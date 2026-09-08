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
// queue and no background worker here: the row is committed first, the email
// is attempted immediately after with a bounded timeout, and the outcome is
// written back to the row. That ordering is deliberate --
//
//   - committing first means a relay outage can never lose an invitation the
//     admin was told was created, and the invitee can still be joined by hand
//     (accept-on-login matches on the address, auth.md §8.7, not on delivery);
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
	// invitationRateWindow / maxInvitationsPerWindow bound how many
	// invitations ONE organization can create per rolling window (#641
	// security review). Without this, a compromised or malicious admin
	// account turns the service into an open relay aimed at arbitrary
	// addresses -- an abuse amplifier and a deliverability risk for the
	// sending domain #417 will provision. 20/hour is far above any real
	// onboarding burst (an organization is a beekeeping business, not a
	// mailing list) and far below anything useful to a spammer.
	invitationRateWindow    = time.Hour
	maxInvitationsPerWindow = 20

	// resendCooldown is the minimum gap between two send attempts for ONE
	// invitation. It stops a resend button (or a script driving the endpoint)
	// from mailbombing a single address, which is the abuse shape the
	// per-organization budget above does not cover.
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

	updated, err := s.q.MarkInvitationDelivery(context.WithoutCancel(ctx), sqlcgen.MarkInvitationDeliveryParams{
		ID:             invitation.ID,
		OrganizationID: invitation.OrganizationID,
		DeliveryStatus: status,
		DeliveryError:  reason,
		LastDeliveryAt: pgtype.Timestamptz{Time: s.clock().UTC(), Valid: true},
	})
	if err != nil {
		return invitation, fmt.Errorf("record invitation delivery: %w", err)
	}
	return updated, nil
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
