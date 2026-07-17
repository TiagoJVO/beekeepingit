// Package api (this file) -- member listing + email invitations (FR-ONB-3,
// FR-TEN-2, NFR-ROL-1, D-3, #27). Every route here is admin-only within the
// caller's own org (auth.md section 5.3: "member/invitation endpoints are
// admin-only, 403 for a user") and asserts {orgId} matches the caller's own
// resolved org before doing anything else (ADR-0002 -- the path never widens
// scope; a caller from a *different* org gets 404, matching
// organizations.go's getOrganization, since there's nothing to reveal about
// another org's existence to a non-member).
//
// acceptPendingInvitationByEmail (called from organizations.go's
// getMyOrganization) is the other half of the invitation lifecycle: it is
// not itself an HTTP handler, just the accept-on-login step "an invited user
// who logs in is joined to the inviting organization" (FR-ONB-3 AC). The
// email it matches against must already be the caller's JWT-verified,
// email_verified-gated address -- never identity.users.email -- see its own
// doc comment and organizations.go's getMyOrganization/ResolvedUser comments
// for the security reasoning (a #170-review-found vulnerability, now fixed).
//
// History recording (FR-HIS-1, #165): invite/revoke/accept each write an
// organizations.audit_log row (entity_type "invitation", plus a "membership"
// create row on accept) in the same local transaction as their domain write
// -- see audit.go's shared writeAuditLog helper and organizations.go's
// package doc for the parallel organization-create wiring.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/organizations/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

const (
	defaultPageLimit = 50
	maxPageLimit     = 200
	// maxEmailLength matches services/identity/api/profile.go's own constant
	// (RFC 5321 upper bound) -- duplicated, not imported: identity and
	// organizations are separate Go modules/services (service-decomposition.md
	// rule 2), so there is no shared package to pull this from.
	maxEmailLength = 320
)

// emailPattern matches services/identity/api/profile.go's own validation --
// duplicated for the same cross-service reason as maxEmailLength above.
var emailPattern = regexp.MustCompile(`^[^\s@]+@[^\s@]+\.[^\s@]+$`)

// MemberResponse is the client-facing member shape
// (contracts/openapi/organizations.openapi.yaml's Member schema).
type MemberResponse struct {
	UserID string `json:"user_id"`
	Role   string `json:"role"`
	Status string `json:"status"`
}

type memberListResponse struct {
	Data []MemberResponse `json:"data"`
	Page pageResponse     `json:"page"`
}

// MemberNameResponse is the least-privilege member-name shape
// (contracts/openapi/organizations.openapi.yaml's MemberName schema, #44
// follow-up): user_id -> display name ONLY, no role/status/email. Any active
// member may read it (unlike the admin-only MemberResponse), so per-user
// attribution (FR-TEN-2) can show a real name instead of a short id fragment.
type MemberNameResponse struct {
	UserID string `json:"user_id"`
	Name   string `json:"name"`
}

type memberNameListResponse struct {
	Data []MemberNameResponse `json:"data"`
	Page pageResponse         `json:"page"`
}

