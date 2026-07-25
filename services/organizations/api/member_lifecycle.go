// Package api (this file) -- admin-only member lifecycle management (#290,
// FR-TEN-2, FR-HIS-1, NFR-ROL-1, NFR-ROL-2, D-3): remove a member from an
// organization and change a member's role within the fixed admin/user model
// (auth.md §5.3). Both routes are registered by invitations.go's
// registerMemberAndInvitationRoutes and reuse its requireOrgAdmin guard, so
// they are admin-only and {orgId}-scoped exactly like the invitation writes:
// a non-admin caller is 403, a caller from another org is 404 (ADR-0002 -- the
// path never widens scope).
//
// Last-admin guard (D-3, closes its "removing members / transferring admin"
// still-open detail): an organization must always keep at least one active
// admin, so removing OR demoting the only remaining admin is refused with 409.
// The check is race-safe via a single per-org serialization point --
// LockOrganizationForUpdate row-locks the organization at the top of each
// transaction, so all remove/change-role writes on one org serialize on that
// one row and CountActiveAdmins runs against an admin set no concurrent
// demote/remove/promote can change before the transaction commits.
//
// Removal is a soft state transition (status active -> removed), mirroring the
// invitation revoke path: the membership row is kept for its history/audit
// trail and stable UNIQUE(organization_id, user_id) identity, but it stops
// resolving as the caller's active membership on their very next request
// (GetActiveMembershipByUser filters status = 'active'), which is what makes a
// removed member lose access to the org's data (FR-TEN-2, NFR-ROL-1). History
// (FR-HIS-1, #165): each remove/role-change writes one organizations.audit_log
// update row for the membership entity, actor = the acting admin, in the same
// local transaction as the domain write (audit.go's writeAuditLog).
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
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

// errLastAdmin is the sentinel a lifecycle transaction returns when the action
// would leave the organization with no active admin (D-3). It is checked with
// errors.Is after the transaction and mapped to 409 Conflict -- kept private to
// this package since only these handlers raise it.
var errLastAdmin = errors.New("api: action would remove the organization's last admin")

// memberRoleUpdateRequest is the PATCH /organizations/{orgId}/members/{userId}
// body (MemberRoleUpdate schema): the single role field, constrained to the
// fixed admin/user enum (NFR-ROL-1/2 -- no new roles are invented here).
type memberRoleUpdateRequest struct {
	Role string `json:"role"`
}

// removeMemberHandler soft-removes an active member of the caller's org (#290,
// FR-TEN-2). Admin-only and org-scoped (requireOrgAdmin). Refuses to remove the
// org's last admin (409, D-3). A member id that isn't an active member of this
// org -- already removed, never a member, or a different org's user -- is 404,
// matching revokeInvitation's "nothing to act on" semantics and never
// confirming another org's membership (ADR-0002).
func removeMemberHandler(pool *pgxpool.Pool, q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		actor, ok := requireOrgAdmin(w, r, q, resolver)
		if !ok {
			return
		}
		targetUserID, ok := parseMemberUserID(w, r)
		if !ok {
			return
		}

		now := pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}
		txErr := withTx(r.Context(), pool, func(tx pgx.Tx) error {
			txq := q.WithTx(tx)

			// Serialize this org's lifecycle writes before reading the target,
			// so the last-admin count below is stable (D-3).
			if _, err := txq.LockOrganizationForUpdate(r.Context(), actor.OrgID); err != nil {
				return fmt.Errorf("lock organization: %w", err)
			}
			before, err := txq.GetActiveMembership(r.Context(), sqlcgen.GetActiveMembershipParams{
				OrganizationID: actor.OrgID,
				UserID:         pgtype.UUID{Bytes: targetUserID, Valid: true},
			})
			if err != nil {
				return err // includes pgx.ErrNoRows -> 404 below
			}
			if err := guardLastAdmin(r.Context(), txq, actor.OrgID, before.Role); err != nil {
				return err
			}

			removed, err := txq.RemoveMembership(r.Context(), sqlcgen.RemoveMembershipParams{
				OrganizationID: actor.OrgID,
				UserID:         pgtype.UUID{Bytes: targetUserID, Valid: true},
			})
			if err != nil {
				return fmt.Errorf("remove membership: %w", err)
			}

			if err := writeAuditLog(r.Context(), txq, actor.OrgID, entityTypeMembership, removed.ID, actor.UserID, now,
				history.ChangeUpdate, membershipFields(before), membershipFields(removed)); err != nil {
				return fmt.Errorf("write membership audit log: %w", err)
			}
			return nil
		})
		if writeLifecycleError(w, r, txErr, "remove member") {
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}
}

