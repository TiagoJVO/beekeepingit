package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/apiaries/api"
	"github.com/TiagoJVO/beekeepingit/services/apiaries/store"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/authn"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/config"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/contracttest"
	"github.com/TiagoJVO/beekeepingit/services/servicetemplate/health"
	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
	"github.com/TiagoJVO/beekeepingit/services/shared/devseed"
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
	pg, err := tcpostgres.Run(ctx, "postgres:16-alpine",
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
	// Migrations no longer create the schema (infra's job in-cluster).
	createSchema(ctx, t, dbCfg, "apiaries")
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
	srv.Mount("/v1/apiaries", injectClaims(api.ReadRouter(pool)))
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

func putOp(id, name string, hive int32, ts time.Time) api.Op {
	data, _ := json.Marshal(map[string]any{"name": name, "hive_count": hive})
	return api.Op{Op: "put", EntityType: "apiary", ID: id, Data: data, UpdatedAt: ts}
}

func patchHive(id string, hive int32, ts time.Time) api.Op {
	data, _ := json.Marshal(map[string]any{"hive_count": hive})
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

// --- small read helpers ---

type apiaryView struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	HiveCount int32  `json:"hive_count"`
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
