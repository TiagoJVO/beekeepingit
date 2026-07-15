// Package api (this file) — the shared history-writing helper for #165
// (FR-HIS-1): every handler in this package that mutates organizations.
// organizations/memberships/invitations calls writeAuditLog to append one
// organizations.audit_log row in the SAME local transaction as its domain
// write (history.md §4), exactly mirroring #59's apiaries.audit_log pattern
// in services/apiaries/api/sync.go. entity_type distinguishes the three
// entities sharing this one table ("organization" | "membership" |
// "invitation", history.md §3/§9) — see organizations.go, invitations.go for
// the call sites.
package api

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/organizations/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

// entity_type discriminators for organizations.audit_log (history.md §3's
// polymorphic entity_type column, §9's "memberships, organizations,
// invitations | organizations | organizations.audit_log").
const (
	entityTypeOrganization = "organization"
	entityTypeMembership   = "membership"
	entityTypeInvitation   = "invitation"
)

// writeAuditLog appends one history.md §3 row for an applied create/update on
// entityType/entityID, in the same local transaction as the domain write
// (§4). before is the field map prior to the change (ignored for
// history.ChangeCreate — pass nil); after is the field map post-change.
// Field maps must carry only the entity's own scalar/soft-ID fields, never
// denormalized personal data (§7.3) — see the per-entity *Fields helpers.
func writeAuditLog(ctx context.Context, q *sqlcgen.Queries, orgID pgtype.UUID, entityType string, entityID pgtype.UUID, actorUserID pgtype.UUID, occurredAt pgtype.Timestamptz, changeType string, before, after map[string]any) error {
	changedFields, change, err := history.ComputeChange(changeType, before, after)
	if err != nil {
		return fmt.Errorf("compute organization change: %w", err)
	}

	changeJSON, err := json.Marshal(change)
	if err != nil {
		return fmt.Errorf("marshal organization change: %w", err)
	}

	if err := q.InsertAuditLog(ctx, sqlcgen.InsertAuditLogParams{
		ID:             pgtype.UUID{Bytes: uuid.New(), Valid: true},
		OrganizationID: orgID,
		EntityType:     entityType,
		EntityID:       entityID,
		ChangeType:     changeType,
		ActorUserID:    actorUserID,
		OccurredAt:     occurredAt,
		ChangedFields:  changedFields,
		Change:         changeJSON,
	}); err != nil {
		return fmt.Errorf("insert audit log: %w", err)
	}
	return nil
}

// organizationFields projects an organization row to the plain field map
// history.ComputeChange diffs — only the organization's own scalar/soft-ID
// fields (never a member's or actor's personal data, §7.3).
func organizationFields(o sqlcgen.OrganizationsOrganization) map[string]any {
	return map[string]any{
		"name":       o.Name,
		"address":    o.Address,
		"created_by": uuidString(o.CreatedBy),
	}
}

// membershipFields projects a membership row to the plain field map
// history.ComputeChange diffs — soft ID references only (user_id), never a
// denormalized member name/email (§7.3).
func membershipFields(m sqlcgen.OrganizationsMembership) map[string]any {
	return map[string]any{
		"user_id": uuidString(m.UserID),
		"role":    m.Role,
		"status":  m.Status,
	}
}

// invitationFields projects an invitation row to the plain field map
// history.ComputeChange diffs. The invitee's email is intentionally
// included: history.md §7.3 forbids denormalizing ANOTHER person's PII into
// an entity's audit trail (e.g. an actor's name/email folded into an
// apiary's change payload) — but here the email IS the invitation's own
// primary field (data-model.md §3's INVITATIONS.email), the thing the
// history entry is describing, exactly like an apiary's own `name`.
// data-model.md notes an invitee may have no identity.users row yet, so
// there is no soft ID to reference it by instead. The actor is still only
// ever actor_user_id (invited_by here) — never a name/email — so the
// pseudonymity contract on ACTOR identity is unaffected.
func invitationFields(inv sqlcgen.OrganizationsInvitation) map[string]any {
	return map[string]any{
		"email":      inv.Email,
		"role":       inv.Role,
		"status":     inv.Status,
		"invited_by": uuidString(inv.InvitedBy),
	}
}
