package main

// apiary_counters (#256, FR-AP-7): typed 1-N counters decoupled from the
// apiaries table. This file covers what's NEW for #256 — the counter
// table's own constraint/upsert/LWW/history/validation behavior via the new
// entityTypeApiaryCounter sync-apply path (api/sync.go's applyCounterOp) —
// and the migration's data backfill + column retirement. The EXISTING
// hive_count-on-the-apiary-op behavior (putOp/patchHive in main_test.go,
// exercised by TestApiariesSlice_CreateReadLWWConflictIdempotencyTombstone
// and friends) is left untouched and still fully green: #256 is a pure
// decoupling underneath that wire shape, not a breaking change to it.

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/TiagoJVO/beekeepingit/services/apiaries/api"
)

const counterTypeHive = "hive"

// counterTypeSuper mirrors api.counterTypeSuper (#346, D-20) for these
// package-main tests, matching counterTypeHive's own local-const convention.
const counterTypeSuper = "super"

// counterOp builds an entityTypeApiaryCounter op (api/sync.go's counterData
// wire shape) for the tests below — the counter-table counterpart of
// main_test.go's putOp/patchHive, but keyed by apiary_id+counter_type rather
// than a client-generated row id doubling as server identity (applyCounterOp's
// doc comment explains why that split exists).
func counterOp(apiaryID, counterType string, value int32, ts time.Time) api.Op {
	data, _ := json.Marshal(map[string]any{"apiary_id": apiaryID, "counter_type": counterType, "value": value})
	return api.Op{Op: "put", EntityType: "apiary_counter", ID: uuid.NewString(), Data: data, UpdatedAt: ts}
}

// counterRow is the subset of apiaries.apiary_counters columns these tests
// read directly from the DB (mirrors main_test.go's auditRow/timelineRow
// convention of small, test-local row structs for direct-SQL assertions).
type counterRow struct {
	ID          string
	ApiaryID    string
	CounterType string
	Value       int32
}

// countersFor returns every apiary_counters row for one apiary, ordered by
// counter_type — direct-SQL, mirroring main_test.go's auditLogFor.
func (f *apiariesFixture) countersFor(t *testing.T, apiaryID string) []counterRow {
	t.Helper()
	rows, err := f.pool.Query(context.Background(),
		`SELECT id, apiary_id, counter_type, value
		 FROM apiaries.apiary_counters
		 WHERE apiary_id = $1
		 ORDER BY counter_type`, apiaryID)
	if err != nil {
		t.Fatalf("query apiary_counters: %v", err)
	}
	defer rows.Close()

	var out []counterRow
	for rows.Next() {
		var (
			id, apiaryIDCol uuid.UUID
			counterType     string
			value           int32
		)
		if err := rows.Scan(&id, &apiaryIDCol, &counterType, &value); err != nil {
			t.Fatalf("scan apiary_counters row: %v", err)
		}
		out = append(out, counterRow{ID: id.String(), ApiaryID: apiaryIDCol.String(), CounterType: counterType, Value: value})
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate apiary_counters: %v", err)
	}
	return out
}