// InvitationResponse is the client-facing invitation shape
// (contracts/openapi/organizations.openapi.yaml's Invitation schema).
type InvitationResponse struct {
	ID        string    `json:"id"`
	Email     string    `json:"email"`
	Role      string    `json:"role"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type invitationListResponse struct {
	Data []InvitationResponse `json:"data"`
	Page pageResponse         `json:"page"`
}

type pageResponse struct {
	NextCursor *string `json:"next_cursor"`
	Limit      int     `json:"limit"`
}

// invitationCreateRequest is the POST /organizations/{orgId}/invitations
// request body (InvitationCreate schema). Role defaults to "user" when
// omitted, matching the memberships table's own DEFAULT.
type invitationCreateRequest struct {
	Email string `json:"email"`
	Role  string `json:"role"`
}

// registerMemberAndInvitationRoutes mounts the admin-only member/invitation
// sub-resources under the same /v1 router organizations.go's PublicRouter
// returns -- kept in this file rather than duplicating PublicRouter, since
// these routes share its request-resolution helpers (resolveActiveMembership).
// Invite/revoke now open their own local transaction (pool, not just q) so
// their #165 audit_log row commits atomically with the domain write
// (history.md section 4) -- see createInvitationHandler/revokeInvitationHandler.
func registerMemberAndInvitationRoutes(r chi.Router, pool *pgxpool.Pool, q *sqlcgen.Queries, resolver UserResolver) {
	r.Get("/organizations/{orgId}/members", listMembersHandler(q, resolver))
	r.Get("/organizations/{orgId}/members/names", listMemberNamesHandler(q, resolver))
	r.Get("/organizations/{orgId}/invitations", listInvitationsHandler(q, resolver))
	r.Post("/organizations/{orgId}/invitations", createInvitationHandler(pool, q, resolver))
	r.Delete("/organizations/{orgId}/invitations/{invitationId}", revokeInvitationHandler(pool, q, resolver))
}

// requireOrgMember resolves the caller's active membership and asserts {orgId}
// matches it (404 otherwise, ADR-0002 -- the path never widens scope; a
// caller from a different org gets 404, not 403, since there's nothing to
// reveal about another org). It applies NO role check -- it's the guard for
// member-readable routes any active member may call (e.g. the member-names
// roster, #44). requireOrgAdmin layers the admin check on top.
func requireOrgMember(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, resolver UserResolver) (callerMembership, bool) {
	member, ok := resolveActiveMembership(w, r, q, resolver)
	if !ok {
		return callerMembership{}, false
	}
	requested, err := uuid.Parse(chi.URLParam(r, "orgId"))
	if err != nil || requested != uuid.UUID(member.OrgID.Bytes) {
		problem.Write(w, r, problem.NotFound("organization not found"))
		return callerMembership{}, false
	}
	return member, true
}

// requireOrgAdmin is requireOrgMember plus an admin-role assertion (403
// otherwise, auth.md section 5.3). Every write-side member/invitation route
// needs exactly this sequence, so it's centralized rather than repeated per
// handler.
func requireOrgAdmin(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, resolver UserResolver) (callerMembership, bool) {
	member, ok := requireOrgMember(w, r, q, resolver)
	if !ok {
		return callerMembership{}, false
	}
	if member.Role != "admin" {
		problem.Write(w, r, problem.Forbidden("only an organization admin may perform this action"))
		return callerMembership{}, false
	}
	return member, true
}

func listMembersHandler(q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		member, ok := requireOrgAdmin(w, r, q, resolver)
		if !ok {
			return
		}

		limit, cursor, ok := parsePage(w, r)
		if !ok {
			return
		}
		rows, err := q.ListMembers(r.Context(), sqlcgen.ListMembersParams{
			OrganizationID: member.OrgID,
			Limit:          int32(limit + 1), //nolint:gosec // limit is clamped to [1,maxPageLimit=200]
			Cursor:         cursor,
		})
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "list members failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		page := pageResponse{Limit: limit}
		if len(rows) > limit {
			next := uuidString(rows[limit-1].ID)
			page.NextCursor = &next
			rows = rows[:limit]
		}
		data := make([]MemberResponse, 0, len(rows))
		for _, row := range rows {
			data = append(data, MemberResponse{
				UserID: uuidString(row.UserID),
				Role:   row.Role,
				Status: row.Status,
			})
		}
		writeJSON(w, r, http.StatusOK, memberListResponse{Data: data, Page: page})
	}
}

// listMemberNamesHandler returns one page of {user_id, name} for the caller's
// org -- readable by ANY active member (requireOrgMember, not requireOrgAdmin),
// the non-admin-safe roster the client needs to resolve activity attribution
// to a real name (#44 follow-up, FR-TEN-2: org data is shared across all
// members). It returns names only -- never role/status/email -- so broadening
// read access beyond admins exposes the minimum: a display name of someone
// the caller already knows shares their org. The roster's user_ids come from
// organizations' own memberships; the names come from identity via the
// injected resolver (service-decomposition.md §4 rule 3 -- cross-context
// composition by id, no cross-schema join). An id identity has no name for
// (or an incomplete profile) yields an empty name, which the client renders
// as a short id fragment. Paginated identically to listMembersHandler.
func listMemberNamesHandler(q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		member, ok := requireOrgMember(w, r, q, resolver)
		if !ok {
			return
		}

		limit, cursor, ok := parsePage(w, r)
		if !ok {
			return
		}
		rows, err := q.ListMembers(r.Context(), sqlcgen.ListMembersParams{
			OrganizationID: member.OrgID,
			Limit:          int32(limit + 1), //nolint:gosec // limit is clamped to [1,maxPageLimit=200]
			Cursor:         cursor,
		})
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "list member names failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		page := pageResponse{Limit: limit}
		if len(rows) > limit {
			next := uuidString(rows[limit-1].ID)
			page.NextCursor = &next
			rows = rows[:limit]
		}

		userIDs := make([]string, 0, len(rows))
		for _, row := range rows {
			userIDs = append(userIDs, uuidString(row.UserID))
		}
		names, err := resolver.ResolveNames(r.Context(), r.Header.Get("Authorization"), userIDs)
		if err != nil {
			// A resolver transport/5xx failure is an upstream fault (identity
			// unreachable), not a client error -- surfaced as 502 and logged,
			// mirroring resolveCaller's own identityUnavailable branch, rather
			// than silently returning every member with an empty name.
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "resolve member names failed", slog.Any("error", err))
			problem.Write(w, r, identityUnavailable("identity service is unavailable"))
			return
		}

		data := make([]MemberNameResponse, 0, len(rows))
		for _, row := range rows {
			id := uuidString(row.UserID)
			data = append(data, MemberNameResponse{UserID: id, Name: names[id]})
		}
		writeJSON(w, r, http.StatusOK, memberNameListResponse{Data: data, Page: page})
	}
}

func listInvitationsHandler(q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		member, ok := requireOrgAdmin(w, r, q, resolver)
		if !ok {
			return
		}

		limit, cursor, ok := parsePage(w, r)
		if !ok {
			return
		}
		rows, err := q.ListInvitations(r.Context(), sqlcgen.ListInvitationsParams{
			OrganizationID: member.OrgID,
			Limit:          int32(limit + 1), //nolint:gosec // limit is clamped to [1,maxPageLimit=200]
			Cursor:         cursor,
		})
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "list invitations failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		page := pageResponse{Limit: limit}
		if len(rows) > limit {
			next := uuidString(rows[limit-1].ID)
			page.NextCursor = &next
			rows = rows[:limit]
		}
		data := make([]InvitationResponse, 0, len(rows))
		for _, row := range rows {
			data = append(data, toInvitationResponse(row))
		}
		writeJSON(w, r, http.StatusOK, invitationListResponse{Data: data, Page: page})
	}
}

func createInvitationHandler(pool *pgxpool.Pool, q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		member, ok := requireOrgAdmin(w, r, q, resolver)
		if !ok {
			return
		}

		var body invitationCreateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}

		var fieldErrs []problem.FieldError
		email := strings.TrimSpace(body.Email)
		switch {
		case email == "":
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "email", Code: "required", Message: "email must not be empty"})
		case len(email) > maxEmailLength || !emailPattern.MatchString(email):
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "email", Code: "invalid", Message: "email must be a valid email address"})
		}
		role := body.Role
		if role == "" {
			role = "user"
		}
		if role != "admin" && role != "user" {
			fieldErrs = append(fieldErrs, problem.FieldError{Field: "role", Code: "invalid", Message: "role must be admin or user"})
		}
		if len(fieldErrs) > 0 {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid", fieldErrs...))
			return
		}

		// History (FR-HIS-1, #165): the invitation's create row commits in
		// the same local transaction as the domain insert (history.md section 4).
		var invitation sqlcgen.OrganizationsInvitation
		now := pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}
		txErr := withTx(r.Context(), pool, func(tx pgx.Tx) error {
			txq := q.WithTx(tx)
			var err error
			invitation, err = txq.CreateInvitation(r.Context(), sqlcgen.CreateInvitationParams{
				ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
				OrganizationID: member.OrgID,
				Email:          email,
				Role:           role,
				InvitedBy:      member.UserID,
			})
			if err != nil {
				return fmt.Errorf("create invitation: %w", err)
			}

			if err := writeAuditLog(r.Context(), txq, member.OrgID, entityTypeInvitation, invitation.ID, member.UserID, now,
				history.ChangeCreate, nil, invitationFields(invitation)); err != nil {
				return fmt.Errorf("write invitation audit log: %w", err)
			}
			return nil
		})
		if txErr != nil {
			if isUniqueViolation(txErr) {
				problem.Write(w, r, problem.Conflict("this email already has a pending invitation to this organization"))
				return
			}
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "create invitation failed", slog.Any("error", txErr))
			problem.Write(w, r, problem.Internal())
			return
		}

		w.Header().Set("Location", "/v1/organizations/"+uuidString(member.OrgID)+"/invitations/"+uuidString(invitation.ID))
		writeJSON(w, r, http.StatusCreated, toInvitationResponse(invitation))
	}
}

func revokeInvitationHandler(pool *pgxpool.Pool, q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		member, ok := requireOrgAdmin(w, r, q, resolver)
		if !ok {
			return
		}

		invitationID, err := uuid.Parse(chi.URLParam(r, "invitationId"))
		if err != nil {
			problem.Write(w, r, problem.NotFound("invitation not found"))
			return
		}

		// Distinguish "doesn't exist in this org" (404) from "exists but
		// isn't pending anymore" (also 404 -- a resolved invitation isn't a
		// resource this endpoint can still act on, and re-checking here
		// keeps the response honest about *why* without leaking whether a
		// non-pending row exists for a non-admin -- moot here since the
		// caller is already asserted admin of this exact org, but keeps the
		// two branches simple rather than a single ambiguous message).
		before, err := q.GetInvitation(r.Context(), sqlcgen.GetInvitationParams{
			ID:             pgtype.UUID{Bytes: invitationID, Valid: true},
			OrganizationID: member.OrgID,
		})
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("invitation not found"))
			return
		}
		if err != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "get invitation before revoke failed", slog.Any("error", err))
			problem.Write(w, r, problem.Internal())
			return
		}

		// History (FR-HIS-1, #165): the revoke's update row commits in the
		// same local transaction as the domain update (history.md section 4).
		var revoked sqlcgen.OrganizationsInvitation
		now := pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}
		txErr := withTx(r.Context(), pool, func(tx pgx.Tx) error {
			txq := q.WithTx(tx)
			var err error
			revoked, err = txq.RevokeInvitation(r.Context(), sqlcgen.RevokeInvitationParams{
				ID:             pgtype.UUID{Bytes: invitationID, Valid: true},
				OrganizationID: member.OrgID,
			})
			if err != nil {
				// includes pgx.ErrNoRows: invitation is no longer pending --
				// returned as-is (not wrapped) so the errors.Is check below
				// still matches.
				return err
			}

			if err := writeAuditLog(r.Context(), txq, member.OrgID, entityTypeInvitation, revoked.ID, member.UserID, now,
				history.ChangeUpdate, invitationFields(before), invitationFields(revoked)); err != nil {
				return fmt.Errorf("write invitation audit log: %w", err)
			}
			return nil
		})
		if errors.Is(txErr, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("invitation is no longer pending"))
			return
		}
		if txErr != nil {
			logging.FromContext(r.Context()).ErrorContext(r.Context(), "revoke invitation failed", slog.Any("error", txErr))
			problem.Write(w, r, problem.Internal())
			return
		}

		w.WriteHeader(http.StatusNoContent)
	}
}

// acceptPendingInvitationByEmail implements the accept-on-login step
// (FR-ONB-3 AC: "an invited user who logs in is joined to the inviting
// organization rather than prompted to create a new one"). Looks up a
// pending invitation for email; if found, marks it accepted and creates the
// membership at the invitation's role, in one DB transaction -- the same
// atomicity pattern as organizations.go's CreateOrganization+CreateMembership
// (D-3), so an invitation is never left pending after its membership exists,
// or vice versa. Returns pgx.ErrNoRows when there is no pending invitation
// for email (the ordinary "not invited" case, not a server fault). email
// must already be the caller's verified email (getMyOrganization passes ""
// when claims.EmailVerified is false, deliberately routing an unverified
// caller through this same "nothing pending" path rather than a distinct
// one) -- see getMyOrganization's security-critical doc comment.
//
// Takes ctx directly (not *http.Request): it does no request-specific work
// beyond the context, and organizations.go's getMyOrganization is its only
// caller.
func acceptPendingInvitationByEmail(ctx context.Context, pool *pgxpool.Pool, q *sqlcgen.Queries, userID pgtype.UUID, email string) (callerMembership, error) {
	if email == "" {
		return callerMembership{}, pgx.ErrNoRows
	}
	invitation, err := q.GetPendingInvitationByEmail(ctx, email)
	if err != nil {
		// includes pgx.ErrNoRows: no pending invitation -- wrapping with %w
		// preserves errors.Is(err, pgx.ErrNoRows) for getMyOrganization.
		return callerMembership{}, fmt.Errorf("get pending invitation by email: %w", err)
	}

	var membership sqlcgen.OrganizationsMembership
	now := pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}
	txErr := withTx(ctx, pool, func(tx pgx.Tx) error {
		txq := q.WithTx(tx)

		accepted, err := txq.AcceptInvitation(ctx, invitation.ID)
		if err != nil {
			// Lost the race with another accept/revoke of the same
			// invitation between the read above and this update. Wrapped
			// with %w (not returned bare) -- errors.Is unwraps through it,
			// so getMyOrganization's errors.Is(err, pgx.ErrNoRows) still
			// matches; the caller still has no org.
			return fmt.Errorf("accept invitation: %w", err)
		}

		// History (FR-HIS-1, #165): the accept is an update on the
		// invitation (pending -> accepted) -- the accepting user IS the
		// actor here (there is no admin action on this path), in the same
		// transaction as the domain update (history.md section 4).
		if err := writeAuditLog(ctx, txq, accepted.OrganizationID, entityTypeInvitation, accepted.ID, userID, now,
			history.ChangeUpdate, invitationFields(invitation), invitationFields(accepted)); err != nil {
			return fmt.Errorf("write invitation audit log: %w", err)
		}

		membership, err = txq.CreateMembershipWithRole(ctx, sqlcgen.CreateMembershipWithRoleParams{
			ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
			OrganizationID: accepted.OrganizationID,
			UserID:         userID,
			Role:           accepted.Role,
		})
		if err != nil {
			return fmt.Errorf("create membership: %w", err)
		}

		// The new membership this acceptance creates is its own entity/create
		// row, same transaction (mirrors organizations.go's createOrganization
		// writing both the org's and its creator membership's rows together).
		if err := writeAuditLog(ctx, txq, membership.OrganizationID, entityTypeMembership, membership.ID, userID, now,
			history.ChangeCreate, nil, membershipFields(membership)); err != nil {
			return fmt.Errorf("write membership audit log: %w", err)
		}
		return nil
	})
	if txErr != nil {
		return callerMembership{}, txErr
	}
	return callerMembership{OrgID: membership.OrganizationID, UserID: userID, Role: membership.Role}, nil
}

func toInvitationResponse(inv sqlcgen.OrganizationsInvitation) InvitationResponse {
	return InvitationResponse{
		ID:        uuidString(inv.ID),
		Email:     inv.Email,
		Role:      inv.Role,
		Status:    inv.Status,
		CreatedAt: inv.CreatedAt.Time,
		UpdatedAt: inv.UpdatedAt.Time,
	}
}

// parsePage parses the shared limit/cursor query params (matches apiaries'
// ReadRouter convention). Writes a 422 and returns ok=false on a malformed
// limit or cursor -- limit used to silently fall back to defaultPageLimit on
// a non-numeric or non-positive value while cursor 422'd on a malformed
// value; both are now validated the same way (MEDIUM review finding).
func parsePage(w http.ResponseWriter, r *http.Request) (limit int, cursor pgtype.UUID, ok bool) {
	limit = defaultPageLimit
	if raw := r.URL.Query().Get("limit"); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n < 1 {
			problem.Write(w, r, problem.ValidationFailed("limit must be a positive integer",
				problem.FieldError{Field: "limit", Code: "invalid", Message: "must be a positive integer"}))
			return 0, pgtype.UUID{}, false
		}
		limit = n
		if limit > maxPageLimit {
			limit = maxPageLimit
		}
	}
	if raw := r.URL.Query().Get("cursor"); raw != "" {
		c, err := uuid.Parse(raw)
		if err != nil {
			problem.Write(w, r, problem.ValidationFailed("cursor must be a UUID",
				problem.FieldError{Field: "cursor", Code: "invalid", Message: "must be a UUID"}))
			return 0, pgtype.UUID{}, false
		}
		cursor = pgtype.UUID{Bytes: c, Valid: true}
	}
	return limit, cursor, true
}
