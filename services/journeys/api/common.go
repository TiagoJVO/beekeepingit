// Package api (this file) — shared helpers for the journeys service's HTTP
// surface, mirroring services/activities/api/common.go's own helpers
// verbatim (JWT + org-resolver + role, RFC 9457 responses) so the wiring
// pattern is already established and tested there.
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"

	sqlcgen "github.com/TiagoJVO/beekeepingit/services/journeys/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/logging"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/problem"
)

// entityTypeJourney/entityTypeJourneyPlanItem are this service's two sync
// wire entity types (services/sync/api/coordinator.go's routing key) — a
// journey's own fields (name/main_activity_type/status) and the "apiaries to
// visit" plan (FR-JO-4) sync as two separate PowerSync-local tables, mirroring
// how apiaries splits `apiary`/`apiary_counter` into two entity types owned
// by the same service (services/apiaries/api/sync.go).
const (
	entityTypeJourney         = "journey"
	entityTypeJourneyPlanItem = "journey_plan_item"
)

// requireOrg is the tenancy-context hand-off point (FR-TEN-2), mirroring
// activities/api/common.go's helper of the same name: it pulls the org id
// authn.NewOrgResolver already derived server-side from the verified token +
// membership (never a client-supplied header/body/query value) off the
// request's Claims. The org-resolver middleware guarantees these are
// present; a missing value is a wiring bug, surfaced as 500.
func requireOrg(w http.ResponseWriter, r *http.Request) (orgID pgtype.UUID, userID string, ok bool) {
	claims, found := authn.FromContext(r.Context())
	if !found || claims.OrganizationID == "" {
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "requireOrg: missing claims or empty organization_id (wiring bug: org-resolver middleware should guarantee these)")
		problem.Write(w, r, problem.Internal())
		return pgtype.UUID{}, "", false
	}
	parsed, err := uuid.Parse(claims.OrganizationID)
	if err != nil {
		logging.FromContext(r.Context()).ErrorContext(r.Context(), "requireOrg: organization_id claim is not a valid UUID", slog.Any("error", err))
		problem.Write(w, r, problem.Internal())
		return pgtype.UUID{}, "", false
	}
	return pgtype.UUID{Bytes: parsed, Valid: true}, claims.UserID, true
}

func writeJSON(w http.ResponseWriter, r *http.Request, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(v); err != nil {
		logging.FromContext(r.Context()).WarnContext(r.Context(), "write json response: encode failed", slog.Any("error", err))
	}
}

// errResponseWritten is withTx's sentinel for "the transaction function
// already wrote the HTTP response itself (a domain-expected outcome like
// 404/409, not an unexpected internal error) — the caller must not also log
// it or write a second (problem.Internal) response, just let the
// transaction abort quietly." Mirrors services/activities/api/common.go's
// identical helper.
var errResponseWritten = errors.New("journeys: response already written")

// withTx runs fn inside one pool transaction: begins, always defers a
// rollback (a no-op after a successful commit), and commits iff fn returns
// nil. Mirrors services/activities/api/common.go's withTx.
func withTx(ctx context.Context, pool *pgxpool.Pool, fn func(*sqlcgen.Queries) error) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after a successful Commit
	if err := fn(sqlcgen.New(tx)); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit tx: %w", err)
	}
	return nil
}

func uuidString(u pgtype.UUID) string { return uuid.UUID(u.Bytes).String() }

// isUniqueViolation reports whether err is a Postgres unique_violation
// (SQLSTATE 23505) — the client-generated id already exists. Mirrors
// services/activities/api/common.go's helper of the same name/purpose.
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// constraintName extracts the violated constraint's name from a Postgres
// unique_violation error, or "" if err isn't one — used to tell
// journey_plan_items' own two unique constraints apart (the PK, `id`, vs. the
// partial `(journey_id, apiary_id)` index) so applyJourneyPlanItemOp can
// distinguish a genuine id-collision idempotent-replay/conflict from "this
// apiary is already on the journey's plan via a different row id" (a benign
// no-op, not a conflict).
func constraintName(err error) string {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return pgErr.ConstraintName
	}
	return ""
}

// verifyApiaryIDs verifies every DISTINCT apiary id in ids against the
// apiaries service (ApiaryVerifier.BelongsToOrg), de-duplicated to ONE
// upstream call per distinct id — the same HIGH-severity fix
// services/activities/api/sync.go's resolveApiaryOwnership carries over
// (N ops/ids against the same apiary must cost one upstream call, not N).
// Shared by write.go's REST create/update (a plain id list) and sync.go's
// resolveApiaryOwnership (which first extracts the distinct ids out of a
// batch's ops before calling this). Fail-closed: a transport/5xx error
// verifying ANY distinct id aborts the whole call (returned error) rather
// than silently treating it as "not owned" — the caller must not write
// anything on an upstream outage it can't distinguish from a real
// rejection.
func verifyApiaryIDs(ctx context.Context, verifier *ApiaryVerifier, bearer string, ids []uuid.UUID) (map[string]bool, error) {
	owned := make(map[string]bool, len(ids))
	for _, id := range ids {
		key := id.String()
		if _, done := owned[key]; done {
			continue
		}
		belongs, err := verifier.BelongsToOrg(ctx, bearer, key)
		if err != nil {
			return nil, err
		}
		owned[key] = belongs
	}
	return owned, nil
}

func parseActor(ctx context.Context, userID string) pgtype.UUID {
	u, err := uuid.Parse(userID)
	if err != nil {
		logging.FromContext(ctx).ErrorContext(ctx, "parseActor: userID is not a valid UUID; audit actor will be recorded as NULL", slog.Any("error", err))
		return pgtype.UUID{Valid: false}
	}
	return pgtype.UUID{Bytes: u, Valid: true}
}
