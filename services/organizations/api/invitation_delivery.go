// Package api (this file) -- the invitation email's DELIVERY: when it is
// attempted, in which language, what is recorded about the outcome, and the
// limits that stop the send path being abused (#641, FR-ONB-3, FR-TEN-2, D-3).
//
// The message itself (EN/PT catalogs, escaping, the sign-up link) is
// invitation_email.go; the SMTP transport is services/shared/mail. This file is
// only the policy in between.
//
// WHY THE SEND IS SYNCHRONOUS AND ITS FAILURE IS NOT AN ERROR. Creating an
// invitation is a low-volume, human-initiated admin action, so there is no
// queue and no background worker here: the row is committed first -- with its
// attempt already CLAIMED in that same transaction (#854, see
// claimDeliverySlot) -- the email is attempted immediately after with a
// bounded timeout, and the outcome is written back to the row. That ordering
// is deliberate --
//
//   - claiming the attempt before the SMTP conversation, never after it, means
//     the two limits that matter (this invitation's cooldown and its lifetime
//     cap) are spent by the same statement that checks them, so concurrent
//     attempts cannot both pass and a lost outcome write cannot hand back a
//     free attempt;
//
//   - committing first means a relay outage can never lose an invitation the
//     admin was told was created, and the invitee can still be joined by hand
//     (accept-on-login matches on the address, auth.md §8.7, not on delivery);
//
//   - a failed send therefore returns 201 with delivery_status "failed", not a
//     5xx. The invitation EXISTS. Reporting the create as failed would be the
//     mirror image of the bug #641 is about -- a screen saying something that
//     is not true -- and would leave a real row behind an error message.
//
// The admin sees "failed" plus a short reason and a resend action; that is
// #641's "a failed send is visible to the admin and retryable".
//
// WHAT AN UNCONFIGURED RELAY MEANS. An environment with no SMTP relay
// provisioned yet (staging/prod until #417 lands a real provider and sending
// domain) gets mail.Unconfigured(): the service starts normally and every
// invitation records delivery_status "failed" with reason "not_configured".
// That is the honest state -- no mail is leaving -- and it needs no code change
// to fix, only configuration.
package api

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgtype"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/organizations/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/shared/mail"
)

// Delivery states -- mirrors the delivery_status CHECK in migration 00008 and
// the Invitation schema's enum in contracts/openapi/organizations.openapi.yaml.
const (
	deliveryPending = "pending"
	deliverySent    = "sent"
	deliveryFailed  = "failed"
)

// Short, stable, non-sensitive failure reasons stored in
// invitations.delivery_error and shown to the admin. They are CODES, not
// messages: the client localizes them (EN/PT, NFR-I18N-1), and a code can
// never accidentally carry a relay hostname, a credential or the recipient's
// address into a screen or a log the way a raw driver error would.
const (
	failureNotConfigured = "not_configured"
	failureRejected      = "rejected"
	failureUnavailable   = "relay_unavailable"
	failureRenderFailed  = "render_failed"
	failureNeverSent     = "never_sent" // written by migration 00008's backfill only
)

