// Package api (this file) — member listing + email invitations (FR-ONB-3,
// FR-TEN-2, NFR-ROL-1, D-3, #27). Every route here is admin-only within the
// caller's own org (auth.md §5.3: "member/invitation endpoints are
// admin-only, 403 for a user") and asserts {orgId} matches the caller's own
// resolved org before doing anything else (ADR-0002 — the path never widens
// scope; a caller from a *different* org gets 404, matching
// organizations.go's getOrganization, since there's nothing to reveal about
// another org's existence to a non-member).
//
// acceptPendingInvitationByEmail (called from organizations.go's
// getMyOrganization) is the other half of the invitation lifecycle: it is
// not itself an HTTP handler, just the accept-on-login step "an invited user
// who logs in is joined to the inviting organization" (FR-ONB-3 AC). The
// email it matches against must already be the caller's JWT-verified,
// email_verified-gated address — never identity.users.email — see its own
// doc comment and organizations.go's getMyOrganization/ResolvedUser comments
// for the security reasoning (a #170-review-found vulnerability, now fixed).
//
// History recording (FR-HIS-1) for invite/accept/revoke is explicitly
// deferred — see organizations.go's package doc; tracked in #165.
package api

import (
	"encoding/json"
	"errors"
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
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

const (
	defaultPageLimit = 50
	maxPageLimit     = 200
	// maxEmailLength matches services/identity/api/profile.go's own constant
	// (RFC 5321 upper bound) — duplicated, not imported: identity and
	// organizations are separate Go modules/services (service-decomposition.md
	// rule 2), so there is no shared package to pull this from.
	maxEmailLength = 320
)

// emailPattern matches services/identity/api/profile.go's own validation —
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
// returns — kept in this file rather than duplicating PublicRouter, since
// these routes share its request-resolution helpers (resolveActiveMembership).
// Invite/revoke are single-statement (no transaction needed), unlike
// acceptPendingInvitationByEmail below.
func registerMemberAndInvitationRoutes(r chi.Router, q *sqlcgen.Queries, resolver UserResolver) {
	r.Get("/organizations/{orgId}/members", listMembersHandler(q, resolver))
	r.Get("/organizations/{orgId}/invitations", listInvitationsHandler(q, resolver))
	r.Post("/organizations/{orgId}/invitations", createInvitationHandler(q, resolver))
	r.Delete("/organizations/{orgId}/invitations/{invitationId}", revokeInvitationHandler(q, resolver))
}

// requireOrgAdmin resolves the caller's active membership, asserts {orgId}
// matches it (404 otherwise, ADR-0002), and asserts the caller is an org
// admin (403 otherwise, auth.md §5.3). Every member/invitation route needs
// exactly this sequence, so it's centralized rather than repeated per
// handler.
func requireOrgAdmin(w http.ResponseWriter, r *http.Request, q *sqlcgen.Queries, resolver UserResolver) (callerMembership, bool) {
	member, ok := resolveActiveMembership(w, r, q, resolver)
	if !ok {
		return callerMembership{}, false
	}
	requested, err := uuid.Parse(chi.URLParam(r, "orgId"))
	if err != nil || requested != uuid.UUID(member.OrgID.Bytes) {
		problem.Write(w, r, problem.NotFound("organization not found"))
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
		writeJSON(w, http.StatusOK, memberListResponse{Data: data, Page: page})
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
		writeJSON(w, http.StatusOK, invitationListResponse{Data: data, Page: page})
	}
}

func createInvitationHandler(q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
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

		invitation, err := q.CreateInvitation(r.Context(), sqlcgen.CreateInvitationParams{
			ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
			OrganizationID: member.OrgID,
			Email:          email,
			Role:           role,
			InvitedBy:      member.UserID,
		})
		if isUniqueViolation(err) {
			problem.Write(w, r, problem.Conflict("this email already has a pending invitation to this organization"))
			return
		}
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		w.Header().Set("Location", "/v1/organizations/"+uuidString(member.OrgID)+"/invitations/"+uuidString(invitation.ID))
		writeJSON(w, http.StatusCreated, toInvitationResponse(invitation))
	}
}

func revokeInvitationHandler(q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
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
		// isn't pending anymore" (also 404 — a resolved invitation isn't a
		// resource this endpoint can still act on, and re-checking here
		// keeps the response honest about *why* without leaking whether a
		// non-pending row exists for a non-admin — moot here since the
		// caller is already asserted admin of this exact org, but keeps the
		// two branches simple rather than a single ambiguous message).
		_, err = q.GetInvitation(r.Context(), sqlcgen.GetInvitationParams{
			ID:             pgtype.UUID{Bytes: invitationID, Valid: true},
			OrganizationID: member.OrgID,
		})
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("invitation not found"))
			return
		}
		if err != nil {
			problem.Write(w, r, problem.Internal())
			return
		}

		_, err = q.RevokeInvitation(r.Context(), sqlcgen.RevokeInvitationParams{
			ID:             pgtype.UUID{Bytes: invitationID, Valid: true},
			OrganizationID: member.OrgID,
		})
		if errors.Is(err, pgx.ErrNoRows) {
			problem.Write(w, r, problem.NotFound("invitation is no longer pending"))
			return
		}
		if err != nil {
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
// membership at the invitation's role, in one DB transaction — the same
// atomicity pattern as organizations.go's CreateOrganization+CreateMembership
// (D-3), so an invitation is never left pending after its membership exists,
// or vice versa. Returns pgx.ErrNoRows when there is no pending invitation
// for email (the ordinary "not invited" case, not a server fault). email
// must already be the caller's verified email (getMyOrganization passes ""
// when claims.EmailVerified is false, deliberately routing an unverified
// caller through this same "nothing pending" path rather than a distinct
// one) — see getMyOrganization's security-critical doc comment.
func acceptPendingInvitationByEmail(r *http.Request, pool *pgxpool.Pool, q *sqlcgen.Queries, userID pgtype.UUID, email string) (callerMembership, error) {
	if email == "" {
		return callerMembership{}, pgx.ErrNoRows
	}
	invitation, err := q.GetPendingInvitationByEmail(r.Context(), email)
	if err != nil {
		return callerMembership{}, err // includes pgx.ErrNoRows: no pending invitation
	}

	tx, err := pool.Begin(r.Context())
	if err != nil {
		return callerMembership{}, err
	}
	defer tx.Rollback(r.Context()) //nolint:errcheck // no-op after a successful Commit
	txq := q.WithTx(tx)

	accepted, err := txq.AcceptInvitation(r.Context(), invitation.ID)
	if err != nil {
		// Lost the race with another accept/revoke of the same invitation
		// between the read above and this update — surface as "not found"
		// rather than 500; the caller (getMyOrganization) still has no org.
		return callerMembership{}, err
	}

	membership, err := txq.CreateMembershipWithRole(r.Context(), sqlcgen.CreateMembershipWithRoleParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		OrganizationID: accepted.OrganizationID,
		UserID:         userID,
		Role:           accepted.Role,
	})
	if err != nil {
		return callerMembership{}, err
	}

	if err := tx.Commit(r.Context()); err != nil {
		return callerMembership{}, err
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
// cursor.
func parsePage(w http.ResponseWriter, r *http.Request) (limit int, cursor pgtype.UUID, ok bool) {
	limit = defaultPageLimit
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n >= 1 {
			limit = n
			if limit > maxPageLimit {
				limit = maxPageLimit
			}
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
