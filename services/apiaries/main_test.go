package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/apiaries/api"
	"github.com/TiagoJVO/beekeepingit/services/apiaries/store"
	sqlcgen "github.com/TiagoJVO/beekeepingit/services/apiaries/store/sqlc/gen"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
	"github.com/TiagoJVO/beekeepingit/services/shared/history"
)

// testOrgHeader lets a test request stand in as a caller resolved to a
// different org/user/role than the devseed default — the only way these
// in-process tests can exercise TestApiariesSlice_CrossOrg* (#28 AC:
// "automated tests including cross-organization access attempts") without a
// live identity/organizations pair to resolve against. It's a test-only
// escape hatch on the fake injectClaims middleware, never read by
// production code (authn.NewOrgResolver derives Claims from the verified
// token + membership, never a header).
const testOrgHeader = "X-Test-Org-Claims"

// injectClaims stands in for the authn + org-resolver chain so these tests
// exercise the read + sync-apply logic directly with a known org/user. By
// default it uses the devseed principal; a request carrying testOrgHeader
// ("sub|userID|orgID|role") overrides it, so a single fixture/server can
// serve two distinct callers in the same test (cross-org assertions).
func injectClaims(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		claims := authn.Claims{
			Sub:            devseed.OidcSub,
			UserID:         devseed.UserID,
			OrganizationID: devseed.OrganizationID,
			Role:           devseed.MembershipRole,
		}
		if override := r.Header.Get(testOrgHeader); override != "" {
			parts := strings.SplitN(override, "|", 4)
			if len(parts) == 4 {
				claims = authn.Claims{Sub: parts[0], UserID: parts[1], OrganizationID: parts[2], Role: parts[3]}
			}
		}
		ctx := authn.ContextWithClaims(r.Context(), claims)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

type apiariesFixture struct {
	srv  *servicetemplate.Server
	pool *pgxpool.Pool
}

func newApiariesFixture(t *testing.T) *apiariesFixture {
	ctx := context.Background()
	const (
		dbUser = "beekeepingit_test"
		dbPass = "beekeepingit_test"
		dbName = "beekeepingit_test"
	)
	// postgis/postgis (not the plain postgres:16-alpine other services use):
	// this service's schema needs the postgis extension (location
	// geography(Point,4326), 00003_add_apiary_location.sql) — matching the
	// real cluster's CNPG postgis operand image (infra/helm/beekeepingit/
	// charts/postgres/values.yaml), just a standalone build of the same
	// extension rather than the CNPG-specific image.
	pg, err := tcpostgres.Run(ctx, "postgis/postgis:16-3.5",
		tcpostgres.WithUsername(dbUser),
		tcpostgres.WithPassword(dbPass),
		tcpostgres.WithDatabase(dbName),
		tcpostgres.BasicWaitStrategies(),
	)
	if err != nil {
		t.Fatalf("start postgres container: %v", err)
	}
	t.Cleanup(func() {
		if err := pg.Terminate(ctx); err != nil {
			t.Logf("terminate postgres container: %v", err)
		}
	})
	host, err := pg.Host(ctx)
	if err != nil {
		t.Fatalf("container host: %v", err)
	}
	port, err := pg.MappedPort(ctx, "5432/tcp")
	if err != nil {
		t.Fatalf("container mapped port: %v", err)
	}

	dbCfg := dbaccess.Config{Host: host, Port: port.Port(), User: dbUser, Password: dbPass, Database: dbName, SSLMode: "disable"}
	// Migrations no longer create the schema or the postgis extension
	// (infra's job in-cluster, cluster.yaml's postInitApplicationSQL) — both
	// stand in for that bootstrap step here.
	createSchema(ctx, t, dbCfg, "apiaries")
	createPostgisExtension(ctx, t, dbCfg)
	if err := dbaccess.Migrate(ctx, dbCfg.DSN(), store.MigrationsFS()); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := dbaccess.Connect(ctx, dbCfg)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	cfg := config.Config{ServiceName: "apiaries-test", HTTPAddr: ":0", LogLevel: slog.LevelInfo, DB: dbCfg}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	checks := health.NewRegistry()
	checks.Register("db", func(ctx context.Context) error { return pool.Ping(ctx) })
	srv, err := servicetemplate.New(cfg, nil, logger, checks)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	srv.Mount("/v1/apiaries", injectClaims(api.Router(pool)))
	srv.Mount("/internal/sync", injectClaims(api.InternalSyncRouter(pool)))

	return &apiariesFixture{srv: srv, pool: pool}
}

func (f *apiariesFixture) do(t *testing.T, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return f.doAs(t, "", method, path, body)
}

// doAs is like do, but callerHeader (built by callerClaims) stands the
// request in as a different resolved caller — the escape hatch
// injectClaims reads to let a single fixture serve two distinct
// orgs/users/roles in one test (cross-org assertions, #28 AC).
func (f *apiariesFixture) doAs(t *testing.T, callerHeader, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	return f.doAsWithHeaders(t, callerHeader, method, path, body, nil)
}

// doAsWithHeaders is doAs plus arbitrary extra request headers — the REST
// write handlers' If-Match/Idempotency-Key tests need to set headers doAs
// has no way to express.
func (f *apiariesFixture) doAsWithHeaders(t *testing.T, callerHeader, method, path string, body any, headers map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	var r io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		r = bytes.NewReader(b)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(method, path, r)
	if callerHeader != "" {
		req.Header.Set(testOrgHeader, callerHeader)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	f.srv.Router().ServeHTTP(rec, req)
	return rec
}

// callerClaims builds the testOrgHeader value for a synthetic caller
// distinct from the devseed default (a second org/user for cross-org tests).
func callerClaims(sub, userID, orgID, role string) string {
	return strings.Join([]string{sub, userID, orgID, role}, "|")
}

func (f *apiariesFixture) apply(t *testing.T, ops ...api.Op) api.ApplyResponse {
	t.Helper()
	return f.applyAs(t, "", ops...)
}

func (f *apiariesFixture) applyAs(t *testing.T, callerHeader string, ops ...api.Op) api.ApplyResponse {
	t.Helper()
	rec := f.doAs(t, callerHeader, http.MethodPost, "/internal/sync/apply", api.Batch{Ops: ops})
	if rec.Code != http.StatusOK {
		t.Fatalf("apply status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var out api.ApplyResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
		t.Fatalf("decode apply response: %v", err)
	}
	return out
}

func (f *apiariesFixture) conflictCount(t *testing.T) int {
	t.Helper()
	var n int
	if err := f.pool.QueryRow(context.Background(), "SELECT count(*) FROM apiaries.sync_conflict_log").Scan(&n); err != nil {
		t.Fatalf("count conflicts: %v", err)
	}
	return n
}

// auditRow is the subset of apiaries.audit_log columns (#59, history.md §3)
// the history tests below assert on.
type auditRow struct {
	ChangeType    string
	ActorUserID   string
	OccurredAt    time.Time
	RecordedAt    time.Time
	ChangedFields []string
	Change        json.RawMessage
}

// auditLogFor returns every apiaries.audit_log row for one entity, oldest
// first — the same ordering ListAuditLog uses.
func (f *apiariesFixture) auditLogFor(t *testing.T, entityID string) []auditRow {
	t.Helper()
	rows, err := f.pool.Query(context.Background(),
		`SELECT change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
		 FROM apiaries.audit_log
		 WHERE entity_type = 'apiary' AND entity_id = $1
		 ORDER BY recorded_at, id`, entityID)
	if err != nil {
		t.Fatalf("query audit_log: %v", err)
	}
	defer rows.Close()

	var out []auditRow
	for rows.Next() {
		var (
			a       auditRow
			actorID uuid.UUID
		)
		if err := rows.Scan(&a.ChangeType, &actorID, &a.OccurredAt, &a.RecordedAt, &a.ChangedFields, &a.Change); err != nil {
			t.Fatalf("scan audit_log row: %v", err)
		}
		a.ActorUserID = actorID.String()
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate audit_log: %v", err)
	}
	return out
}

// timelineRow is the subset of ListEntityTimeline's columns
// TestApiariesSlice_History_ConflictSurfacesInCombinedTimeline asserts on.
type timelineRow struct {
	EventKind  string
	OccurredAt time.Time
	RecordedAt time.Time
	Change     json.RawMessage
}

// timelineFor runs the #61 combined-timeline query (sqlcgen.ListEntityTimeline
// — audit_log UNION ALL sync_conflict_log, history.md §6) directly against
// the fixture's pool, the same way the other history helpers here read
// tables straight from the DB rather than through an (unexposed, #59/#61)
// HTTP surface.
func (f *apiariesFixture) timelineFor(t *testing.T, entityID string) []timelineRow {
	t.Helper()
	id, err := uuid.Parse(entityID)
	if err != nil {
		t.Fatalf("parse entityID: %v", err)
	}
	q := sqlcgen.New(f.pool)
	rows, err := q.ListEntityTimeline(context.Background(), sqlcgen.ListEntityTimelineParams{
		OrganizationID: pgtype.UUID{Bytes: uuid.MustParse(devseed.OrganizationID), Valid: true},
		EntityType:     "apiary",
		EntityID:       pgtype.UUID{Bytes: id, Valid: true},
	})
	if err != nil {
		t.Fatalf("ListEntityTimeline: %v", err)
	}
	out := make([]timelineRow, 0, len(rows))
	for _, r := range rows {
		out = append(out, timelineRow{
			EventKind:  r.EventKind,
			OccurredAt: r.OccurredAt.Time,
			RecordedAt: r.RecordedAt.Time,
			Change:     r.Change,
		})
	}
	return out
}

func putOp(id, name string, hive int32, ts time.Time) api.Op {
	data, _ := json.Marshal(map[string]any{"name": name, "hive_count": hive})
	return api.Op{Op: "put", EntityType: "apiary", ID: id, Data: data, UpdatedAt: ts}
}

func patchHive(id string, hive int32, ts time.Time) api.Op {
	data, _ := json.Marshal(map[string]any{"hive_count": hive})
	return api.Op{Op: "patch", EntityType: "apiary", ID: id, Data: data, UpdatedAt: ts}
}

func patchNotes(id, notes string, ts time.Time) api.Op {
	data, _ := json.Marshal(map[string]any{"notes": notes})
	return api.Op{Op: "patch", EntityType: "apiary", ID: id, Data: data, UpdatedAt: ts}
}

// TestApiariesSlice_CreateReadLWWConflictIdempotencyTombstone walks the whole
// apply/read matrix the skeleton must guarantee (sync.md §4–§5).
func TestApiariesSlice_CreateReadLWWConflictIdempotencyTombstone(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	// ① Create (put) → applied, and readable via the client-facing read path.
	if got := f.apply(t, putOp(id, "Encosta Nova", 0, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}
	if a := f.getApiary(t, id); a.Name != "Encosta Nova" || a.HiveCount != 0 {
		t.Fatalf("read after create = %+v", a)
	}

	// ② Newer edit wins.
	if got := f.apply(t, patchHive(id, 12, t0.Add(time.Minute))); got.Results[0].Result != "applied" {
		t.Fatalf("newer edit result = %q, want applied", got.Results[0].Result)
	}
	if a := f.getApiary(t, id); a.HiveCount != 12 {
		t.Fatalf("hive_count after newer edit = %d, want 12", a.HiveCount)
	}

	// ③ Older edit loses → superseded, server value kept, conflict logged.
	if got := f.apply(t, patchHive(id, 99, t0.Add(-time.Minute))); got.Results[0].Result != "superseded" {
		t.Fatalf("older edit result = %q, want superseded", got.Results[0].Result)
	}
	if a := f.getApiary(t, id); a.HiveCount != 12 {
		t.Fatalf("hive_count after superseded edit = %d, want 12 (server kept)", a.HiveCount)
	}
	if n := f.conflictCount(t); n != 1 {
		t.Fatalf("conflict rows = %d, want 1", n)
	}

	// ④ Idempotent re-send of the winning edit → applied, no new conflict, no change.
	if got := f.apply(t, patchHive(id, 12, t0.Add(time.Minute))); got.Results[0].Result != "applied" {
		t.Fatalf("idempotent re-send result = %q, want applied", got.Results[0].Result)
	}
	if n := f.conflictCount(t); n != 1 {
		t.Fatalf("conflict rows after idempotent re-send = %d, want 1", n)
	}

	// ⑤ Delete (tombstone) → applied; hidden from read.
	delOp := api.Op{Op: "delete", EntityType: "apiary", ID: id, UpdatedAt: t0.Add(2 * time.Minute)}
	if got := f.apply(t, delOp); got.Results[0].Result != "applied" {
		t.Fatalf("delete result = %q, want applied", got.Results[0].Result)
	}
	if rec := f.do(t, http.MethodGet, "/v1/apiaries/"+id, nil); rec.Code != http.StatusNotFound {
		t.Fatalf("get after delete status = %d, want 404", rec.Code)
	}
	if list := f.listApiaries(t); len(list.Data) != 0 {
		t.Fatalf("list after delete = %d rows, want 0", len(list.Data))
	}
}

// TestApiariesSlice_History_CreateUpdateDeleteEachProduceOneAuditRow is #59's
// core AC: every applied create/update/delete writes exactly one correctly
// attributed apiaries.audit_log row (history.md §3-§4), with occurred_at =
// the op's device timestamp and recorded_at ≈ server time.
func TestApiariesSlice_History_CreateUpdateDeleteEachProduceOneAuditRow(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	before := time.Now().Add(-time.Second)

	// Create.
	if got := f.apply(t, putOp(id, "Encosta Nova", 3, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}
	rows := f.auditLogFor(t, id)
	if len(rows) != 1 {
		t.Fatalf("audit rows after create = %d, want 1: %+v", len(rows), rows)
	}
	create := rows[0]
	if create.ChangeType != "create" {
		t.Fatalf("create audit change_type = %q, want create", create.ChangeType)
	}
	if create.ActorUserID != devseed.UserID {
		t.Fatalf("create audit actor_user_id = %q, want %q", create.ActorUserID, devseed.UserID)
	}
	if !create.OccurredAt.Equal(t0) {
		t.Fatalf("create audit occurred_at = %v, want %v (device time)", create.OccurredAt, t0)
	}
	if create.RecordedAt.Before(before) || create.RecordedAt.After(time.Now().Add(time.Second)) {
		t.Fatalf("create audit recorded_at = %v, want close to server now (%v)", create.RecordedAt, before)
	}
	if create.ChangedFields != nil {
		t.Fatalf("create audit changed_fields = %v, want nil (create carries a baseline, not a diff)", create.ChangedFields)
	}
	var createChange map[string]any
	if err := json.Unmarshal(create.Change, &createChange); err != nil {
		t.Fatalf("unmarshal create change: %v", err)
	}
	if createChange["name"] != "Encosta Nova" || createChange["hive_count"] != float64(3) {
		t.Fatalf("create change = %+v, want the baseline field values", createChange)
	}

	// Update (newer edit wins, §4.1).
	t1 := t0.Add(time.Minute)
	if got := f.apply(t, patchHive(id, 12, t1)); got.Results[0].Result != "applied" {
		t.Fatalf("update result = %q, want applied", got.Results[0].Result)
	}
	rows = f.auditLogFor(t, id)
	if len(rows) != 2 {
		t.Fatalf("audit rows after update = %d, want 2: %+v", len(rows), rows)
	}
	update := rows[1]
	if update.ChangeType != "update" {
		t.Fatalf("update audit change_type = %q, want update", update.ChangeType)
	}
	if !update.OccurredAt.Equal(t1) {
		t.Fatalf("update audit occurred_at = %v, want %v", update.OccurredAt, t1)
	}
	if len(update.ChangedFields) != 1 || update.ChangedFields[0] != "hive_count" {
		t.Fatalf("update audit changed_fields = %v, want [hive_count]", update.ChangedFields)
	}
	var updateChange map[string]any
	if err := json.Unmarshal(update.Change, &updateChange); err != nil {
		t.Fatalf("unmarshal update change: %v", err)
	}
	hiveDelta, ok := updateChange["hive_count"].(map[string]any)
	if !ok {
		t.Fatalf("update change[hive_count] = %#v, want a {from,to} object", updateChange["hive_count"])
	}
	if hiveDelta["from"] != float64(3) || hiveDelta["to"] != float64(12) {
		t.Fatalf("update change[hive_count] = %+v, want from=3 to=12", hiveDelta)
	}
	if _, ok := updateChange["name"]; ok {
		t.Fatalf("update change unexpectedly contains unchanged field name: %+v", updateChange)
	}

	// Delete (tombstone, §4.5/§6).
	t2 := t0.Add(2 * time.Minute)
	delOp := api.Op{Op: "delete", EntityType: "apiary", ID: id, UpdatedAt: t2}
	if got := f.apply(t, delOp); got.Results[0].Result != "applied" {
		t.Fatalf("delete result = %q, want applied", got.Results[0].Result)
	}
	rows = f.auditLogFor(t, id)
	if len(rows) != 3 {
		t.Fatalf("audit rows after delete = %d, want 3: %+v", len(rows), rows)
	}
	del := rows[2]
	if del.ChangeType != "delete" {
		t.Fatalf("delete audit change_type = %q, want delete", del.ChangeType)
	}
	if !del.OccurredAt.Equal(t2) {
		t.Fatalf("delete audit occurred_at = %v, want %v", del.OccurredAt, t2)
	}
	if del.ChangedFields != nil {
		t.Fatalf("delete audit changed_fields = %v, want nil", del.ChangedFields)
	}
	var delChange map[string]any
	if err := json.Unmarshal(del.Change, &delChange); err != nil {
		t.Fatalf("unmarshal delete change: %v", err)
	}
	if delChange["deleted"] != true {
		t.Fatalf("delete change = %+v, want a {deleted:true} tombstone", delChange)
	}
	for _, forbidden := range []string{"name", "hive_count"} {
		if _, ok := delChange[forbidden]; ok {
			t.Fatalf("delete tombstone leaked field value %q: %+v", forbidden, delChange)
		}
	}
}

// TestApiariesSlice_History_IdempotentReplayWritesNoNewAuditRow is #59's
// idempotency AC (history.md §4 "Idempotency"): a replayed/forward-retried
// op that no-ops the domain write must not double-count history.
func TestApiariesSlice_History_IdempotentReplayWritesNoNewAuditRow(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	if got := f.apply(t, putOp(id, "Encosta Nova", 0, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}
	winningOp := patchHive(id, 12, t0.Add(time.Minute))
	if got := f.apply(t, winningOp); got.Results[0].Result != "applied" {
		t.Fatalf("update result = %q, want applied", got.Results[0].Result)
	}
	countBefore := len(f.auditLogFor(t, id))
	if countBefore != 2 {
		t.Fatalf("audit rows before replay = %d, want 2", countBefore)
	}

	// Re-send the exact same (already-applied) op — same client UUID PK,
	// same value and timestamp as the current stored state.
	if got := f.apply(t, winningOp); got.Results[0].Result != "applied" {
		t.Fatalf("idempotent re-send result = %q, want applied", got.Results[0].Result)
	}
	if n := len(f.auditLogFor(t, id)); n != countBefore {
		t.Fatalf("audit rows after idempotent replay = %d, want unchanged %d", n, countBefore)
	}
}

// TestApiariesSlice_History_LWWLossWritesNoDomainAuditRow is #59's LWW-loss
// AC: a losing offline edit applies no domain change, so it must not write a
// domain audit_log row — only the existing sync_conflict_log row (history.md
// §6 "LWW losers are not lost" via sync_conflict_log, not audit_log).
func TestApiariesSlice_History_LWWLossWritesNoDomainAuditRow(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	if got := f.apply(t, putOp(id, "Encosta Nova", 0, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}
	if got := f.apply(t, patchHive(id, 12, t0.Add(time.Minute))); got.Results[0].Result != "applied" {
		t.Fatalf("update result = %q, want applied", got.Results[0].Result)
	}
	countBefore := len(f.auditLogFor(t, id))
	if countBefore != 2 {
		t.Fatalf("audit rows before losing edit = %d, want 2", countBefore)
	}

	// An older edit loses (§4.1) — superseded, server value kept.
	if got := f.apply(t, patchHive(id, 99, t0.Add(-time.Minute))); got.Results[0].Result != "superseded" {
		t.Fatalf("older edit result = %q, want superseded", got.Results[0].Result)
	}
	if n := f.conflictCount(t); n != 1 {
		t.Fatalf("conflict rows = %d, want 1", n)
	}
	if n := len(f.auditLogFor(t, id)); n != countBefore {
		t.Fatalf("audit rows after LWW loss = %d, want unchanged %d (loss goes to sync_conflict_log only)", n, countBefore)
	}
}

// TestApiariesSlice_History_ConflictSurfacesInCombinedTimeline is #61's
// end-to-end conflict AC: two devices editing the same apiary offline, whose
// pushes reach the server out of device-clock order (an older-timestamped op
// arrives AFTER a newer one has already applied — the realistic offline
// scenario, not just "two ops in one batch"). It asserts:
//   - the winning edit (device B, same-org other user) has an audit_log row;
//   - the losing edit (device A, the default devseed user) has a
//     sync_conflict_log row instead, preserving its payload (history.md §6
//     "LWW losers are not lost");
//   - ListEntityTimeline (#61) returns both in correct chronological order
//     (by recorded_at, matching ListAuditLog's own ordering), with the loser
//     tagged event_kind = history.EventSuperseded rather than silently
//     missing from the combined read.
func TestApiariesSlice_History_ConflictSurfacesInCombinedTimeline(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	otherUser := sameOrgOtherUserCaller() // same org, distinct actor (sync.md §3.1)
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	// Device A (default devseed user) creates the apiary while both devices
	// are offline.
	if got := f.apply(t, putOp(id, "Encosta Nova", 3, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}

	// Device B (a different member of the same org) is the first to reach
	// the network and pushes a NEWER offline edit — it applies and wins.
	winningTS := t0.Add(2 * time.Minute)
	winningOp := patchHive(id, 20, winningTS)
	if got := f.applyAs(t, otherUser, winningOp); got.Results[0].Result != "applied" {
		t.Fatalf("device B (winning) edit result = %q, want applied", got.Results[0].Result)
	}

	// Device A regains connectivity later and pushes its own OLDER offline
	// edit (made before device B's, per its device clock) — it reaches the
	// server AFTER the newer edit already applied. Per §4.1 it loses: the
	// server value is kept and the loss is logged, not silently dropped.
	losingTS := t0.Add(time.Minute)
	losingOp := patchHive(id, 12, losingTS)
	if got := f.apply(t, losingOp); got.Results[0].Result != "superseded" {
		t.Fatalf("device A (losing) edit result = %q, want superseded", got.Results[0].Result)
	}

	// Server converges on device B's value.
	if a := f.getApiary(t, id); a.HiveCount != 20 {
		t.Fatalf("hive_count after conflict = %d, want 20 (device B's winning edit)", a.HiveCount)
	}

	// The winning edit has its own audit_log row (create + this update = 2).
	audit := f.auditLogFor(t, id)
	if len(audit) != 2 {
		t.Fatalf("audit rows = %d, want 2 (create + device B's winning update): %+v", len(audit), audit)
	}
	winningAudit := audit[1]
	if winningAudit.ChangeType != "update" {
		t.Fatalf("winning audit change_type = %q, want update", winningAudit.ChangeType)
	}
	if !winningAudit.OccurredAt.Equal(winningTS) {
		t.Fatalf("winning audit occurred_at = %v, want %v (device B's timestamp)", winningAudit.OccurredAt, winningTS)
	}

	// The losing edit produced exactly one sync_conflict_log row (device A's
	// payload preserved), and no matching domain audit_log row.
	if n := f.conflictCount(t); n != 1 {
		t.Fatalf("conflict rows = %d, want 1", n)
	}

	// ListEntityTimeline (#61) returns both events, chronologically ordered,
	// with the loser tagged as a superseded timeline event alongside the
	// applied changes — history.md §6's combined read.
	timeline := f.timelineFor(t, id)
	if len(timeline) != 3 {
		t.Fatalf("timeline rows = %d, want 3 (create, device B update, device A superseded): %+v", len(timeline), timeline)
	}
	if timeline[0].EventKind != "create" {
		t.Fatalf("timeline[0].EventKind = %q, want create", timeline[0].EventKind)
	}
	if timeline[1].EventKind != "update" {
		t.Fatalf("timeline[1].EventKind = %q, want update (device B's winning edit)", timeline[1].EventKind)
	}
	if !timeline[1].OccurredAt.Equal(winningTS) {
		t.Fatalf("timeline[1].OccurredAt = %v, want %v", timeline[1].OccurredAt, winningTS)
	}
	superseded := timeline[2]
	if superseded.EventKind != history.EventSuperseded {
		t.Fatalf("timeline[2].EventKind = %q, want %q (device A's losing edit)", superseded.EventKind, history.EventSuperseded)
	}
	if !superseded.OccurredAt.Equal(losingTS) {
		t.Fatalf("timeline[2].OccurredAt = %v, want %v (device A's device timestamp preserved, not dropped)", superseded.OccurredAt, losingTS)
	}
	// The superseded row's recorded_at (server time it was logged) must
	// order it AFTER the winning update, matching apply order, not device
	// clock order — the same "occurred then, recorded now" property #59
	// already proved for audit_log, now proven across the combined read.
	if !superseded.RecordedAt.After(timeline[1].RecordedAt) {
		t.Fatalf("superseded recorded_at %v not after winning update's recorded_at %v", superseded.RecordedAt, timeline[1].RecordedAt)
	}
	var conflictChange map[string]any
	if err := json.Unmarshal(superseded.Change, &conflictChange); err != nil {
		t.Fatalf("unmarshal superseded change: %v", err)
	}
	if _, ok := conflictChange["losing_payload"]; !ok {
		t.Fatalf("superseded change = %+v, want a losing_payload field preserving device A's edit", conflictChange)
	}
	if _, ok := conflictChange["winning_payload"]; !ok {
		t.Fatalf("superseded change = %+v, want a winning_payload field", conflictChange)
	}
	if conflictChange["winner"] != "server" {
		t.Fatalf("superseded change[winner] = %v, want server", conflictChange["winner"])
	}
}

// TestApiariesSlice_History_ChangePayloadNeverEmbedsPersonalData is #59's
// pseudonymity contract test (history.md §7.3): the change JSONB must never
// contain a denormalized name/email — only opaque IDs and the apiary's own
// (non-personal) fields. actor identity lives solely in actor_user_id.
func TestApiariesSlice_History_ChangePayloadNeverEmbedsPersonalData(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	if got := f.apply(t, putOp(id, "Encosta Nova", 3, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}
	if got := f.apply(t, patchHive(id, 12, t0.Add(time.Minute))); got.Results[0].Result != "applied" {
		t.Fatalf("update result = %q, want applied", got.Results[0].Result)
	}
	delOp := api.Op{Op: "delete", EntityType: "apiary", ID: id, UpdatedAt: t0.Add(2 * time.Minute)}
	if got := f.apply(t, delOp); got.Results[0].Result != "applied" {
		t.Fatalf("delete result = %q, want applied", got.Results[0].Result)
	}

	// devseed's known PII — if it ever leaked into a change payload it would
	// appear verbatim as one of these substrings.
	forbidden := []string{devseed.UserName, devseed.UserEmail}

	for _, row := range f.auditLogFor(t, id) {
		body := string(row.Change)
		for _, pii := range forbidden {
			if strings.Contains(body, pii) {
				t.Fatalf("audit change payload for change_type=%s contains denormalized PII %q: %s", row.ChangeType, pii, body)
			}
		}
		// change must decode to a JSON object whose values are only
		// strings/numbers/bools/nested from/to pairs, never something that
		// looks like a free-text name field.
		var decoded map[string]any
		if err := json.Unmarshal(row.Change, &decoded); err != nil {
			t.Fatalf("change payload is not a JSON object: %s", body)
		}
		if _, ok := decoded["actor_name"]; ok {
			t.Fatalf("change payload embeds an actor_name field: %s", body)
		}
		if _, ok := decoded["email"]; ok {
			t.Fatalf("change payload embeds an email field: %s", body)
		}
	}
}

func TestApiariesSlice_ValidateRejectsBadOps(t *testing.T) {
	f := newApiariesFixture(t)
	// put with empty name is invalid.
	bad := api.Op{Op: "put", EntityType: "apiary", ID: uuid.NewString(),
		Data: json.RawMessage(`{"name":""}`), UpdatedAt: time.Now()}
	rec := f.do(t, http.MethodPost, "/internal/sync/validate", api.Batch{Ops: []api.Op{bad}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("validate status = %d, want 422, body = %s", rec.Code, rec.Body.String())
	}
}

// otherOrgCaller is a second, distinct principal (org B) used by the
// cross-org tests below — a different sub/user/org from devseed's (org A),
// so the two calls in each test are genuinely two different tenants, not
// just two requests with the same claims.
func otherOrgCaller() string {
	return callerClaims(
		"22222222-2222-4222-8222-222222222222",
		"a0000000-0000-7000-8000-000000000002",
		"b0000000-0000-7000-8000-000000000002",
		"admin",
	)
}

// TestApiariesSlice_CrossOrg_GetReturns404NotFound is the #28 AC's
// "requests for resources outside the caller's organization are denied
// (403/404)" case for apiaries: org B must not be able to read org A's
// apiary by id, and the response must be 404 (ADR-0002 scope-hiding), not a
// distinguishable "exists but forbidden" signal.
func TestApiariesSlice_CrossOrg_GetReturns404NotFound(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	// devseed's org (org A) creates an apiary.
	if got := f.apply(t, putOp(id, "Org A Apiary", 5, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}

	// Org B (a different caller entirely) tries to read it directly by id.
	other := otherOrgCaller()
	rec := f.doAs(t, other, http.MethodGet, "/v1/apiaries/"+id, nil)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("cross-org get status = %d, want 404, body = %s", rec.Code, rec.Body.String())
	}
}

// TestApiariesSlice_CrossOrg_ListNeverIncludesOtherOrgsRows guards the list
// endpoint the same way: org B's list must never contain org A's rows, even
// though both orgs have data.
func TestApiariesSlice_CrossOrg_ListNeverIncludesOtherOrgsRows(t *testing.T) {
	f := newApiariesFixture(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	other := otherOrgCaller()

	idA := uuid.NewString()
	if got := f.apply(t, putOp(idA, "Org A Apiary", 1, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create org A apiary result = %q, want applied", got.Results[0].Result)
	}
	idB := uuid.NewString()
	if got := f.applyAs(t, other, putOp(idB, "Org B Apiary", 2, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create org B apiary result = %q, want applied", got.Results[0].Result)
	}

	// Org A's list contains only its own apiary.
	listA := f.listApiaries(t)
	if len(listA.Data) != 1 || listA.Data[0].ID != idA {
		t.Fatalf("org A list = %+v, want exactly [%s]", listA.Data, idA)
	}

	// Org B's list contains only its own apiary — never org A's.
	rec := f.doAs(t, other, http.MethodGet, "/v1/apiaries", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("org B list status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var listB listView
	if err := json.Unmarshal(rec.Body.Bytes(), &listB); err != nil {
		t.Fatalf("decode org B list: %v", err)
	}
	if len(listB.Data) != 1 || listB.Data[0].ID != idB {
		t.Fatalf("org B list = %+v, want exactly [%s]", listB.Data, idB)
	}
}

// TestApiariesSlice_CrossOrg_SyncApplyCannotMutateOtherOrgsRow is the write
// half of the same guarantee: org B's sync-apply batch addressing org A's
// apiary id must not mutate — or delete — it. GetApiaryForUpdate is
// org-scoped (sync.go's applyOp), so from org B's perspective org A's row
// simply doesn't exist; a delete op against it is the safe, PK-collision-free
// way to prove that (applyOp's "missing row + delete ⇒ nothing to tombstone"
// branch never touches the database). A put/patch op would instead attempt
// an INSERT reusing org A's id as the (bare, non-org-scoped) primary key,
// which collides at the DB level — a real but separate schema question
// (whether apiaries.apiaries should be keyed by (organization_id, id)) that's
// #30's tenancy-model territory, not this test's concern. Confirms FR-TEN-2
// holds on the write path, not just reads.
func TestApiariesSlice_CrossOrg_SyncApplyCannotMutateOtherOrgsRow(t *testing.T) {
	f := newApiariesFixture(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	other := otherOrgCaller()

	id := uuid.NewString()
	if got := f.apply(t, putOp(id, "Org A Apiary", 5, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create org A apiary result = %q, want applied", got.Results[0].Result)
	}

	// Org B "deletes" org A's id — from org B's org-scoped view the row
	// doesn't exist, so this must be a no-op against the database, not an
	// actual delete of org A's apiary.
	delOp := api.Op{Op: "delete", EntityType: "apiary", ID: id, UpdatedAt: t0.Add(time.Minute)}
	if got := f.applyAs(t, other, delOp); got.Results[0].Result != "applied" {
		t.Fatalf("org B delete-of-unknown-id result = %q, want applied (no-op)", got.Results[0].Result)
	}

	// Org A's own apiary is untouched and still live.
	if a := f.getApiary(t, id); a.HiveCount != 5 {
		t.Fatalf("org A apiary hive_count = %d, want 5 (untouched by org B's delete attempt)", a.HiveCount)
	}

	// Org B still can't see it either (it was never org B's to begin with).
	recB := f.doAs(t, other, http.MethodGet, "/v1/apiaries/"+id, nil)
	if recB.Code != http.StatusNotFound {
		t.Fatalf("org B get status = %d, want 404, body = %s", recB.Code, recB.Body.String())
	}
}

// sameOrgOtherUserCaller is a second principal in the SAME org as devseed
// (org A) but a distinct sub/user — used by
// TestApiariesSlice_SameOrg_DifferentUsersSeeSameApiaries to prove the slice
// is organization-first with no accidental per-user narrowing (sync.md §3.1,
// #57 AC "activity ownership is preserved... without breaking
// organization-wide sharing").
func sameOrgOtherUserCaller() string {
	return callerClaims(
		"33333333-3333-4333-8333-333333333333",
		"a0000000-0000-7000-8000-000000000003",
		devseed.OrganizationID, // same org as the default devseed caller
		"member",
	)
}

// TestApiariesSlice_SameOrg_DifferentUsersSeeSameApiaries is #57's AC
// "activity ownership is preserved by also scoping per user where required,
// without breaking organization-wide sharing of apiaries" and sync.md §3.1's
// "organization-first, user is attribution only": two distinct users who are
// both active members of the SAME org must see the exact same apiaries list
// — sync is org-scoped, never additionally filtered by the requesting user.
// This guards against a regression that would (incorrectly) start scoping
// reads by caller identity instead of by organization_id alone.
func TestApiariesSlice_SameOrg_DifferentUsersSeeSameApiaries(t *testing.T) {
	f := newApiariesFixture(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	otherUser := sameOrgOtherUserCaller()

	// One of the two same-org users creates the data (attribution differs;
	// visibility must not).
	idOne := uuid.NewString()
	if got := f.apply(t, putOp(idOne, "Encosta Norte", 3, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create apiary result = %q, want applied", got.Results[0].Result)
	}
	idTwo := uuid.NewString()
	if got := f.applyAs(t, otherUser, putOp(idTwo, "Encosta Sul", 7, t0.Add(time.Second))); got.Results[0].Result != "applied" {
		t.Fatalf("second same-org user create result = %q, want applied", got.Results[0].Result)
	}

	// Default devseed user's list contains BOTH apiaries...
	listDefault := f.listApiaries(t)
	if len(listDefault.Data) != 2 {
		t.Fatalf("default user list = %+v, want 2 rows (both org apiaries)", listDefault.Data)
	}

	// ...and so does the other same-org user's list: identical membership,
	// not a per-user subset.
	recOther := f.doAs(t, otherUser, http.MethodGet, "/v1/apiaries", nil)
	if recOther.Code != http.StatusOK {
		t.Fatalf("other user list status = %d, want 200, body = %s", recOther.Code, recOther.Body.String())
	}
	var listOther listView
	if err := json.Unmarshal(recOther.Body.Bytes(), &listOther); err != nil {
		t.Fatalf("decode other user list: %v", err)
	}
	if len(listOther.Data) != 2 {
		t.Fatalf("other same-org user list = %+v, want 2 rows (both org apiaries)", listOther.Data)
	}

	gotIDs := map[string]bool{listDefault.Data[0].ID: true, listDefault.Data[1].ID: true}
	wantIDs := map[string]bool{idOne: true, idTwo: true}
	if len(gotIDs) != 2 || !gotIDs[idOne] || !gotIDs[idTwo] {
		t.Fatalf("default user list ids = %v, want %v", gotIDs, wantIDs)
	}
	otherIDs := map[string]bool{listOther.Data[0].ID: true, listOther.Data[1].ID: true}
	if len(otherIDs) != 2 || !otherIDs[idOne] || !otherIDs[idTwo] {
		t.Fatalf("other user list ids = %v, want %v", otherIDs, wantIDs)
	}

	// Each user can also directly GET the apiary the OTHER user created —
	// same-org visibility is symmetric, not scoped to "my own rows".
	if a := f.getApiary(t, idTwo); a.HiveCount != 7 {
		t.Fatalf("default user reading other user's apiary hive_count = %d, want 7", a.HiveCount)
	}
	recCross := f.doAs(t, otherUser, http.MethodGet, "/v1/apiaries/"+idOne, nil)
	if recCross.Code != http.StatusOK {
		t.Fatalf("other user reading first user's apiary status = %d, want 200", recCross.Code)
	}
}

// TestApiariesSlice_SyncApply_OrgIsAlwaysTokenResolved_NeverClientSupplied is
// #57's AC "the replication scope is enforced server-side, not only filtered
// on the client": the sync-apply Op/apiaryData wire shape (services/apiaries/
// api/sync.go) carries no organization_id field at all — org-scoping comes
// exclusively from requireOrg reading the token-resolved Claims in context
// (common.go), never from anything in the request. This test proves a
// forged "organization_id" smuggled into the op's data payload (as though a
// compromised/buggy client tried to claim a different org) has zero effect:
// the row is still created under the CALLER's real (token-resolved) org —
// here, org B — not the org named in the payload (org A's id).
func TestApiariesSlice_SyncApply_OrgIsAlwaysTokenResolved_NeverClientSupplied(t *testing.T) {
	f := newApiariesFixture(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	other := otherOrgCaller()

	id := uuid.NewString()
	// The payload smuggles an organization_id claiming devseed's org (org A),
	// but the request is authenticated/resolved as org B (via testOrgHeader,
	// standing in for the token-resolved claims in production). apiaryData
	// has no OrganizationID field, so json.Unmarshal silently drops the
	// unknown key — the same outcome a real client's forged field would get.
	forgedData := json.RawMessage(`{"name":"Forged Org Claim","hive_count":9,"organization_id":"` + devseed.OrganizationID + `"}`)
	op := api.Op{Op: "put", EntityType: "apiary", ID: id, Data: forgedData, UpdatedAt: t0}
	if got := f.applyAs(t, other, op); got.Results[0].Result != "applied" {
		t.Fatalf("apply with forged organization_id result = %q, want applied", got.Results[0].Result)
	}

	// The row lands under org B (the token-resolved caller), so org B can
	// read it back...
	recB := f.doAs(t, other, http.MethodGet, "/v1/apiaries/"+id, nil)
	if recB.Code != http.StatusOK {
		t.Fatalf("org B (real caller) get status = %d, want 200, body = %s", recB.Code, recB.Body.String())
	}

	// ...and org A (the org forged into the payload) must NOT see it: the
	// forged field never reached the org-scoping query param.
	recA := f.do(t, http.MethodGet, "/v1/apiaries/"+id, nil)
	if recA.Code != http.StatusNotFound {
		t.Fatalf("org A (forged target) get status = %d, want 404 — forged organization_id must have no effect, body = %s", recA.Code, recA.Body.String())
	}
	listA := f.listApiaries(t)
	for _, a := range listA.Data {
		if a.ID == id {
			t.Fatalf("org A's list leaked the forged-org row %s; forged organization_id in op data must be ignored", id)
		}
	}
}

// TestApiariesSchema_EveryOwnedTableCarriesOrganizationID is the automated
// form of #30's AC "every owned row (apiary, activity, journey, and other
// org-owned entities) carries an organization_id": rather than a one-time
// manual read of the migration files, this runs against the real, migrated
// apiaries schema so a future migration that adds a table without
// organization_id fails CI (dbaccess.UnscopedTables, shared across services).
// apiaries has no exempt (tenant-root/global-identity) tables of its own —
// unlike identity.users or organizations.organizations — so every base
// table here is expected to be scoped.
func TestApiariesSchema_EveryOwnedTableCarriesOrganizationID(t *testing.T) {
	f := newApiariesFixture(t)

	unscoped, err := dbaccess.UnscopedTables(context.Background(), f.pool, "apiaries")
	if err != nil {
		t.Fatalf("UnscopedTables: %v", err)
	}
	if len(unscoped) != 0 {
		t.Fatalf("apiaries schema has table(s) missing organization_id: %v", unscoped)
	}
}

// TestApiariesSlice_ResponsesConformToOpenAPIContract exercises the
// client-facing read surface (GET /v1/apiaries[/{id}]) through the real
// server and validates each response against contracts/openapi/apiaries —
// the "contract tests at boundaries" AC of #153. It's a boundary test, not a
// functional one: TestApiariesSlice_CreateReadLWWConflictIdempotencyTombstone
// already covers the read/apply semantics this reuses.
func TestApiariesSlice_ResponsesConformToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/apiaries.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}

	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if got := f.apply(t, putOp(id, "Quinta do Vale", 3, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}

	getPath := "/v1/apiaries/" + id
	recGet := f.do(t, http.MethodGet, getPath, nil)
	if recGet.Code != http.StatusOK {
		t.Fatalf("get status = %d, want 200", recGet.Code)
	}
	doc.ValidateResponseBody(t, http.MethodGet, getPath, http.StatusOK, recGet.Body.Bytes())

	recList := f.do(t, http.MethodGet, "/v1/apiaries", nil)
	if recList.Code != http.StatusOK {
		t.Fatalf("list status = %d, want 200", recList.Code)
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/apiaries", http.StatusOK, recList.Body.Bytes())

	// A deleted resource's 404 must still be a well-formed Problem response.
	delOp := api.Op{Op: "delete", EntityType: "apiary", ID: id, UpdatedAt: t0.Add(time.Minute)}
	if got := f.apply(t, delOp); got.Results[0].Result != "applied" {
		t.Fatalf("delete result = %q, want applied", got.Results[0].Result)
	}
	recGone := f.do(t, http.MethodGet, getPath, nil)
	if recGone.Code != http.StatusNotFound {
		t.Fatalf("get-after-delete status = %d, want 404", recGone.Code)
	}
	doc.ValidateResponseBody(t, http.MethodGet, getPath, http.StatusNotFound, recGone.Body.Bytes())
}

// TestApiariesRest_ResponsesConformToOpenAPIContract is
// TestApiariesSlice_ResponsesConformToOpenAPIContract's counterpart for the
// REST write surface this issue (#31) adds: POST's 201, PATCH's 200, and a
// validation failure's 422 all validated against
// contracts/openapi/apiaries.openapi.yaml (the "contract tests at
// boundaries" AC of #153). DELETE's 204 has no body to validate
// (contracttest.ValidateResponseBody no-ops when a status declares none).
func TestApiariesRest_ResponsesConformToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/apiaries.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}

	f := newApiariesFixture(t)
	id := uuid.NewString()

	recCreate := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Quinta do Vale", int32Ptr(3), geoPoint(-8.6, 41.1)))
	if recCreate.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", recCreate.Code, recCreate.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodPost, "/v1/apiaries", http.StatusCreated, recCreate.Body.Bytes())

	patchPath := "/v1/apiaries/" + id
	recPatch := f.do(t, http.MethodPatch, patchPath, map[string]any{"hive_count": 5})
	if recPatch.Code != http.StatusOK {
		t.Fatalf("update status = %d, want 200, body = %s", recPatch.Code, recPatch.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodPatch, patchPath, http.StatusOK, recPatch.Body.Bytes())

	// notes (FR-AP-8, #196) — new field, validated against the contract too.
	recNotes := f.do(t, http.MethodPatch, patchPath, map[string]any{"notes": "Cerca elétrica."})
	if recNotes.Code != http.StatusOK {
		t.Fatalf("notes update status = %d, want 200, body = %s", recNotes.Code, recNotes.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodPatch, patchPath, http.StatusOK, recNotes.Body.Bytes())

	recInvalid := f.do(t, http.MethodPatch, patchPath, map[string]any{"hive_count": -1})
	if recInvalid.Code != http.StatusUnprocessableEntity {
		t.Fatalf("invalid update status = %d, want 422, body = %s", recInvalid.Code, recInvalid.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodPatch, patchPath, http.StatusUnprocessableEntity, recInvalid.Body.Bytes())

	recDelete := f.do(t, http.MethodDelete, patchPath, nil)
	if recDelete.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204, body = %s", recDelete.Code, recDelete.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodDelete, patchPath, http.StatusNoContent, recDelete.Body.Bytes())
}

// --- REST write handlers (POST/PATCH/DELETE /v1/apiaries[/{id}], #31) ---

// createBody/updateBody build the REST write handlers' request bodies —
// small literal maps rather than typed structs, so a test can omit a field
// (nil) versus send its zero value, exercising the same
// present/absent distinction the handlers themselves make.
func createBody(id, name string, hiveCount *int32, loc *geoPointView) map[string]any {
	body := map[string]any{"id": id, "name": name}
	if hiveCount != nil {
		body["hive_count"] = *hiveCount
	}
	if loc != nil {
		body["location"] = loc
	}
	return body
}

// createBodyWithNotes layers a `notes` key onto createBody's result — kept
// as a separate helper (rather than widening createBody's signature) so the
// many existing createBody(...) call sites stay untouched (FR-AP-8, #196).
func createBodyWithNotes(id, name string, hiveCount *int32, loc *geoPointView, notes string) map[string]any {
	body := createBody(id, name, hiveCount, loc)
	body["notes"] = notes
	return body
}

func geoPoint(lon, lat float64) *geoPointView {
	return &geoPointView{Type: "Point", Coordinates: [2]float64{lon, lat}}
}

// TestApiariesRest_CreateReadUpdateDelete walks the REST CRUD round-trip
// this issue (#31) adds: POST creates (with Location/ETag headers and a
// GeoJSON location), GET reads it back, PATCH partially updates it
// (including clearing/changing location), and DELETE tombstones it so a
// subsequent GET 404s — matching FR-AP-1's create/read/update/delete ACs.
func TestApiariesRest_CreateReadUpdateDelete(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()

	// Create with a location.
	body := createBody(id, "Quinta do Vale", int32Ptr(3), geoPoint(-8.611, 41.148))
	recCreate := f.do(t, http.MethodPost, "/v1/apiaries", body)
	if recCreate.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", recCreate.Code, recCreate.Body.String())
	}
	if loc := recCreate.Header().Get("Location"); loc != "/v1/apiaries/"+id {
		t.Fatalf("create Location header = %q, want /v1/apiaries/%s", loc, id)
	}
	etag := recCreate.Header().Get("ETag")
	if etag == "" {
		t.Fatalf("create ETag header is empty, want a version tag")
	}
	var created apiaryView
	if err := json.Unmarshal(recCreate.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if created.Name != "Quinta do Vale" || created.HiveCount != 3 {
		t.Fatalf("created apiary = %+v, want name=Quinta do Vale hive_count=3", created)
	}
	if created.Location == nil || created.Location.Coordinates != [2]float64{-8.611, 41.148} {
		t.Fatalf("created apiary location = %+v, want [-8.611, 41.148]", created.Location)
	}

	// Read it back — same content, ETag on the response too.
	recGet := f.do(t, http.MethodGet, "/v1/apiaries/"+id, nil)
	if recGet.Code != http.StatusOK {
		t.Fatalf("get status = %d, want 200, body = %s", recGet.Code, recGet.Body.String())
	}
	if got := recGet.Header().Get("ETag"); got != etag {
		t.Fatalf("get ETag = %q, want %q (unchanged since create)", got, etag)
	}

	// Partial update: only hive_count changes; name/location must survive
	// untouched (PATCH is a partial update, not a replace).
	recUpdate := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"hive_count": 9})
	if recUpdate.Code != http.StatusOK {
		t.Fatalf("update status = %d, want 200, body = %s", recUpdate.Code, recUpdate.Body.String())
	}
	var updated apiaryView
	if err := json.Unmarshal(recUpdate.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode update response: %v", err)
	}
	if updated.HiveCount != 9 || updated.Name != "Quinta do Vale" {
		t.Fatalf("updated apiary = %+v, want hive_count=9 name unchanged", updated)
	}
	if updated.Location == nil || updated.Location.Coordinates != [2]float64{-8.611, 41.148} {
		t.Fatalf("updated apiary location = %+v, want unchanged [-8.611, 41.148]", updated.Location)
	}
	newETag := recUpdate.Header().Get("ETag")
	if newETag == "" || newETag == etag {
		t.Fatalf("update ETag = %q, want a new value distinct from create's %q", newETag, etag)
	}

	// Update the location itself.
	recMove := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"location": geoPoint(-9.0, 41.5)})
	if recMove.Code != http.StatusOK {
		t.Fatalf("move status = %d, want 200, body = %s", recMove.Code, recMove.Body.String())
	}
	var moved apiaryView
	if err := json.Unmarshal(recMove.Body.Bytes(), &moved); err != nil {
		t.Fatalf("decode move response: %v", err)
	}
	if moved.Location == nil || moved.Location.Coordinates != [2]float64{-9.0, 41.5} {
		t.Fatalf("moved apiary location = %+v, want [-9.0, 41.5]", moved.Location)
	}

	// Delete (tombstone) — 204, then a subsequent GET/PATCH/DELETE all 404.
	recDelete := f.do(t, http.MethodDelete, "/v1/apiaries/"+id, nil)
	if recDelete.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204, body = %s", recDelete.Code, recDelete.Body.String())
	}
	if recGone := f.do(t, http.MethodGet, "/v1/apiaries/"+id, nil); recGone.Code != http.StatusNotFound {
		t.Fatalf("get-after-delete status = %d, want 404", recGone.Code)
	}
	if recPatchGone := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"hive_count": 1}); recPatchGone.Code != http.StatusNotFound {
		t.Fatalf("patch-after-delete status = %d, want 404", recPatchGone.Code)
	}
	if recDeleteAgain := f.do(t, http.MethodDelete, "/v1/apiaries/"+id, nil); recDeleteAgain.Code != http.StatusNotFound {
		t.Fatalf("delete-after-delete status = %d, want 404", recDeleteAgain.Code)
	}
}

// TestApiariesRest_CreateWithoutLocation confirms the OpenAPI contract's
// ApiaryCreate.required (only [id, name], NOT location) is honored: a
// caller that omits location entirely gets a 201 with no `location` key in
// the response (omitempty — the GeoPoint schema has no null variant).
func TestApiariesRest_CreateWithoutLocation(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()

	rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Encosta Sem Local", nil, nil))
	if rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if strings.Contains(rec.Body.String(), `"location"`) {
		t.Fatalf("create response unexpectedly contains a location key: %s", rec.Body.String())
	}
	var created apiaryView
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode create response: %v", err)
	}
	if created.HiveCount != 0 {
		t.Fatalf("created apiary hive_count = %d, want 0 (schema default)", created.HiveCount)
	}
}

// TestApiariesRest_UpdateLocation_ExplicitNullClearsIt confirms sending
// `"location": null` on PATCH (a defensive case beyond what the GeoPoint
// schema itself specifies — it has no null variant, so this is undefined by
// the contract, not a documented clear-location signal) does not panic and
// results in an apiary with no location, matching how create-without-location
// behaves.
func TestApiariesRest_UpdateLocation_ExplicitNullClearsIt(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Foo", nil, geoPoint(-8.6, 41.1))); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	rec := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"location": nil})
	if rec.Code != http.StatusOK {
		t.Fatalf("update status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var updated apiaryView
	if err := json.Unmarshal(rec.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode update response: %v", err)
	}
	if updated.Location != nil {
		t.Fatalf("updated apiary location = %+v, want nil (cleared)", updated.Location)
	}
}

// TestApiariesRest_CreateValidation_RejectsBadInput matches the sync path's
// validation rules (sync.go's validateOp: name required/non-empty/≤200,
// hive_count >= 0) plus location bounds validation, with field-level 422s.
func TestApiariesRest_CreateValidation_RejectsBadInput(t *testing.T) {
	f := newApiariesFixture(t)

	cases := []struct {
		name string
		body map[string]any
	}{
		{"missing id", map[string]any{"name": "Foo"}},
		{"empty name", createBody(uuid.NewString(), "", nil, nil)},
		{"name too long", createBody(uuid.NewString(), strings.Repeat("x", 201), nil, nil)},
		{"negative hive_count", createBody(uuid.NewString(), "Foo", int32Ptr(-1), nil)},
		{"location wrong type", map[string]any{"id": uuid.NewString(), "name": "Foo", "location": map[string]any{"type": "Polygon", "coordinates": []float64{0, 0}}}},
		{"location out of range", map[string]any{"id": uuid.NewString(), "name": "Foo", "location": map[string]any{"type": "Point", "coordinates": []float64{200, 100}}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := f.do(t, http.MethodPost, "/v1/apiaries", tc.body)
			if rec.Code != http.StatusUnprocessableEntity {
				t.Fatalf("create(%s) status = %d, want 422, body = %s", tc.name, rec.Code, rec.Body.String())
			}
		})
	}
}

// TestApiariesRest_UpdateValidation_RejectsBadInput mirrors the create
// validation matrix for PATCH, plus the "must change at least one field"
// rule (ApiaryUpdate's minProperties: 1).
func TestApiariesRest_UpdateValidation_RejectsBadInput(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Foo", nil, nil)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	cases := []struct {
		name string
		body map[string]any
	}{
		{"empty body", map[string]any{}},
		{"empty name", map[string]any{"name": ""}},
		{"name too long", map[string]any{"name": strings.Repeat("x", 201)}},
		{"negative hive_count", map[string]any{"hive_count": -1}},
		{"location out of range", map[string]any{"location": map[string]any{"type": "Point", "coordinates": []float64{0, -100}}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, tc.body)
			if rec.Code != http.StatusUnprocessableEntity {
				t.Fatalf("update(%s) status = %d, want 422, body = %s", tc.name, rec.Code, rec.Body.String())
			}
		})
	}
}

// TestApiariesRest_Create_IdempotentReplayDoesNotDuplicate is #31's
// idempotency AC: re-sending the exact same create (same client-generated
// id, same content, with an Idempotency-Key) returns the original resource
// (201, unchanged) rather than a duplicate or an error — the row's own id
// is the idempotency anchor (api-contracts.md §4). A conflicting re-create
// (same id, different content) is a genuine 409.
func TestApiariesRest_Create_IdempotentReplayDoesNotDuplicate(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	idempotencyKey := uuid.NewString()
	body := createBody(id, "Quinta do Vale", int32Ptr(3), geoPoint(-8.6, 41.1))

	headers := map[string]string{"Idempotency-Key": idempotencyKey}
	rec1 := f.doAsWithHeaders(t, "", http.MethodPost, "/v1/apiaries", body, headers)
	if rec1.Code != http.StatusCreated {
		t.Fatalf("first create status = %d, want 201, body = %s", rec1.Code, rec1.Body.String())
	}

	rec2 := f.doAsWithHeaders(t, "", http.MethodPost, "/v1/apiaries", body, headers)
	if rec2.Code != http.StatusCreated {
		t.Fatalf("replayed create status = %d, want 201 (idempotent replay), body = %s", rec2.Code, rec2.Body.String())
	}
	var first, second apiaryView
	if err := json.Unmarshal(rec1.Body.Bytes(), &first); err != nil {
		t.Fatalf("decode first create: %v", err)
	}
	if err := json.Unmarshal(rec2.Body.Bytes(), &second); err != nil {
		t.Fatalf("decode replayed create: %v", err)
	}
	if first.ID != second.ID || first.Name != second.Name || first.HiveCount != second.HiveCount {
		t.Fatalf("replayed create body = %+v, want identical to first %+v", second, first)
	}
	if (first.Location == nil) != (second.Location == nil) {
		t.Fatalf("replayed create location = %+v, want identical to first %+v", second.Location, first.Location)
	}
	if first.Location != nil && *first.Location != *second.Location {
		t.Fatalf("replayed create location = %+v, want identical to first %+v", *second.Location, *first.Location)
	}

	var n int
	if err := f.pool.QueryRow(context.Background(), "SELECT count(*) FROM apiaries.apiaries WHERE id = $1", id).Scan(&n); err != nil {
		t.Fatalf("count apiaries: %v", err)
	}
	if n != 1 {
		t.Fatalf("apiaries rows with id %s = %d, want 1 (no duplicate)", id, n)
	}

	// A different payload reusing the same id is a genuine conflict.
	conflicting := createBody(id, "Different Name", int32Ptr(3), geoPoint(-8.6, 41.1))
	recConflict := f.do(t, http.MethodPost, "/v1/apiaries", conflicting)
	if recConflict.Code != http.StatusConflict {
		t.Fatalf("conflicting create status = %d, want 409, body = %s", recConflict.Code, recConflict.Body.String())
	}
}

// TestApiariesRest_History_CreateUpdateDeleteEachProduceOneAuditRow is #31's
// history AC (FR-HIS-1): every REST create/update/delete writes exactly one
// apiaries.audit_log row, in the same shape sync.go's writeAuditLog
// produces (mirrors TestApiariesSlice_History_CreateUpdateDeleteEachProduceOneAuditRow
// for the sync-apply path).
func TestApiariesRest_History_CreateUpdateDeleteEachProduceOneAuditRow(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()

	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Encosta Nova", int32Ptr(3), nil)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	rows := f.auditLogFor(t, id)
	if len(rows) != 1 || rows[0].ChangeType != "create" {
		t.Fatalf("audit rows after create = %+v, want exactly 1 create row", rows)
	}
	if rows[0].ActorUserID != devseed.UserID {
		t.Fatalf("create audit actor_user_id = %q, want %q", rows[0].ActorUserID, devseed.UserID)
	}

	if rec := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"hive_count": 12}); rec.Code != http.StatusOK {
		t.Fatalf("update status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	rows = f.auditLogFor(t, id)
	if len(rows) != 2 || rows[1].ChangeType != "update" {
		t.Fatalf("audit rows after update = %+v, want [create, update]", rows)
	}
	if len(rows[1].ChangedFields) != 1 || rows[1].ChangedFields[0] != "hive_count" {
		t.Fatalf("update audit changed_fields = %v, want [hive_count]", rows[1].ChangedFields)
	}

	if rec := f.do(t, http.MethodDelete, "/v1/apiaries/"+id, nil); rec.Code != http.StatusNoContent {
		t.Fatalf("delete status = %d, want 204, body = %s", rec.Code, rec.Body.String())
	}
	rows = f.auditLogFor(t, id)
	if len(rows) != 3 || rows[2].ChangeType != "delete" {
		t.Fatalf("audit rows after delete = %+v, want [create, update, delete]", rows)
	}
	var delChange map[string]any
	if err := json.Unmarshal(rows[2].Change, &delChange); err != nil {
		t.Fatalf("unmarshal delete change: %v", err)
	}
	if delChange["deleted"] != true {
		t.Fatalf("delete change = %+v, want a {deleted:true} tombstone", delChange)
	}
}

// TestApiariesRest_Notes_CreateAndUpdateRoundTrip is #196's core REST AC:
// notes is optional on create, present on read when set, and independently
// updatable via PATCH without disturbing other fields (mirrors how
// TestApiariesRest_CreateReadUpdateDelete exercises hive_count/location).
func TestApiariesRest_Notes_CreateAndUpdateRoundTrip(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()

	// Create without notes: omitted from the response (omitempty, like
	// location's own "unset" convention).
	recCreate := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Quinta das Flores", int32Ptr(2), nil))
	if recCreate.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", recCreate.Code, recCreate.Body.String())
	}
	if strings.Contains(recCreate.Body.String(), `"notes"`) {
		t.Fatalf("create response unexpectedly contains a notes key: %s", recCreate.Body.String())
	}

	// Create a second apiary with notes set up front.
	id2 := uuid.NewString()
	recCreate2 := f.do(t, http.MethodPost, "/v1/apiaries",
		createBodyWithNotes(id2, "Monte Alto", int32Ptr(4), nil, "Rosmaninho e eucalipto; acesso por caminho de terra."))
	if recCreate2.Code != http.StatusCreated {
		t.Fatalf("create-with-notes status = %d, want 201, body = %s", recCreate2.Code, recCreate2.Body.String())
	}
	var created2 apiaryView
	if err := json.Unmarshal(recCreate2.Body.Bytes(), &created2); err != nil {
		t.Fatalf("decode create-with-notes response: %v", err)
	}
	if created2.Notes == nil || *created2.Notes != "Rosmaninho e eucalipto; acesso por caminho de terra." {
		t.Fatalf("created apiary notes = %v, want the submitted text", created2.Notes)
	}

	// PATCH sets notes on the apiary created without them; other fields
	// (name, hive_count) must survive untouched (partial update).
	recUpdate := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"notes": "Cerca elétrica."})
	if recUpdate.Code != http.StatusOK {
		t.Fatalf("update status = %d, want 200, body = %s", recUpdate.Code, recUpdate.Body.String())
	}
	var updated apiaryView
	if err := json.Unmarshal(recUpdate.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode update response: %v", err)
	}
	if updated.Notes == nil || *updated.Notes != "Cerca elétrica." {
		t.Fatalf("updated apiary notes = %v, want \"Cerca elétrica.\"", updated.Notes)
	}
	if updated.Name != "Quinta das Flores" || updated.HiveCount != 2 {
		t.Fatalf("updated apiary = %+v, want name/hive_count unchanged", updated)
	}

	// A subsequent GET reflects the same notes (persisted, not just echoed).
	got := f.getApiary(t, id)
	if got.Notes == nil || *got.Notes != "Cerca elétrica." {
		t.Fatalf("get apiary notes = %v, want \"Cerca elétrica.\"", got.Notes)
	}

	// PATCH clearing notes back to empty string is a valid (if unusual)
	// content change, not treated as "field absent".
	recClear := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"notes": ""})
	if recClear.Code != http.StatusOK {
		t.Fatalf("clear-notes status = %d, want 200, body = %s", recClear.Code, recClear.Body.String())
	}
}

// TestApiariesRest_Notes_ValidationRejectsTooLong matches sync.go's
// validateOp notes-length rule (10000 chars) on the REST create/update path.
func TestApiariesRest_Notes_ValidationRejectsTooLong(t *testing.T) {
	f := newApiariesFixture(t)
	tooLong := strings.Repeat("x", 10001)

	recCreate := f.do(t, http.MethodPost, "/v1/apiaries", createBodyWithNotes(uuid.NewString(), "Foo", nil, nil, tooLong))
	if recCreate.Code != http.StatusUnprocessableEntity {
		t.Fatalf("create with too-long notes status = %d, want 422, body = %s", recCreate.Code, recCreate.Body.String())
	}

	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Foo", nil, nil)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	recUpdate := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"notes": tooLong})
	if recUpdate.Code != http.StatusUnprocessableEntity {
		t.Fatalf("update with too-long notes status = %d, want 422, body = %s", recUpdate.Code, recUpdate.Body.String())
	}
}

// TestApiariesRest_History_NotesChangeProducesAuditRowWithChangedField is
// #196's history AC (FR-HIS): a notes-only PATCH is recorded in change
// history like any other apiary edit, mirroring
// TestApiariesRest_History_CreateUpdateDeleteEachProduceOneAuditRow's
// hive_count assertion but for the new field.
func TestApiariesRest_History_NotesChangeProducesAuditRowWithChangedField(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()

	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Encosta Nova", int32Ptr(3), nil)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	if rec := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"notes": "Montado de sobro."}); rec.Code != http.StatusOK {
		t.Fatalf("update status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	rows := f.auditLogFor(t, id)
	if len(rows) != 2 || rows[1].ChangeType != "update" {
		t.Fatalf("audit rows after notes update = %+v, want [create, update]", rows)
	}
	if len(rows[1].ChangedFields) != 1 || rows[1].ChangedFields[0] != "notes" {
		t.Fatalf("notes-update audit changed_fields = %v, want [notes]", rows[1].ChangedFields)
	}
	var change map[string]any
	if err := json.Unmarshal(rows[1].Change, &change); err != nil {
		t.Fatalf("unmarshal update change: %v", err)
	}
	notesChange, ok := change["notes"].(map[string]any)
	if !ok {
		t.Fatalf("update change = %+v, want a notes {from,to} entry", change)
	}
	if notesChange["to"] != "Montado de sobro." {
		t.Fatalf("notes change.to = %v, want %q", notesChange["to"], "Montado de sobro.")
	}
	if rows[1].ActorUserID != devseed.UserID {
		t.Fatalf("notes-update audit actor_user_id = %q, want %q", rows[1].ActorUserID, devseed.UserID)
	}
}

// TestApiariesSlice_Notes_SyncApplyRoundTrip is #196's offline-sync AC
// ("notes sync offline"): notes flows through the sync-apply put/patch path
// exactly like name/hive_count, mirroring
// TestApiariesSlice_CreateReadLWWConflictIdempotencyTombstone's shape.
func TestApiariesSlice_Notes_SyncApplyRoundTrip(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	if got := f.apply(t, putOp(id, "Encosta Nova", 0, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %+v, want applied", got.Results[0])
	}
	created := f.getApiary(t, id)
	if created.Notes != nil {
		t.Fatalf("created apiary notes = %v, want nil (not set)", created.Notes)
	}

	t1 := t0.Add(time.Minute)
	if got := f.apply(t, patchNotes(id, "Junto à albufeira.", t1)); got.Results[0].Result != "applied" {
		t.Fatalf("notes patch result = %+v, want applied", got.Results[0])
	}
	updated := f.getApiary(t, id)
	if updated.Notes == nil || *updated.Notes != "Junto à albufeira." {
		t.Fatalf("updated apiary notes = %v, want \"Junto à albufeira.\"", updated.Notes)
	}

	rows := f.auditLogFor(t, id)
	if len(rows) != 2 || rows[1].ChangeType != "update" {
		t.Fatalf("audit rows after notes sync-apply = %+v, want [create, update]", rows)
	}
	if len(rows[1].ChangedFields) != 1 || rows[1].ChangedFields[0] != "notes" {
		t.Fatalf("notes sync-apply changed_fields = %v, want [notes]", rows[1].ChangedFields)
	}
}

// TestApiariesRest_IfMatch_StaleETagIsConflict is the optimistic-concurrency
// half of PATCH/DELETE's If-Match handling (IfMatchHeader,
// contracts/openapi/_shared/components.openapi.yaml): a stale If-Match is
// 409, a current one succeeds, and an absent one (If-Match is optional) also
// succeeds.
func TestApiariesRest_IfMatch_StaleETagIsConflict(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	recCreate := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Foo", nil, nil))
	if recCreate.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", recCreate.Code, recCreate.Body.String())
	}
	staleETag := recCreate.Header().Get("ETag")

	// A stale If-Match (from before an intervening update) is rejected.
	if rec := f.do(t, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"hive_count": 1}); rec.Code != http.StatusOK {
		t.Fatalf("first update status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	recStale := f.doAsWithHeaders(t, "", http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"hive_count": 2}, map[string]string{"If-Match": staleETag})
	if recStale.Code != http.StatusConflict {
		t.Fatalf("update with stale If-Match status = %d, want 409, body = %s", recStale.Code, recStale.Body.String())
	}

	// The current ETag succeeds.
	currentETag := f.getETag(t, id)
	recOK := f.doAsWithHeaders(t, "", http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"hive_count": 3}, map[string]string{"If-Match": currentETag})
	if recOK.Code != http.StatusOK {
		t.Fatalf("update with current If-Match status = %d, want 200, body = %s", recOK.Code, recOK.Body.String())
	}

	// A stale If-Match on DELETE is likewise rejected.
	recDeleteStale := f.doAsWithHeaders(t, "", http.MethodDelete, "/v1/apiaries/"+id, nil, map[string]string{"If-Match": staleETag})
	if recDeleteStale.Code != http.StatusConflict {
		t.Fatalf("delete with stale If-Match status = %d, want 409, body = %s", recDeleteStale.Code, recDeleteStale.Body.String())
	}
}

// TestApiariesRest_CrossOrg_WritesCannotTouchOtherOrgsRow is FR-TEN-2's
// write-side guarantee for the REST handlers (mirrors
// TestApiariesSlice_CrossOrg_SyncApplyCannotMutateOtherOrgsRow for the
// sync-apply path, #57's cross-org idiom): org B cannot update or delete
// org A's apiary by id — both come back 404, and org A's row is untouched.
func TestApiariesRest_CrossOrg_WritesCannotTouchOtherOrgsRow(t *testing.T) {
	f := newApiariesFixture(t)
	other := otherOrgCaller()

	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Org A Apiary", int32Ptr(5), nil)); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	recUpdate := f.doAs(t, other, http.MethodPatch, "/v1/apiaries/"+id, map[string]any{"hive_count": 99})
	if recUpdate.Code != http.StatusNotFound {
		t.Fatalf("org B update status = %d, want 404, body = %s", recUpdate.Code, recUpdate.Body.String())
	}
	recDelete := f.doAs(t, other, http.MethodDelete, "/v1/apiaries/"+id, nil)
	if recDelete.Code != http.StatusNotFound {
		t.Fatalf("org B delete status = %d, want 404, body = %s", recDelete.Code, recDelete.Body.String())
	}

	// Org A's apiary is untouched and still live.
	if a := f.getApiary(t, id); a.HiveCount != 5 {
		t.Fatalf("org A apiary hive_count = %d, want 5 (untouched by org B's attempts)", a.HiveCount)
	}
}

// TestApiariesRest_Create_CrossOrgIdCollisionIsConflict guards against the
// REST create idempotency-replay path (respondIdempotentCreateOrConflict)
// accidentally treating a same-id create from a DIFFERENT org as a safe
// replay: org A creates id X, then org B creates the same id X — since
// org B's org-scoped lookup of id X finds nothing (it's org A's row), this
// must be a 409, never a 200/201 that would leak org A's data into the
// response.
func TestApiariesRest_Create_CrossOrgIdCollisionIsConflict(t *testing.T) {
	f := newApiariesFixture(t)
	other := otherOrgCaller()
	id := uuid.NewString()

	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Org A Apiary", nil, nil)); rec.Code != http.StatusCreated {
		t.Fatalf("org A create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	recOtherOrg := f.doAs(t, other, http.MethodPost, "/v1/apiaries", createBody(id, "Org B Apiary", nil, nil))
	if recOtherOrg.Code != http.StatusConflict {
		t.Fatalf("org B create with colliding id status = %d, want 409, body = %s", recOtherOrg.Code, recOtherOrg.Body.String())
	}
}

// --- Proximity ordering (`near`, FR-AP-2, #33) ---

// TestApiariesRest_ListNear_OrdersByDistanceAscending is #33's core AC
// ("proximity ordering produces correct results... verified against known
// coordinates"): three apiaries at known offsets from a reference point in
// Porto, Portugal (roughly 1km/5km/20km east along the same latitude, where
// 1 degree of longitude ≈ 111km * cos(latitude) — small enough offsets that
// the flat-earth approximation used to derive the fixture coordinates is
// accurate to well within the assertion's tolerance) come back nearest
// first, each carrying a distance_m consistent with that known separation.
func TestApiariesRest_ListNear_OrdersByDistanceAscending(t *testing.T) {
	f := newApiariesFixture(t)
	const refLon, refLat = -8.6291, 41.1579 // Porto city centre

	// Longitude-degrees-per-km at this latitude (~41.16°N): 1 / (111.32 * cos(lat)).
	// near (~1km), mid (~5km), far (~20km) east of the reference point.
	near := uuid.NewString()
	mid := uuid.NewString()
	far := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(far, "Far", nil, geoPoint(refLon+0.2394, refLat))); rec.Code != http.StatusCreated {
		t.Fatalf("create far status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(near, "Near", nil, geoPoint(refLon+0.01197, refLat))); rec.Code != http.StatusCreated {
		t.Fatalf("create near status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(mid, "Mid", nil, geoPoint(refLon+0.05985, refLat))); rec.Code != http.StatusCreated {
		t.Fatalf("create mid status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	list := f.listApiariesNear(t, refLon, refLat)
	if len(list.Data) != 3 {
		t.Fatalf("near list = %+v, want 3 rows", list.Data)
	}
	gotOrder := []string{list.Data[0].ID, list.Data[1].ID, list.Data[2].ID}
	wantOrder := []string{near, mid, far}
	if gotOrder[0] != wantOrder[0] || gotOrder[1] != wantOrder[1] || gotOrder[2] != wantOrder[2] {
		t.Fatalf("near list order = %v, want %v (near, mid, far)", gotOrder, wantOrder)
	}

	// Each row carries distance_m consistent with its known offset (±10%
	// tolerance for the flat-earth approximation used to derive the fixture
	// coordinates vs. PostGIS's geodesic ST_Distance).
	wantDistances := map[string]float64{near: 1000, mid: 5000, far: 20000}
	for _, a := range list.Data {
		if a.DistanceM == nil {
			t.Fatalf("apiary %s has no distance_m, want ~%.0fm", a.ID, wantDistances[a.ID])
		}
		want := wantDistances[a.ID]
		tolerance := want * 0.1
		if *a.DistanceM < want-tolerance || *a.DistanceM > want+tolerance {
			t.Fatalf("apiary %s distance_m = %.1f, want ~%.1f (±10%%)", a.ID, *a.DistanceM, want)
		}
	}
}

// TestApiariesRest_ListNear_ApiaryWithoutLocationSortsLastWithNullDistance
// confirms an apiary missing a location still appears in a `near` list
// (rather than being silently dropped) with a null distance_m, sorted after
// every apiary that does have a distance.
func TestApiariesRest_ListNear_ApiaryWithoutLocationSortsLastWithNullDistance(t *testing.T) {
	f := newApiariesFixture(t)
	const refLon, refLat = -8.6291, 41.1579

	withLoc := uuid.NewString()
	withoutLoc := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(withLoc, "Has location", nil, geoPoint(refLon, refLat))); rec.Code != http.StatusCreated {
		t.Fatalf("create withLoc status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(withoutLoc, "No location", nil, nil)); rec.Code != http.StatusCreated {
		t.Fatalf("create withoutLoc status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}

	list := f.listApiariesNear(t, refLon, refLat)
	if len(list.Data) != 2 {
		t.Fatalf("near list = %+v, want 2 rows", list.Data)
	}
	if list.Data[0].ID != withLoc || list.Data[1].ID != withoutLoc {
		t.Fatalf("near list order = [%s, %s], want [withLoc, withoutLoc] (no-location sorts last)", list.Data[0].ID, list.Data[1].ID)
	}
	if list.Data[0].DistanceM == nil {
		t.Fatalf("apiary with location has nil distance_m, want a value")
	}
	if list.Data[1].DistanceM != nil {
		t.Fatalf("apiary without location distance_m = %v, want nil", *list.Data[1].DistanceM)
	}
}

// TestApiariesRest_List_WithoutNear_OmitsDistance confirms distance_m is
// only populated on a `near`-ordered list (contract: "only on proximity
// lists") — the default keyset-paginated list never carries it.
func TestApiariesRest_List_WithoutNear_OmitsDistance(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Foo", nil, geoPoint(-8.6, 41.1))); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	list := f.listApiaries(t)
	if len(list.Data) != 1 {
		t.Fatalf("list = %+v, want 1 row", list.Data)
	}
	if list.Data[0].DistanceM != nil {
		t.Fatalf("list without near distance_m = %v, want nil (omitted)", *list.Data[0].DistanceM)
	}
}

// TestApiariesRest_ListNear_RejectsMalformedInput is #33's `near` validation
// AC: a malformed or out-of-range `near` value is a 422, matching the
// contract's field-level validation-error shape used elsewhere (e.g.
// TestApiariesRest_CreateValidation_RejectsBadInput).
func TestApiariesRest_ListNear_RejectsMalformedInput(t *testing.T) {
	f := newApiariesFixture(t)
	cases := []struct {
		name string
		near string
	}{
		{"not a coordinate pair", "not-a-number"},
		{"missing latitude", "-8.6"},
		{"three components", "-8.6,41.1,10"},
		{"longitude out of range", "200,41.1"},
		{"latitude out of range", "-8.6,100"},
		{"empty", ""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			rec := f.do(t, http.MethodGet, "/v1/apiaries?near="+url.QueryEscape(tc.near), nil)
			// An empty `near` is indistinguishable from "not supplied" per
			// url.Values semantics (the handler only branches on a non-empty
			// value) — that's the default-list path, not a validation error.
			if tc.near == "" {
				if rec.Code != http.StatusOK {
					t.Fatalf("list with empty near status = %d, want 200 (treated as absent)", rec.Code)
				}
				return
			}
			if rec.Code != http.StatusUnprocessableEntity {
				t.Fatalf("list with near=%q status = %d, want 422, body = %s", tc.near, rec.Code, rec.Body.String())
			}
		})
	}
}

// TestApiariesRest_ListNear_ResponsesConformToOpenAPIContract validates a
// `near`-ordered list response (with distance_m present) against the
// contract, the near-specific counterpart of
// TestApiariesSlice_ResponsesConformToOpenAPIContract.
func TestApiariesRest_ListNear_ResponsesConformToOpenAPIContract(t *testing.T) {
	doc, err := contracttest.Load("../../contracts/openapi/apiaries.openapi.yaml")
	if err != nil {
		t.Fatalf("load contract: %v", err)
	}
	f := newApiariesFixture(t)
	id := uuid.NewString()
	if rec := f.do(t, http.MethodPost, "/v1/apiaries", createBody(id, "Quinta do Vale", nil, geoPoint(-8.6, 41.1))); rec.Code != http.StatusCreated {
		t.Fatalf("create status = %d, want 201, body = %s", rec.Code, rec.Body.String())
	}
	recList := f.do(t, http.MethodGet, "/v1/apiaries?near=-8.6,41.1", nil)
	if recList.Code != http.StatusOK {
		t.Fatalf("near list status = %d, want 200, body = %s", recList.Code, recList.Body.String())
	}
	doc.ValidateResponseBody(t, http.MethodGet, "/v1/apiaries", http.StatusOK, recList.Body.Bytes())
}

// listApiariesNear issues GET /v1/apiaries?near=lon,lat and decodes the list.
func (f *apiariesFixture) listApiariesNear(t *testing.T, lon, lat float64) listView {
	t.Helper()
	near := strconv.FormatFloat(lon, 'f', -1, 64) + "," + strconv.FormatFloat(lat, 'f', -1, 64)
	rec := f.do(t, http.MethodGet, "/v1/apiaries?near="+url.QueryEscape(near), nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("near list status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var l listView
	if err := json.Unmarshal(rec.Body.Bytes(), &l); err != nil {
		t.Fatalf("decode near list: %v", err)
	}
	return l
}

func int32Ptr(n int32) *int32 { return &n }

// getETag issues a GET and returns just the ETag header — a shorthand for
// tests that need the current version stamp without the full body.
func (f *apiariesFixture) getETag(t *testing.T, id string) string {
	t.Helper()
	rec := f.do(t, http.MethodGet, "/v1/apiaries/"+id, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("get status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	return rec.Header().Get("ETag")
}

// --- small read helpers ---

// geoPointView mirrors api.geoPointDTO's wire shape for test assertions.
type geoPointView struct {
	Type        string     `json:"type"`
	Coordinates [2]float64 `json:"coordinates"`
}

type apiaryView struct {
	ID        string        `json:"id"`
	Name      string        `json:"name"`
	HiveCount int32         `json:"hive_count"`
	Location  *geoPointView `json:"location,omitempty"`
	Notes     *string       `json:"notes,omitempty"`
	DistanceM *float64      `json:"distance_m,omitempty"`
}

func (f *apiariesFixture) getApiary(t *testing.T, id string) apiaryView {
	t.Helper()
	rec := f.do(t, http.MethodGet, "/v1/apiaries/"+id, nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("get status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var a apiaryView
	if err := json.Unmarshal(rec.Body.Bytes(), &a); err != nil {
		t.Fatalf("decode apiary: %v", err)
	}
	return a
}

type listView struct {
	Data []apiaryView `json:"data"`
	Page struct {
		NextCursor *string `json:"next_cursor"`
		Limit      int     `json:"limit"`
	} `json:"page"`
}

func (f *apiariesFixture) listApiaries(t *testing.T) listView {
	t.Helper()
	rec := f.do(t, http.MethodGet, "/v1/apiaries", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("list status = %d, want 200, body = %s", rec.Code, rec.Body.String())
	}
	var l listView
	if err := json.Unmarshal(rec.Body.Bytes(), &l); err != nil {
		t.Fatalf("decode list: %v", err)
	}
	return l
}

// createSchema provisions the service's schema before migrating, standing in
// for the postgres chart's bootstrap (migrations no longer create it).
func createSchema(ctx context.Context, t *testing.T, cfg dbaccess.Config, name string) {
	t.Helper()
	conn, err := pgx.Connect(ctx, cfg.DSN())
	if err != nil {
		t.Fatalf("connect to create schema: %v", err)
	}
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, "CREATE SCHEMA IF NOT EXISTS "+name); err != nil {
		t.Fatalf("create schema %s: %v", name, err)
	}
}

// createPostgisExtension enables postgis on the test database, standing in
// for the postgres chart's bootstrap (cluster.yaml's postInitApplicationSQL
// runs `CREATE EXTENSION IF NOT EXISTS postgis;` once, cluster-wide, before
// any service's migrations run) — 00003_add_apiary_location.sql's
// `geography(Point, 4326)` column needs the extension to already exist.
func createPostgisExtension(ctx context.Context, t *testing.T, cfg dbaccess.Config) {
	t.Helper()
	conn, err := pgx.Connect(ctx, cfg.DSN())
	if err != nil {
		t.Fatalf("connect to create postgis extension: %v", err)
	}
	defer conn.Close(ctx)
	if _, err := conn.Exec(ctx, "CREATE EXTENSION IF NOT EXISTS postgis"); err != nil {
		t.Fatalf("create postgis extension: %v", err)
	}
}