// TestApiaryCounters_UniqueConstraint_UpsertNeverDuplicatesARow is #256's
// core DB-shape AC: "UNIQUE (apiary_id, counter_type) — an apiary can never
// hold two counters of the same type." Exercised through the existing
// entityTypeApiary op's hive_count field (the legacy-compatible write path,
// api/sync.go's applyOp) across THREE separate applies — if upsertCounter's
// ON CONFLICT ever regressed to a plain INSERT, this would either error
// (unique_violation surfacing as 500) or produce 3 rows instead of 1.
func TestApiaryCounters_UniqueConstraint_UpsertNeverDuplicatesARow(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	if got := f.apply(t, putOp(id, "Encosta Nova", 3, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}
	if got := f.apply(t, patchHive(id, 7, t0.Add(time.Minute))); got.Results[0].Result != "applied" {
		t.Fatalf("first hive update result = %q, want applied", got.Results[0].Result)
	}
	if got := f.apply(t, patchHive(id, 12, t0.Add(2*time.Minute))); got.Results[0].Result != "applied" {
		t.Fatalf("second hive update result = %q, want applied", got.Results[0].Result)
	}

	rows := f.countersFor(t, id)
	if len(rows) != 1 {
		t.Fatalf("apiary_counters rows for apiary %s = %d, want exactly 1 (UNIQUE(apiary_id, counter_type)): %+v", id, len(rows), rows)
	}
	if rows[0].CounterType != counterTypeHive || rows[0].Value != 12 {
		t.Fatalf("counter row = %+v, want counter_type=hive value=12 (the last write wins via upsert)", rows[0])
	}
}

// TestApiaryCounters_DeleteDoesNotChurnTheCounterRow guards a subtlety of
// applyOp's delete branch (api/sync.go): mergeOp never changes .hive on
// delete, so applyOp intentionally skips re-upserting the counter for a
// delete op (a delete isn't "about" the hive count). This confirms that skip
// doesn't silently corrupt the counter (still there, still correct) and
// doesn't touch its updated_at for an unrelated op.
func TestApiaryCounters_DeleteDoesNotChurnTheCounterRow(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	if got := f.apply(t, putOp(id, "Encosta Nova", 5, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %q, want applied", got.Results[0].Result)
	}
	before := f.countersFor(t, id)
	if len(before) != 1 || before[0].Value != 5 {
		t.Fatalf("counters before delete = %+v, want [{hive 5}]", before)
	}

	delOp := api.Op{Op: "delete", EntityType: "apiary", ID: id, UpdatedAt: t0.Add(time.Minute)}
	if got := f.apply(t, delOp); got.Results[0].Result != "applied" {
		t.Fatalf("delete result = %q, want applied", got.Results[0].Result)
	}

	after := f.countersFor(t, id)
	if len(after) != 1 || after[0].Value != 5 || after[0].ID != before[0].ID {
		t.Fatalf("counters after delete = %+v, want unchanged %+v (same row id, same value)", after, before)
	}
}

// --- The new entityTypeApiaryCounter sync-apply path (applyCounterOp) ---

// TestApiariesSlice_CounterOp_CreateLWWConflictIdempotency is the counter-op
// counterpart of TestApiariesSlice_CreateReadLWWConflictIdempotencyTombstone:
// the same apply/LWW/conflict/idempotency matrix, but through the NEW,
// genuinely-1-N entityTypeApiaryCounter op (the client's actual write path
// going forward), keyed by (apiary_id, counter_type) rather than a
// client-generated row id.
func TestApiariesSlice_CounterOp_CreateLWWConflictIdempotency(t *testing.T) {
	f := newApiariesFixture(t)
	apiaryID := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	// The apiary itself must exist first (a counter is meaningless without
	// its parent row) — created via the ordinary apiary op, whose EXPLICIT
	// hive_count of 0 (putOp always sends the key) makes applyOp upsert a
	// 0-value hive counter row of its own — so the very first row this test
	// observes below already exists before its first counterOp call; what ①
	// actually exercises is applyCounterOp's UPDATE branch (still exactly
	// the LWW/idempotency/conflict behavior being tested; the CREATE branch
	// has its own dedicated test,
	// TestApiariesSlice_CounterOp_History_FirstWriteIsACreateBaseline).
	if got := f.apply(t, putOp(apiaryID, "Encosta Nova", 0, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create apiary result = %q, want applied", got.Results[0].Result)
	}

	// ① First edit via the NEW op (an update over the apiary-create's own
	// 0-value counter row, per the comment above) — applied.
	if got := f.apply(t, counterOp(apiaryID, counterTypeHive, 3, t0.Add(time.Second))); got.Results[0].Result != "applied" {
		t.Fatalf("first counter-op edit result = %q, want applied", got.Results[0].Result)
	}
	rows := f.countersFor(t, apiaryID)
	if len(rows) != 1 || rows[0].Value != 3 {
		t.Fatalf("counters after first edit = %+v, want [{hive 3}]", rows)
	}
	firstRowID := rows[0].ID

	// ② Newer edit wins — same underlying row (same id), new value.
	winningTS := t0.Add(time.Minute)
	if got := f.apply(t, counterOp(apiaryID, counterTypeHive, 12, winningTS)); got.Results[0].Result != "applied" {
		t.Fatalf("newer counter edit result = %q, want applied", got.Results[0].Result)
	}
	rows = f.countersFor(t, apiaryID)
	if len(rows) != 1 || rows[0].Value != 12 || rows[0].ID != firstRowID {
		t.Fatalf("counters after newer edit = %+v, want [{id=%s hive 12}] (same row, upserted)", rows, firstRowID)
	}

	// ③ Older edit loses → superseded, server value kept, conflict logged.
	if got := f.apply(t, counterOp(apiaryID, counterTypeHive, 99, t0.Add(-time.Minute))); got.Results[0].Result != "superseded" {
		t.Fatalf("older counter edit result = %q, want superseded", got.Results[0].Result)
	}
	rows = f.countersFor(t, apiaryID)
	if len(rows) != 1 || rows[0].Value != 12 {
		t.Fatalf("counters after superseded edit = %+v, want value still 12 (server kept)", rows)
	}
	if n := f.conflictCount(t); n != 1 {
		t.Fatalf("conflict rows = %d, want 1", n)
	}

	// ④ Idempotent re-send of the winning edit → applied, no new conflict.
	if got := f.apply(t, counterOp(apiaryID, counterTypeHive, 12, winningTS)); got.Results[0].Result != "applied" {
		t.Fatalf("idempotent re-send result = %q, want applied", got.Results[0].Result)
	}
	if n := f.conflictCount(t); n != 1 {
		t.Fatalf("conflict rows after idempotent re-send = %d, want unchanged 1", n)
	}
}

// TestApiariesSlice_CounterOp_TwoOfflineDevicesCollapseToOneRow is the #256
// AC made concrete: two different (client-generated) op ids targeting the
// SAME (apiary_id, counter_type) — simulating two different offline devices
// both editing "the hive counter" for the same apiary without ever having
// seen each other's local row id — must collapse into exactly one server
// row, not two. This is exactly why applyCounterOp keys off
// (apiary_id, counter_type), never off Op.ID. (A third writer is already in
// play too: putOp's explicit hive_count 0 makes the apiary create upsert an
// initial 0-value hive row — so this test actually proves THREE independent
// writers collapse to one row, an even stronger guarantee than the
// two-device framing in its name.)
func TestApiariesSlice_CounterOp_TwoOfflineDevicesCollapseToOneRow(t *testing.T) {
	f := newApiariesFixture(t)
	apiaryID := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if got := f.apply(t, putOp(apiaryID, "Encosta Nova", 0, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create apiary result = %q, want applied", got.Results[0].Result)
	}

	// Device A's op (its own client-generated id, opaque to the server).
	deviceA := counterOp(apiaryID, counterTypeHive, 4, t0.Add(time.Second))
	if got := f.apply(t, deviceA); got.Results[0].Result != "applied" {
		t.Fatalf("device A create result = %q, want applied", got.Results[0].Result)
	}

	// Device B's op — a DIFFERENT client-generated id (counterOp always
	// mints a fresh uuid.NewString() for Op.ID), same apiary+type, a later
	// timestamp (device B synced after A).
	deviceB := counterOp(apiaryID, counterTypeHive, 9, t0.Add(2*time.Second))
	if deviceA.ID == deviceB.ID {
		t.Fatalf("test setup bug: deviceA/deviceB must have distinct client-generated ids")
	}
	if got := f.apply(t, deviceB); got.Results[0].Result != "applied" {
		t.Fatalf("device B create result = %q, want applied", got.Results[0].Result)
	}

	rows := f.countersFor(t, apiaryID)
	if len(rows) != 1 {
		t.Fatalf("apiary_counters rows = %d, want exactly 1 (two devices' creates collapsed via (apiary_id, counter_type)): %+v", len(rows), rows)
	}
	if rows[0].Value != 9 {
		t.Fatalf("counter value = %d, want 9 (device B's later write)", rows[0].Value)
	}
}

// --- Known-type validation (#256 AC 2: "reject unknown types with the
// standard RFC 9457 error format") ---

// TestApiariesSlice_CounterOp_ValidateRejectsUnknownCounterType is the
// concrete proof of #256's extensibility guarantee's OTHER half: not just
// "adding a type is code-only" but "an unrecognized type is actually
// rejected", with field-level RFC 9457 detail — not silently accepted or a
// generic 500.
func TestApiariesSlice_CounterOp_ValidateRejectsUnknownCounterType(t *testing.T) {
	f := newApiariesFixture(t)
	bad := api.Op{
		Op: "put", EntityType: "apiary_counter", ID: uuid.NewString(),
		Data:      json.RawMessage(`{"apiary_id":"` + uuid.NewString() + `","counter_type":"nucs","value":2}`),
		UpdatedAt: time.Now(),
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/validate", api.Batch{Ops: []api.Op{bad}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("validate status = %d, want 422 (unknown counter_type), body = %s", rec.Code, rec.Body.String())
	}
	var problem struct {
		Errors []struct {
			Field string `json:"field"`
			Code  string `json:"code"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &problem); err != nil {
		t.Fatalf("decode problem response: %v", err)
	}
	found := false
	for _, e := range problem.Errors {
		if e.Field == "ops[0].data.counter_type" && e.Code == "invalid" {
			found = true
		}
	}
	if !found {
		t.Fatalf("problem errors = %+v, want a field-level error on ops[0].data.counter_type", problem.Errors)
	}
}

// TestApiariesSlice_CounterOp_ValidateRejectsNegativeValue mirrors the
// apiary op's own hive_count >= 0 rule (main_test.go's
// TestApiariesSlice_ValidateRejectsBadOps), now for the counter op's own
// `value` field.
func TestApiariesSlice_CounterOp_ValidateRejectsNegativeValue(t *testing.T) {
	f := newApiariesFixture(t)
	bad := api.Op{
		Op: "put", EntityType: "apiary_counter", ID: uuid.NewString(),
		Data:      json.RawMessage(`{"apiary_id":"` + uuid.NewString() + `","counter_type":"hive","value":-1}`),
		UpdatedAt: time.Now(),
	}
	rec := f.do(t, http.MethodPost, "/internal/sync/validate", api.Batch{Ops: []api.Op{bad}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("validate status = %d, want 422 (negative value), body = %s", rec.Code, rec.Body.String())
	}
}

// TestApiariesSlice_CounterOp_ValidateRejectsDeleteOp confirms the "counters
// have no delete" rule (validateCounterOp) — a counter has no independent
// lifecycle, so `delete` is not a valid op for entityTypeApiaryCounter.
func TestApiariesSlice_CounterOp_ValidateRejectsDeleteOp(t *testing.T) {
	f := newApiariesFixture(t)
	bad := api.Op{Op: "delete", EntityType: "apiary_counter", ID: uuid.NewString(), UpdatedAt: time.Now()}
	rec := f.do(t, http.MethodPost, "/internal/sync/validate", api.Batch{Ops: []api.Op{bad}})
	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("validate status = %d, want 422 (delete not allowed for apiary_counter), body = %s", rec.Code, rec.Body.String())
	}
}

// --- History (FR-HIS-1) for the new entity type ---

// TestApiariesSlice_CounterOp_History_CreateAndUpdateProduceAuditRows is
// #256's history AC ("history capture follows the existing apiaries
// pattern"): a counter-op create/update writes an apiaries.audit_log row
// keyed by entity_type=apiary_counter, entity_id=the apiary_id (a counter
// has no client-stable id of its own — applyCounterOp's doc comment) — the
// same in-transaction, per-service capture mechanism history.md §4 already
// proves for entity_type=apiary.
//
// Two audit-attribution rules pinned here:
//   - the LEGACY path (an apiary op carrying hive_count, putOp) audits the
//     hive value inside the APIARY's own audit row (entity_type=apiary,
//     hive_count in its change payload — main_test.go's history tests) and
//     writes NO apiary_counter-typed row — one logical change, one audit
//     row, never double-counted across the two entity types;
//   - the NEW path (an entityTypeApiaryCounter op) audits under
//     entity_type=apiary_counter: `create` with a baseline when no counter
//     row existed yet, `update` with a {from,to} delta otherwise.
func TestApiariesSlice_CounterOp_History_CreateAndUpdateProduceAuditRows(t *testing.T) {
	f := newApiariesFixture(t)
	apiaryID := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if got := f.apply(t, putOp(apiaryID, "Encosta Nova", 0, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create apiary result = %q, want applied", got.Results[0].Result)
	}
	// putOp carries hive_count (0), so the counter ROW exists — but its
	// audit trail lives in the apiary's own create row (first rule above):
	// zero apiary_counter-typed rows yet.
	if rows := f.counterAuditLogFor(t, apiaryID); len(rows) != 0 {
		t.Fatalf("counter audit rows after apiary create = %+v, want none (legacy-path hive changes audit under entity_type=apiary)", rows)
	}

	// First counter-op edit: the row exists (0), so this is an update with a
	// 0→7 delta.
	if got := f.apply(t, counterOp(apiaryID, counterTypeHive, 7, t0.Add(time.Second))); got.Results[0].Result != "applied" {
		t.Fatalf("first counter-op update result = %q, want applied", got.Results[0].Result)
	}
	rows := f.counterAuditLogFor(t, apiaryID)
	if len(rows) != 1 || rows[0].ChangeType != "update" {
		t.Fatalf("counter audit rows after first counter-op update = %+v, want exactly [update]", rows)
	}
	if len(rows[0].ChangedFields) != 1 || rows[0].ChangedFields[0] != "hive" {
		t.Fatalf("first update audit changed_fields = %v, want [hive]", rows[0].ChangedFields)
	}
	firstUpdateChange := map[string]any{}
	if err := json.Unmarshal(rows[0].Change, &firstUpdateChange); err != nil {
		t.Fatalf("unmarshal first update change: %v", err)
	}
	firstDelta, ok := firstUpdateChange["hive"].(map[string]any)
	if !ok || firstDelta["from"] != float64(0) || firstDelta["to"] != float64(7) {
		t.Fatalf("first update change[hive] = %#v, want from=0 to=7", firstUpdateChange["hive"])
	}

	// Second counter-op edit: 7→12 delta.
	if got := f.apply(t, counterOp(apiaryID, counterTypeHive, 12, t0.Add(time.Minute))); got.Results[0].Result != "applied" {
		t.Fatalf("second counter-op update result = %q, want applied", got.Results[0].Result)
	}
	rows = f.counterAuditLogFor(t, apiaryID)
	if len(rows) != 2 || rows[1].ChangeType != "update" {
		t.Fatalf("counter audit rows after second counter-op update = %+v, want [update, update]", rows)
	}
	var secondUpdateChange map[string]any
	if err := json.Unmarshal(rows[1].Change, &secondUpdateChange); err != nil {
		t.Fatalf("unmarshal second update change: %v", err)
	}
	secondDelta, ok := secondUpdateChange["hive"].(map[string]any)
	if !ok {
		t.Fatalf("second update change[hive] = %#v, want a {from,to} object", secondUpdateChange["hive"])
	}
	if secondDelta["from"] != float64(7) || secondDelta["to"] != float64(12) {
		t.Fatalf("second update change[hive] = %+v, want from=7 to=12", secondDelta)
	}
}

// TestApiariesSlice_CounterOp_History_FirstWriteIsACreateBaseline exercises
// applyCounterOp's genuine CREATE branch: an apiary created WITHOUT any
// hive_count in its op data gets no counter row at all (applyOp's nil-guard
// — the new client's own create shape, whose hive count arrives as this
// separate counter op instead), so the first counter op for it finds no
// stored row and audits as a `create` with a baseline payload — exactly
// mirroring the apiary op's own create-baseline convention (history.md §3).
func TestApiariesSlice_CounterOp_History_FirstWriteIsACreateBaseline(t *testing.T) {
	f := newApiariesFixture(t)
	apiaryID := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	// An apiary op with NO hive_count key — the new client's create shape
	// (its local apiaries table no longer has the column).
	createData, _ := json.Marshal(map[string]any{"name": "Encosta Nova"})
	create := api.Op{Op: "put", EntityType: "apiary", ID: apiaryID, Data: createData, UpdatedAt: t0}
	if got := f.apply(t, create); got.Results[0].Result != "applied" {
		t.Fatalf("create apiary result = %q, want applied", got.Results[0].Result)
	}
	if rows := f.countersFor(t, apiaryID); len(rows) != 0 {
		t.Fatalf("counters after hive-less apiary create = %+v, want none (no hive_count in the op ⇒ no counter row; reads default to 0)", rows)
	}
	// The read path still reports hive_count 0 — the "0 when no row exists"
	// default (#256 AC) — via the LEFT JOIN + COALESCE.
	if a := f.getApiary(t, apiaryID); a.HiveCount != 0 {
		t.Fatalf("hive_count with no counter row = %d, want 0 (COALESCE default)", a.HiveCount)
	}

	// The first counter op finds no stored row → create + baseline audit.
	if got := f.apply(t, counterOp(apiaryID, counterTypeHive, 5, t0.Add(time.Second))); got.Results[0].Result != "applied" {
		t.Fatalf("first counter op result = %q, want applied", got.Results[0].Result)
	}
	rows := f.counterAuditLogFor(t, apiaryID)
	if len(rows) != 1 || rows[0].ChangeType != "create" {
		t.Fatalf("counter audit rows = %+v, want exactly [create]", rows)
	}
	if rows[0].ChangedFields != nil {
		t.Fatalf("create audit changed_fields = %v, want nil (create carries a baseline, not a diff)", rows[0].ChangedFields)
	}
	var createChange map[string]any
	if err := json.Unmarshal(rows[0].Change, &createChange); err != nil {
		t.Fatalf("unmarshal create change: %v", err)
	}
	if createChange["hive"] != float64(5) {
		t.Fatalf("create change = %+v, want {hive: 5} baseline", createChange)
	}
	if a := f.getApiary(t, apiaryID); a.HiveCount != 5 {
		t.Fatalf("hive_count after counter create = %d, want 5", a.HiveCount)
	}
}

// TestApiariesSlice_CounterOp_SuperType_KnownFirstClassAndAuditedSeparately
// is #346's server-side AC: `super` (D-20's "supers" example) is now a KNOWN
// counter type, so a super counter op is accepted (not rejected like an
// unknown type), stored as its OWN row keyed by (apiary_id, counter_type)
// alongside the hive counter (never colliding with it — the UNIQUE key is the
// pair, not just apiary_id), and history-audited under entity_type=
// apiary_counter with a baseline keyed by its own type. This is the whole of
// what the "code-only append to the known set" (D-20) had to buy on the
// server: no new apply/validate/audit code, just the const + set entry in
// counters.go — this test proves the existing generic machinery now carries
// it.
func TestApiariesSlice_CounterOp_SuperType_KnownFirstClassAndAuditedSeparately(t *testing.T) {
	f := newApiariesFixture(t)
	apiaryID := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	// A hive-less apiary create (the new client's shape) — no counter rows yet.
	createData, _ := json.Marshal(map[string]any{"name": "Encosta Nova"})
	create := api.Op{Op: "put", EntityType: "apiary", ID: apiaryID, Data: createData, UpdatedAt: t0}
	if got := f.apply(t, create); got.Results[0].Result != "applied" {
		t.Fatalf("create apiary result = %q, want applied", got.Results[0].Result)
	}

	// A super counter op is ACCEPTED (proving `super` is in the known set —
	// an unknown type is rejected by TestApiariesSlice_CounterOp_Validate
	// RejectsUnknownCounterType).
	if got := f.apply(t, counterOp(apiaryID, counterTypeSuper, 6, t0.Add(time.Second))); got.Results[0].Result != "applied" {
		t.Fatalf("super counter op result = %q, want applied", got.Results[0].Result)
	}
	// It landed as its own row; hive still reads 0 (no hive row) — the two
	// types coexist, keyed by (apiary_id, counter_type).
	rows := f.countersFor(t, apiaryID) // ordered by counter_type
	if len(rows) != 1 || rows[0].CounterType != "super" || rows[0].Value != 6 {
		t.Fatalf("counters after super op = %+v, want exactly [{super 6}]", rows)
	}
	if a := f.getApiary(t, apiaryID); a.HiveCount != 0 {
		t.Fatalf("hive_count with only a super row = %d, want 0 (unaffected)", a.HiveCount)
	}

	// Adding a hive counter now yields two independent rows (no collision).
	if got := f.apply(t, counterOp(apiaryID, counterTypeHive, 4, t0.Add(2*time.Second))); got.Results[0].Result != "applied" {
		t.Fatalf("hive counter op result = %q, want applied", got.Results[0].Result)
	}
	rows = f.countersFor(t, apiaryID)
	if len(rows) != 2 || rows[0].CounterType != "hive" || rows[0].Value != 4 ||
		rows[1].CounterType != "super" || rows[1].Value != 6 {
		t.Fatalf("counters after hive+super = %+v, want [{hive 4},{super 6}]", rows)
	}

	// The super write audited under entity_type=apiary_counter as a create
	// baseline keyed by its own type (not "hive").
	audit := f.counterAuditLogFor(t, apiaryID)
	var superCreate *auditRow
	for i := range audit {
		if audit[i].ChangeType == "create" {
			var change map[string]any
			if err := json.Unmarshal(audit[i].Change, &change); err == nil {
				if _, ok := change["super"]; ok {
					superCreate = &audit[i]
				}
			}
		}
	}
	if superCreate == nil {
		t.Fatalf("no apiary_counter create audit row keyed by 'super' found in %+v", audit)
	}
	var change map[string]any
	if err := json.Unmarshal(superCreate.Change, &change); err != nil {
		t.Fatalf("unmarshal super create change: %v", err)
	}
	if change["super"] != float64(6) {
		t.Fatalf("super create change = %+v, want {super: 6} baseline", change)
	}
}

// counterAuditLogFor is main_test.go's auditLogFor scoped to
// entity_type=apiary_counter (rather than "apiary") — the counter op's own
// history rows, keyed by apiary_id (applyCounterOp's doc comment).
func (f *apiariesFixture) counterAuditLogFor(t *testing.T, apiaryID string) []auditRow {
	t.Helper()
	rows, err := f.pool.Query(context.Background(),
		`SELECT change_type, actor_user_id, occurred_at, recorded_at, changed_fields, change
		 FROM apiaries.audit_log
		 WHERE entity_type = 'apiary_counter' AND entity_id = $1
		 ORDER BY recorded_at, id`, apiaryID)
	if err != nil {
		t.Fatalf("query counter audit_log: %v", err)
	}
	defer rows.Close()

	var out []auditRow
	for rows.Next() {
		var (
			a       auditRow
			actorID uuid.UUID
		)
		if err := rows.Scan(&a.ChangeType, &actorID, &a.OccurredAt, &a.RecordedAt, &a.ChangedFields, &a.Change); err != nil {
			t.Fatalf("scan counter audit_log row: %v", err)
		}
		a.ActorUserID = actorID.String()
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate counter audit_log: %v", err)
	}
	return out
}

// --- Migration data backfill + column retirement (#256 AC: "Existing
// hive_count data migrated into hive counter rows; the apiaries.hive_count
// column retired from schema") ---

// TestApiariesMigration_HiveCountColumnRetiredFromSchema confirms the column
// is actually GONE from the live, migrated schema — not just unused by the
// Go code. A regression that reintroduced the column (or forgot to run
// 00005's DROP COLUMN) would leave this failing rather than silently passing
// the app-level tests above (which never assert column ABSENCE, only
// behavior).
func TestApiariesMigration_HiveCountColumnRetiredFromSchema(t *testing.T) {
	f := newApiariesFixture(t)

	var exists bool
	err := f.pool.QueryRow(context.Background(), `
		SELECT EXISTS (
			SELECT 1 FROM information_schema.columns
			WHERE table_schema = 'apiaries' AND table_name = 'apiaries' AND column_name = 'hive_count'
		)`).Scan(&exists)
	if err != nil {
		t.Fatalf("query information_schema.columns: %v", err)
	}
	if exists {
		t.Fatalf("apiaries.apiaries.hive_count column still exists — #256 requires it retired (decoupled into apiary_counters)")
	}
}

// TestApiariesMigration_ApiaryCountersTableShape confirms the new table's DB
// shape matches #256's AC directly: organization_id present (tenancy),
// apiary_id FK, counter_type + value columns, and the UNIQUE(apiary_id,
// counter_type) constraint actually enforced at the DB level (a second
// INSERT bypassing the Go upsert entirely — raw SQL — must fail with
// unique_violation, proving the constraint isn't just application-level
// discipline).
func TestApiariesMigration_ApiaryCountersTableShape(t *testing.T) {
	f := newApiariesFixture(t)
	apiaryID := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	if got := f.apply(t, putOp(apiaryID, "Encosta Nova", 3, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create apiary result = %q, want applied", got.Results[0].Result)
	}

	// A second raw INSERT for the same (apiary_id, counter_type) — bypassing
	// upsertCounter's ON CONFLICT entirely — must fail at the DB level.
	_, err := f.pool.Exec(context.Background(),
		`INSERT INTO apiaries.apiary_counters (id, organization_id, apiary_id, counter_type, value)
		 SELECT gen_random_uuid(), organization_id, $1, 'hive', 1
		 FROM apiaries.apiaries WHERE id = $1`, apiaryID)
	if err == nil {
		t.Fatalf("raw duplicate (apiary_id, counter_type) insert unexpectedly succeeded — UNIQUE constraint not enforced at the DB level")
	}

	// A negative value must fail the table's CHECK(value >= 0) constraint,
	// independent of the Go-level validation validateCounterOp already
	// covers — defense in depth at the schema itself.
	_, err = f.pool.Exec(context.Background(),
		`INSERT INTO apiaries.apiary_counters (id, organization_id, apiary_id, counter_type, value)
		 SELECT gen_random_uuid(), organization_id, $1, 'nucs', -1
		 FROM apiaries.apiaries WHERE id = $1`, apiaryID)
	if err == nil {
		t.Fatalf("raw negative-value insert unexpectedly succeeded — CHECK(value >= 0) not enforced at the DB level")
	}
}

// --- Cross-tenant IDOR (CRITICAL fix: applyCounterOp must verify apiary
// ownership before writing counter data) ---

// TestApiariesSlice_CrossOrg_CounterOpCannotMutateOtherOrgsCounter is the
// counter-op counterpart of main_test.go's
// TestApiariesSlice_CrossOrg_SyncApplyCannotMutateOtherOrgsRow: applyCounterOp
// (api/sync.go) took the client-supplied apiary_id from a counter op and
// never verified it belongs to the caller's org before writing. Because
// GetApiaryCounter is itself org-scoped, a foreign org's lookup always
// misses (the org-scoped WHERE never matches a row that belongs to a
// different org), which used to fall straight into the "missing => create"
// branch and upsert UNCONDITIONALLY -- no LWW comparison at all, since
// "missing" always short-circuited to an unconditional write. The table's
// UNIQUE(apiary_id, counter_type) ON CONFLICT target then let that
// unconditional upsert silently overwrite the VICTIM's existing counter
// row's value (organization_id itself isn't in the ON CONFLICT SET clause,
// so the row doesn't change owner -- but its value does). This proves org B
// cannot inject/overwrite org A's hive count via a counter op targeting org
// A's apiary_id.
func TestApiariesSlice_CrossOrg_CounterOpCannotMutateOtherOrgsCounter(t *testing.T) {
	f := newApiariesFixture(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	other := otherOrgCaller()

	// Org A creates an apiary with a real hive count.
	apiaryID := uuid.NewString()
	if got := f.apply(t, putOp(apiaryID, "Org A Apiary", 5, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create org A apiary result = %q, want applied", got.Results[0].Result)
	}
	before := f.countersFor(t, apiaryID)
	if len(before) != 1 || before[0].Value != 5 {
		t.Fatalf("org A counters before attack = %+v, want [{hive 5}]", before)
	}

	// Org B submits a counter op targeting ORG A's apiary_id -- a forged
	// cross-tenant write attempt, at a timestamp far in the future so LWW
	// alone (were it even consulted) would let it win.
	attack := counterOp(apiaryID, counterTypeHive, 9999, t0.Add(time.Hour))
	got := f.applyAs(t, other, attack)
	if got.Results[0].Result != "applied" {
		t.Fatalf("cross-org counter attack result = %q, want applied (no-op, not rejected -- matches the existing cross-org delete convention, TestApiariesSlice_CrossOrg_SyncApplyCannotMutateOtherOrgsRow)", got.Results[0].Result)
	}

	// Org A's counter must be completely unaffected: same value, same row id.
	after := f.countersFor(t, apiaryID)
	if len(after) != 1 {
		t.Fatalf("org A counters after attack = %+v, want exactly 1 row (attack must not create a second row)", after)
	}
	if after[0].Value != 5 {
		t.Fatalf("org A counter value after cross-org attack = %d, want unchanged 5 (was overwritten by the attacker's 9999)", after[0].Value)
	}
	if after[0].ID != before[0].ID {
		t.Fatalf("org A counter row id changed from %s to %s -- attack must not touch the existing row", before[0].ID, after[0].ID)
	}

	// The apiary's own hive_count read (COALESCE over the counter join) must
	// also still reflect org A's real value, not the attacker's.
	if a := f.getApiary(t, apiaryID); a.HiveCount != 5 {
		t.Fatalf("org A apiary hive_count after cross-org counter attack = %d, want unchanged 5", a.HiveCount)
	}

	// No apiary_counter-typed audit row should have been written for this
	// no-op -- a no-op against a foreign/unknown apiary applies no domain
	// change, so it gets no audit row (mirrors writeAuditLog's "no domain
	// change => no audit row" contract already proven for entity_type=apiary).
	if rows := f.counterAuditLogFor(t, apiaryID); len(rows) != 0 {
		t.Fatalf("counter audit rows after cross-org no-op = %+v, want none", rows)
	}
}