// changeMemberRoleHandler changes an active member's role within the fixed
// admin/user model (#290, NFR-ROL-1/2, auth.md §5.3). Admin-only and
// org-scoped. Refuses to demote the org's last admin to user (409, D-3);
// promotions are always safe. A no-op (role already equal) succeeds with 200
// and writes no audit row. An unknown active member of this org is 404.
func changeMemberRoleHandler(pool *pgxpool.Pool, q *sqlcgen.Queries, resolver UserResolver) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		actor, ok := requireOrgAdmin(w, r, q, resolver)
		if !ok {
			return
		}
		targetUserID, ok := parseMemberUserID(w, r)
		if !ok {
			return
		}

		var body memberRoleUpdateRequest
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			problem.Write(w, r, problem.ValidationFailed("request body must be valid JSON"))
			return
		}
		if !isValidMembershipRole(body.Role) {
			problem.Write(w, r, problem.ValidationFailed("one or more fields are invalid",
				problem.FieldError{Field: "role", Code: "invalid", Message: "role must be admin or user"}))
			return
		}

		var updated sqlcgen.OrganizationsMembership
		now := pgtype.Timestamptz{Time: time.Now().UTC(), Valid: true}
		txErr := withTx(r.Context(), pool, func(tx pgx.Tx) error {
			txq := q.WithTx(tx)

			// Serialize this org's lifecycle writes before reading the target,
			// so the last-admin count below is stable (D-3).
			if _, err := txq.LockOrganizationForUpdate(r.Context(), actor.OrgID); err != nil {
				return fmt.Errorf("lock organization: %w", err)
			}
			before, err := txq.GetActiveMembership(r.Context(), sqlcgen.GetActiveMembershipParams{
				OrganizationID: actor.OrgID,
				UserID:         pgtype.UUID{Bytes: targetUserID, Valid: true},
			})
			if err != nil {
				return err // includes pgx.ErrNoRows -> 404 below
			}

			// No-op: role already equals the requested one. Return the current
			// row without a domain write or an audit row -- an update delta
			// would be empty, so recording it would only add a misleading
			// no-change history entry.
			if before.Role == body.Role {
				updated = before
				return nil
			}

			// Demoting an admin to user is the only role change that can drop
			// the admin count; a promotion (user -> admin) never trips the guard.
			if body.Role == "user" {
				if err := guardLastAdmin(r.Context(), txq, actor.OrgID, before.Role); err != nil {
					return err
				}
			}

			updated, err = txq.UpdateMembershipRole(r.Context(), sqlcgen.UpdateMembershipRoleParams{
				OrganizationID: actor.OrgID,
				UserID:         pgtype.UUID{Bytes: targetUserID, Valid: true},
				Role:           body.Role,
			})
			if err != nil {
				return fmt.Errorf("update membership role: %w", err)
			}

			if err := writeAuditLog(r.Context(), txq, actor.OrgID, entityTypeMembership, updated.ID, actor.UserID, now,
				history.ChangeUpdate, membershipFields(before), membershipFields(updated)); err != nil {
				return fmt.Errorf("write membership audit log: %w", err)
			}
			return nil
		})
		if writeLifecycleError(w, r, txErr, "change member role") {
			return
		}
		writeJSON(w, r, http.StatusOK, toMemberResponse(updated))
	}
}

// guardLastAdmin returns errLastAdmin when acting on an admin whose removal or
// demotion would leave the organization with no active admin (D-3). It only
// counts when the target is itself an admin -- acting on a plain user can never
// affect the admin count. Must run inside a transaction that has already called
// LockOrganizationForUpdate, so the count is stable.
func guardLastAdmin(ctx context.Context, txq *sqlcgen.Queries, orgID pgtype.UUID, targetRole string) error {
	if targetRole != "admin" {
		return nil
	}
	admins, err := txq.CountActiveAdmins(ctx, orgID)
	if err != nil {
		return fmt.Errorf("count active admins: %w", err)
	}
	if admins <= 1 {
		return errLastAdmin
	}
	return nil
}

// writeLifecycleError maps a lifecycle transaction's error to the right HTTP
// response and reports whether it wrote one. Shared by both handlers so the
// last-admin (409) / not-found (404) / internal (500) mapping stays identical.
func writeLifecycleError(w http.ResponseWriter, r *http.Request, err error, op string) bool {
	switch {
	case err == nil:
		return false
	case errors.Is(err, errLastAdmin):
		problem.Write(w, r, problem.Conflict("cannot remove or demote the organization's last admin"))
		return true
	case errors.Is(err, pgx.ErrNoRows):
		problem.Write(w, r, problem.NotFound("member not found"))
		return true
	default:
		logging.FromContext(r.Context()).ErrorContext(r.Context(), op+" failed", slog.Any("error", err))
		problem.Write(w, r, problem.Internal())
		return true
	}
}

// parseMemberUserID parses the {userId} path param. A malformed id can't match
// any real member, so it is a 404 (mirrors revokeInvitation's invalid
// {invitationId} handling) rather than a 422 -- the endpoint never reveals
// whether a well-formed-but-absent id exists either.
func parseMemberUserID(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	id, err := uuid.Parse(chi.URLParam(r, "userId"))
	if err != nil {
		problem.Write(w, r, problem.NotFound("member not found"))
		return uuid.UUID{}, false
	}
	return id, true
}

// toMemberResponse projects a membership row to the client-facing Member shape
// (contracts/openapi/organizations.openapi.yaml's Member schema) -- the same
// {user_id, role, status} listMembersHandler builds inline, shared here for the
// role-change response.
func toMemberResponse(m sqlcgen.OrganizationsMembership) MemberResponse {
	return MemberResponse{
		UserID: uuidString(m.UserID),
		Role:   m.Role,
		Status: m.Status,
	}
}