const (
	// invitationRateWindow / maxInvitationsPerWindow bound how much
	// invitation mail ONE organization can cause per rolling window (#641
	// security review). Without this, a compromised or malicious admin
	// account turns the service into an open relay aimed at arbitrary
	// addresses -- an abuse amplifier and a deliverability risk for the
	// sending domain #417 will provision. 20/hour is far above any real
	// onboarding burst (an organization is a beekeeping business, not a
	// mailing list) and far below anything useful to a spammer.
	//
	// RESENDS SPEND THE SAME BUDGET (#854): a resend can target
	// any still-pending invitation of any age, so a window counted only over
	// creations left the endpoint that actually causes most of the mail
	// outside the ceiling. What is bounded is mail leaving on behalf of one
	// organization per hour, not the endpoint that triggered it --
	// CountInvitationDeliveryBudgetSince counts both.
	invitationRateWindow    = time.Hour
	maxInvitationsPerWindow = 20

	// resendCooldown is the minimum gap between two send attempts for ONE
	// invitation. It stops a resend button (or a script driving the endpoint)
	// from mailbombing a single address, which is the abuse shape the
	// per-organization budget above does not cover.
	//
	// It only stops that if it is SERIALIZED, which is what
	// claimDeliverySlot's conditional UPDATE provides (#854): the cooldown
	// used to be read on the pool and acted on afterwards, so concurrent
	// resends all observed the same pre-attempt state.
	resendCooldown = time.Minute

	// maxDeliveryAttempts caps total attempts per invitation. A permanently
	// undeliverable address (typo, closed mailbox) must not be retryable
	// forever: past this the admin has to revoke and re-invite, which is both
	// the correct fix for a typo and a hard ceiling on how much mail one
	// invitation row can generate.
	maxDeliveryAttempts = 10

	// sendTimeout bounds ONE SMTP conversation. The admin is waiting on this
	// synchronously, so it is short: a slow relay becomes a recorded, visible,
	// retryable failure rather than a request that hangs.
	sendTimeout = 15 * time.Second

	// recordTimeout bounds the outcome write that follows the send. It is
	// detached from the request's cancellation (the outcome must be recorded
	// even if the admin closed the tab) but must not be unbounded: it is a
	// single indexed UPDATE, and on the resend path it decides 200 vs 500.
	recordTimeout = 5 * time.Second
)

// invitationSender carries everything the delivery step needs. Built once per
// router (PublicRouter's options) rather than threaded through every handler
// signature, and injected as an interface (mail.Sender) so tests can substitute
// a recording fake without an SMTP server.
type invitationSender struct {
	mailer     mail.Sender
	appBaseURL string
	resolver   UserResolver
	q          *sqlcgen.Queries
	// now is the clock, injectable so the resend-cooldown tests do not have to
	// sleep.
	now func() time.Time
}

// enabled reports whether this service was wired with a usable mail
// configuration. A false value is a legitimate deployment state, not a bug
// (see the package comment) -- it is reported per invitation, never at startup.
func (s invitationSender) enabled() bool {
	return s.mailer != nil && s.appBaseURL != ""
}

// deliver attempts ONE send for invitation and records the outcome, returning
// the updated row. It never returns an error for a send failure -- that is
// state, not an error -- and only returns one when the outcome could not be
// PERSISTED, which is a real fault the caller must surface.
//
// PRECONDITION (#854): the attempt slot must already be claimed --
// claimDeliverySlot, committed -- before deliver is called. deliver records
// only what the attempt DID; it does not charge the attempt or restart the
// cooldown. That ordering is what makes the bookkeeping fail CLOSED: losing
// the write below costs the admin an accurate status line, never a spent
// attempt or a cooldown that never started after mail had already gone out.
//
// bearer is the caller's Authorization header, forwarded to identity for the
// two composition lookups below (service-decomposition.md §4 rule 3).
func (s invitationSender) deliver(ctx context.Context, bearer string, invitation sqlcgen.OrganizationsInvitation) (sqlcgen.OrganizationsInvitation, error) {
	log := logging.FromContext(ctx)

	// Detach from the HTTP request's cancellation but keep its values (trace
	// context, logger): an admin closing the tab mid-send must not leave the
	// row claiming a send is still in flight. The bounded timeout below is
	// what stops this outliving the request meaningfully.
	sendCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), sendTimeout)
	defer cancel()

	status, reason := s.attempt(sendCtx, bearer, invitation)
	if status == deliveryFailed {
		// Logged at WARN with the invitation id and the CODE only -- never
		// the recipient address (that is an admin-visible field, not a
		// log-visible one) and never the underlying error text, which can
		// carry relay detail.
		log.WarnContext(ctx, "invitation email not delivered",
			slog.String("invitation_id", uuidString(invitation.ID)),
			slog.String("reason", reason))
	}

	// Detached from the request's cancellation for the same reason as the send
	// above, but BOUNDED: this single UPDATE is what decides the resend's 200
	// vs 500, and an unbounded wait on a wedged database would pin a pool
	// connection and the admin's request behind it indefinitely.
	recordCtx, recordCancel := context.WithTimeout(context.WithoutCancel(ctx), recordTimeout)
	defer recordCancel()

	updated, err := s.q.RecordInvitationDeliveryOutcome(recordCtx, sqlcgen.RecordInvitationDeliveryOutcomeParams{
		ID:             invitation.ID,
		OrganizationID: invitation.OrganizationID,
		DeliveryStatus: status,
		DeliveryError:  reason,
	})
	if err != nil {
		return invitation, fmt.Errorf("record invitation delivery: %w", err)
	}
	return updated, nil
}

// claimDeliverySlot charges ONE attempt against invitationID and restarts its
// cooldown, atomically, inside the caller's transaction (#854, NFR-SEC-1).
//
// It is the single place either send path is allowed to decide "this attempt
// may happen", and it decides by WRITING: one conditional UPDATE that checks
// still-pending, the lifetime cap and the cooldown in the same statement that
// spends them. pgx.ErrNoRows means refused, and the caller must not open an
// SMTP conversation.
//
// Both callers additionally hold LockOrganizationForUpdate, so the budget
// count next to this claim is stable too; the conditional UPDATE is what makes
// the PER-INVITATION limits hold on its own, independently of that lock.
func claimDeliverySlot(ctx context.Context, txq *sqlcgen.Queries, invitationID, orgID pgtype.UUID, now time.Time) (sqlcgen.OrganizationsInvitation, error) {
	return txq.ClaimInvitationDeliverySlot(ctx, sqlcgen.ClaimInvitationDeliverySlotParams{
		ID:             invitationID,
		OrganizationID: orgID,
		AttemptedAt:    pgtype.Timestamptz{Time: now.UTC(), Valid: true},
		MaxAttempts:    maxDeliveryAttempts,
		CooldownCutoff: pgtype.Timestamptz{Time: now.Add(-resendCooldown).UTC(), Valid: true},
	})
}

// checkDeliveryBudget returns errInvitationBudget when this organization has
// already spent its hourly outbound-mail allowance (#641 security review,
// extended to resends by #854). Called inside the caller's transaction, after
// LockOrganizationForUpdate, so the count cannot move between being read and
// being acted on.
//
// The allowance is counted in MESSAGES, not invitations: see
// CountInvitationDeliveryBudgetSince for why a per-row count let a resend loop
// run about ten times past the stated ceiling, and for the one direction in
// which the sum deliberately over-charges.
//
// Fails CLOSED by construction: a count that cannot be read returns an error
// and aborts the transaction rather than letting the send through.
func checkDeliveryBudget(ctx context.Context, txq *sqlcgen.Queries, orgID pgtype.UUID, now time.Time) error {
	count, err := txq.CountInvitationDeliveryBudgetSince(ctx, sqlcgen.CountInvitationDeliveryBudgetSinceParams{
		OrganizationID: orgID,
		Since:          pgtype.Timestamptz{Time: now.Add(-invitationRateWindow).UTC(), Valid: true},
	})
	if err != nil {
		return fmt.Errorf("count recent invitation sends: %w", err)
	}
	if count >= maxInvitationsPerWindow {
		return errInvitationBudget
	}
	return nil
}

// attempt renders and sends, returning (delivery_status, delivery_error code).
// Split out from deliver so the "what happened" logic has no database in it.
func (s invitationSender) attempt(ctx context.Context, bearer string, invitation sqlcgen.OrganizationsInvitation) (status, reason string) {
	if !s.enabled() {
		return deliveryFailed, failureNotConfigured
	}

	log := logging.FromContext(ctx)

	// The organization row carries both the name the email must show and the
	// fallback locale (migration 00008). Without it there is no message to
	// render at all, so this is the one lookup whose failure is fatal to the
	// attempt.
	org, err := s.q.GetOrganization(ctx, invitation.OrganizationID)
	if err != nil {
		log.ErrorContext(ctx, "load organization for invitation email failed", slog.Any("error", err))
		return deliveryFailed, failureRenderFailed
	}

	msg, err := invitationEmail(s.locale(ctx, bearer, invitation.Email, org.Locale), invitationEmailData{
		OrganizationName: org.Name,
		InviterName:      s.inviterName(ctx, bearer, invitation.InvitedBy),
		InviteeEmail:     invitation.Email,
		SignUpURL:        signUpURL(s.appBaseURL),
	})
	if err != nil {
		log.ErrorContext(ctx, "render invitation email failed", slog.Any("error", err))
		return deliveryFailed, failureRenderFailed
	}

	if err := s.mailer.Send(ctx, msg); err != nil {
		return deliveryFailed, classifySendError(err)
	}
	return deliverySent, ""
}

// locale implements #641 AC 3 -- "sent in the recipient's language where
// known, otherwise the organization's".
//
// "Known" means identity has a profile for this address and that profile
// carries a locale. The lookup is identity's internal by-email endpoint, the
// same non-authoritative profile cache #468's support tool uses: fine for
// choosing a language, never for an authorization decision (see ResolvedUser's
// doc comment). Its failure -- unknown address, or identity unreachable --
// falls straight through to the organization's own locale rather than failing
// the send: a message in the wrong language still delivers the invitation.
//
// This lookup is invisible to the admin and to the invitee, so it is not an
// account-existence oracle: the only observable difference is the language of
// a message sent to the address's own owner.
func (s invitationSender) locale(ctx context.Context, bearer, email, orgLocale string) string {
	if s.resolver == nil {
		return orgLocale
	}
	user, err := s.resolver.ResolveByEmail(ctx, bearer, email)
	switch {
	case err == nil && strings.TrimSpace(user.Locale) != "":
		return user.Locale
	case err != nil && !errors.Is(err, ErrUnknownUser):
		logging.FromContext(ctx).WarnContext(ctx, "invitation email locale lookup failed; using the organization's language",
			slog.Any("error", err))
	}
	return orgLocale
}

// inviterName resolves the inviting admin's display name for the message body
// (#641 AC 2: the email identifies the inviter). Best-effort: identity holds
// names, this service holds the membership (service-decomposition.md §4 rule
// 3), and a name that cannot be resolved -- unreachable identity, or an admin
// who never completed their profile -- yields "", which the templates render
// as an impersonal phrasing that still names the organization. Losing the
// inviter's name is not a reason to withhold the invitation.
func (s invitationSender) inviterName(ctx context.Context, bearer string, inviterID pgtype.UUID) string {
	if s.resolver == nil {
		return ""
	}
	names, err := s.resolver.ResolveNames(ctx, bearer, []string{uuidString(inviterID)})
	if err != nil {
		logging.FromContext(ctx).WarnContext(ctx, "invitation email inviter-name lookup failed; sending without it",
			slog.Any("error", err))
		return ""
	}
	return names[uuidString(inviterID)]
}

func (s invitationSender) clock() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

// classifySendError maps a transport error onto one of the short admin-facing
// codes. Deliberately coarse: the admin's only two useful questions are "is
// this address wrong?" and "is the mail system broken?", and a finer taxonomy
// would tempt the code into echoing SMTP text (which can quote the recipient
// address and the relay's banner) into a database column and a UI.
func classifySendError(err error) string {
	if errors.Is(err, mail.ErrNotConfigured) {
		return failureNotConfigured
	}
	// A stored value that would inject a header. Reported as "rejected"
	// rather than a distinct code: the fix is the same (correct the
	// organization or inviter name, or the address, and send again), and
	// naming the injection attempt back to whoever may have made it is not
	// information they need.
	if errors.Is(err, mail.ErrInvalidHeader) {
		return failureRejected
	}
	// A 5xx from the relay is PERMANENT for this message (bad address, refused
	// content, blocked sender): retrying it unchanged will fail identically, so
	// the admin is told the address/message was rejected rather than sent
	// looking for a broken mail server. Everything else -- 4xx, a dial failure,
	// a timeout -- is transient, and a retry is the right advice.
	var stepErr *mail.StepError
	if errors.As(err, &stepErr) && stepErr.Code >= 500 && stepErr.Code < 600 {
		return failureRejected
	}
	return failureUnavailable
}
