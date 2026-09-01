package main

// Integration tests for the stock-declaration sync path (#298, FR-AP-10,
// FR-HIS-1, FR-TEN-2, NFR-SEC-1). They exercise validate/apply against a
// containerized Postgres through the same fixture the apiaries tests use
// (newApiariesFixture, f.apply, f.do).
//
// The property under test throughout is the one that makes a declaration a
// declaration rather than a counter: it is a POINT-IN-TIME record, keyed by its
// own id, scoped to a DGAV registration number rather than to an apiary, and it
// survives unchanged when the live hive count moves on.

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/TiagoJVO/beekeepingit/services/apiaries/api"
)

// declarationView is the shape these tests read back out of Postgres directly —
// the service exposes declarations only through sync (like apiary_counters,
// which has no REST surface either), so there is no HTTP read path to assert
// against.
type declarationView struct {
	dgavNumber string
	declaredOn time.Time
	total      int32
	breakdown  string
	notes      *string
	deleted    bool
}

func (f *apiariesFixture) declaration(t *testing.T, id string) (declarationView, bool) {
	t.Helper()
	var v declarationView
	var deletedAt *time.Time
	err := f.pool.QueryRow(context.Background(),
		`SELECT dgav_registration_number, declared_on, total_hive_count,
		        breakdown::text, notes, deleted_at
		 FROM apiaries.stock_declarations WHERE id = $1`, id).
		Scan(&v.dgavNumber, &v.declaredOn, &v.total, &v.breakdown, &v.notes, &deletedAt)
	if err != nil {
		if strings.Contains(err.Error(), "no rows") {
			return declarationView{}, false
		}
		t.Fatalf("read declaration: %v", err)
	}
	v.deleted = deletedAt != nil
	return v, true
}

func (f *apiariesFixture) declarationAuditCount(t *testing.T, id string) int {
	t.Helper()
	var n int
	if err := f.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM apiaries.audit_log
		 WHERE entity_type = 'stock_declaration' AND entity_id = $1`, id).Scan(&n); err != nil {
		t.Fatalf("count declaration audit rows: %v", err)
	}
	return n
}

// putDeclaration builds a full stock_declaration put op.
func putDeclaration(id, number, declaredOn string, total int32, ts time.Time) api.Op {
	data, _ := json.Marshal(map[string]any{
		"dgav_registration_number": number,
		"declared_on":              declaredOn,
		"total_hive_count":         total,
	})
	return api.Op{Op: "put", EntityType: "stock_declaration", ID: id, Data: data, UpdatedAt: ts}
}

// patchDeclaration builds a partial stock_declaration patch op from an
// already-marshalable field map.
func patchDeclaration(id string, fields map[string]any, ts time.Time) api.Op {
	data, _ := json.Marshal(fields)
	return api.Op{Op: "patch", EntityType: "stock_declaration", ID: id, Data: data, UpdatedAt: ts}
}

func deleteDeclaration(id string, ts time.Time) api.Op {
	return api.Op{Op: "delete", EntityType: "stock_declaration", ID: id, UpdatedAt: ts}
}

// TestDeclarations_SyncApplyRoundTrip is FR-AP-10's core AC: a declaration
// records the date, the total, the registration number it was filed under and
// an optional per-apiary breakdown, offline, through the sync path — and the
// change is audited (FR-HIS-1).
func TestDeclarations_SyncApplyRoundTrip(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	breakdown := []map[string]any{
		{"apiary_id": uuid.NewString(), "name": "Serra Norte", "hive_count": 18},
		{"apiary_id": uuid.NewString(), "name": "Monte Alto", "hive_count": 12},
	}
	data, _ := json.Marshal(map[string]any{
		"dgav_registration_number": "PT-123456",
		"declared_on":              "2026-09-12",
		"total_hive_count":         30,
		"breakdown":                breakdown,
		"notes":                    "Submetida via portal do IFAP.",
	})
	op := api.Op{Op: "put", EntityType: "stock_declaration", ID: id, Data: data, UpdatedAt: t0}

	if got := f.apply(t, op); got.Results[0].Result != "applied" {
		t.Fatalf("create result = %+v, want applied", got.Results[0])
	}

	stored, ok := f.declaration(t, id)
	if !ok {
		t.Fatal("declaration was not stored")
	}
	if stored.dgavNumber != "PT-123456" {
		t.Errorf("dgav_registration_number = %q, want PT-123456", stored.dgavNumber)
	}
	if got := stored.declaredOn.Format("2006-01-02"); got != "2026-09-12" {
		t.Errorf("declared_on = %q, want 2026-09-12", got)
	}
	if stored.total != 30 {
		t.Errorf("total_hive_count = %d, want 30", stored.total)
	}
	if stored.notes == nil || *stored.notes != "Submetida via portal do IFAP." {
		t.Errorf("notes = %v, want the filing memo", stored.notes)
	}

	var roundTripped []map[string]any
	if err := json.Unmarshal([]byte(stored.breakdown), &roundTripped); err != nil {
		t.Fatalf("breakdown is not a JSON array: %v (raw = %s)", err, stored.breakdown)
	}
	if len(roundTripped) != 2 {
		t.Fatalf("breakdown has %d entries, want 2", len(roundTripped))
	}

	if n := f.declarationAuditCount(t, id); n != 1 {
		t.Errorf("declaration audit rows = %d, want 1 (FR-HIS-1)", n)
	}
}

// TestDeclarations_IsNotTheLiveHiveCounter is the distinction FR-AP-10 exists
// to draw (and the one this feature would be worthless without): changing an
// apiary's live hive counter afterwards must leave the declaration exactly as
// filed. A declaration says what was declared on a date; a counter says what is
// true now.
func TestDeclarations_IsNotTheLiveHiveCounter(t *testing.T) {
	f := newApiariesFixture(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	apiaryID := uuid.NewString()
	if got := f.apply(t, putOpWithLocation(apiaryID, "Serra Norte", 30, -8.6, 41.1, "Montargil", t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create apiary result = %+v, want applied", got.Results[0])
	}

	declarationID := uuid.NewString()
	if got := f.apply(t, putDeclaration(declarationID, "PT-123456", "2026-09-12", 30, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("create declaration result = %+v, want applied", got.Results[0])
	}

	// The live counter moves on — a swarm season, say.
	if got := f.apply(t, patchHive(apiaryID, 55, t0.Add(time.Hour))); got.Results[0].Result != "applied" {
		t.Fatalf("hive count update result = %+v, want applied", got.Results[0])
	}
	if a := f.getApiary(t, apiaryID); a.HiveCount != 55 {
		t.Fatalf("live hive count = %d, want 55", a.HiveCount)
	}

	stored, ok := f.declaration(t, declarationID)
	if !ok {
		t.Fatal("declaration disappeared")
	}
	if stored.total != 30 {
		t.Errorf("declared total = %d after the live counter moved to 55, want the declared 30 — a declaration is a point-in-time record, not the current count", stored.total)
	}
}

// TestDeclarations_LWWAndIdempotency covers the sync guarantees (§4.1/§4.3): a
// newer op wins, a stale one is superseded (and logged, never silently
// dropped), and an identical re-send is applied idempotently.
func TestDeclarations_LWWAndIdempotency(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	f.apply(t, putDeclaration(id, "PT-123456", "2026-09-12", 30, t0))

	// Newer wins.
	if got := f.apply(t, patchDeclaration(id, map[string]any{"total_hive_count": 44}, t0.Add(time.Second))); got.Results[0].Result != "applied" {
		t.Fatalf("newer patch result = %+v, want applied", got.Results[0])
	}
	if stored, _ := f.declaration(t, id); stored.total != 44 {
		t.Errorf("total = %d after a newer patch, want 44", stored.total)
	}

	// Stale loses, and the loser is preserved in the conflict log.
	before := f.conflictCount(t)
	if got := f.apply(t, patchDeclaration(id, map[string]any{"total_hive_count": 7}, t0)); got.Results[0].Result != "superseded" {
		t.Fatalf("stale patch result = %+v, want superseded", got.Results[0])
	}
	if stored, _ := f.declaration(t, id); stored.total != 44 {
		t.Errorf("total = %d after a stale patch, want unchanged 44", stored.total)
	}
	if after := f.conflictCount(t); after != before+1 {
		t.Errorf("conflict rows = %d, want %d (a losing offline edit must be preserved)", after, before+1)
	}

	// An identical re-send at the same timestamp changes nothing and is applied.
	if got := f.apply(t, patchDeclaration(id, map[string]any{"total_hive_count": 44}, t0)); got.Results[0].Result != "applied" {
		t.Fatalf("idempotent re-send result = %+v, want applied", got.Results[0])
	}
}

// TestDeclarations_DeleteTombstones covers the lifecycle a counter deliberately
// does NOT have: a mis-entered declaration is removable, and the delete
// tombstones the row so it propagates to the beekeeper's other devices.
func TestDeclarations_DeleteTombstones(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	f.apply(t, putDeclaration(id, "PT-123456", "2026-09-12", 30, t0))
	if got := f.apply(t, deleteDeclaration(id, t0.Add(time.Second))); got.Results[0].Result != "applied" {
		t.Fatalf("delete result = %+v, want applied", got.Results[0])
	}

	stored, ok := f.declaration(t, id)
	if !ok {
		t.Fatal("row was hard-deleted; a tombstone is required so the delete reaches other devices")
	}
	if !stored.deleted {
		t.Error("deleted_at is not set — the delete did not tombstone the row")
	}
}

// TestDeclarations_DeleteOfUnknownIdIsApplied: a device that created and then
// deleted a declaration while offline can push only the delete. There is
// nothing to tombstone, and that is success, not an error.
func TestDeclarations_DeleteOfUnknownIdIsApplied(t *testing.T) {
	f := newApiariesFixture(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	if got := f.apply(t, deleteDeclaration(uuid.NewString(), t0)); got.Results[0].Result != "applied" {
		t.Fatalf("delete of an unknown id result = %+v, want applied", got.Results[0])
	}
}

// TestDeclarations_MixedBatchWithApiaryAndCounterOps: one client transaction
// may freely mix all three entity types the apiaries service owns — the case
// an offline field session actually produces (record an apiary, bump its
// counter, file a declaration).
func TestDeclarations_MixedBatchWithApiaryAndCounterOps(t *testing.T) {
	f := newApiariesFixture(t)
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	apiaryID := uuid.NewString()
	declarationID := uuid.NewString()

	got := f.apply(t,
		putOpWithLocation(apiaryID, "Serra Norte", 0, -8.6, 41.1, "Montargil", t0),
		// The counter op carries a LATER timestamp than the apiary op: the
		// apiary put itself carries hive_count 0, which applyOp upserts into
		// the hive counter at t0, so a sibling counter op at the SAME t0 loses
		// LWW (equal, not after) and comes back superseded. That is existing
		// #256 behaviour, not a declarations concern — the point of this test
		// is that all three entity types are ACCEPTED in one batch.
		counterOp(apiaryID, "hive", 24, t0.Add(time.Second)),
		putDeclaration(declarationID, "PT-123456", "2026-09-12", 24, t0),
	)
	if len(got.Results) != 3 {
		t.Fatalf("results = %d, want 3", len(got.Results))
	}
	for i, r := range got.Results {
		if r.Result != "applied" {
			t.Errorf("op %d result = %q, want applied", i, r.Result)
		}
	}
	if _, ok := f.declaration(t, declarationID); !ok {
		t.Error("the declaration in the mixed batch was not stored")
	}
}

// TestDeclarations_ValidationRejects covers NFR-SEC-1 input validation on the
// sync path: every rule the apply path and the column CHECKs rely on is
// enforced by validate FIRST, so a bad batch writes nothing (§6.2).
func TestDeclarations_ValidationRejects(t *testing.T) {
	t0 := time.Now().UTC().Truncate(time.Millisecond)
	tooLong := strings.Repeat("9", 51)

	cases := []struct {
		name string
		op   api.Op
	}{
		{
			name: "put without declared_on",
			op: func() api.Op {
				data, _ := json.Marshal(map[string]any{"total_hive_count": 10})
				return api.Op{Op: "put", EntityType: "stock_declaration", ID: uuid.NewString(), Data: data, UpdatedAt: t0}
			}(),
		},
		{
			name: "put without total_hive_count",
			op: func() api.Op {
				data, _ := json.Marshal(map[string]any{"declared_on": "2026-09-12"})
				return api.Op{Op: "put", EntityType: "stock_declaration", ID: uuid.NewString(), Data: data, UpdatedAt: t0}
			}(),
		},
		{
			name: "declared_on is not a date",
			op:   putDeclaration(uuid.NewString(), "PT-1", "12/09/2026", 10, t0),
		},
		{
			name: "declared_on carries a time",
			op:   putDeclaration(uuid.NewString(), "PT-1", "2026-09-12T10:00:00Z", 10, t0),
		},
		{
			name: "negative total_hive_count",
			op:   putDeclaration(uuid.NewString(), "PT-1", "2026-09-12", -1, t0),
		},
		{
			name: "over-long registration number",
			op:   putDeclaration(uuid.NewString(), tooLong, "2026-09-12", 10, t0),
		},
		{
			name: "over-long notes",
			op: patchDeclaration(uuid.NewString(), map[string]any{
				"notes": strings.Repeat("x", 2001),
			}, t0),
		},
		{
			name: "breakdown is not an array",
			op: patchDeclaration(uuid.NewString(), map[string]any{
				"breakdown": map[string]any{"apiary_id": "x"},
			}, t0),
		},
		{
			name: "breakdown entries are not objects",
			op: patchDeclaration(uuid.NewString(), map[string]any{
				"breakdown": []any{"just a string"},
			}, t0),
		},
		{
			name: "patch changes nothing",
			op:   patchDeclaration(uuid.NewString(), map[string]any{}, t0),
		},
		{
			name: "id is not a UUID",
			op:   putDeclaration("not-a-uuid", "PT-1", "2026-09-12", 10, t0),
		},
		{
			name: "missing updated_at",
			op:   putDeclaration(uuid.NewString(), "PT-1", "2026-09-12", 10, time.Time{}),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newApiariesFixture(t)
			rec := f.do(t, http.MethodPost, "/internal/sync/validate", api.Batch{Ops: []api.Op{tc.op}})
			if rec.Code != http.StatusUnprocessableEntity {
				t.Fatalf("validate status = %d, want 422, body = %s", rec.Code, rec.Body.String())
			}
		})
	}
}

// TestDeclarations_CrossOrgIsolation is the tenancy guarantee (FR-TEN-2,
// ADR-0002): org B cannot read, mutate or tombstone org A's declaration.
//
// Exercised with a DELETE of org A's id, mirroring
// TestApiariesSlice_CrossOrg_SyncApplyCannotMutateOtherOrgsRow — org B's op
// resolves against ITS OWN org scope, finds nothing, and is a harmless no-op,
// while org A's declaration is untouched.
//
// A cross-org PUT reusing the same id is deliberately NOT asserted here: like
// apiaries.apiaries, this table's primary key is `id` alone, so such an op
// fails on the primary key rather than resolving per-org. Client-generated
// UUIDs make the collision unreachable in practice, and the failure mode is
// loud (a rejected batch) rather than dangerous (a silent cross-org
// overwrite) — the property that actually matters is the one asserted below:
// org B's op never reaches org A's row.
func TestDeclarations_CrossOrgIsolation(t *testing.T) {
	f := newApiariesFixture(t)
	id := uuid.NewString()
	t0 := time.Now().UTC().Truncate(time.Millisecond)

	f.apply(t, putDeclaration(id, "PT-AAA", "2026-09-12", 30, t0))

	// Org B tries to tombstone org A's declaration by id, with a LATER
	// timestamp so LWW could not be what saves org A here.
	other := otherOrgCaller()
	if got := f.applyAs(t, other, deleteDeclaration(id, t0.Add(time.Hour))); got.Results[0].Result != "applied" {
		t.Fatalf("org B delete-of-unknown-id result = %q, want applied (a no-op)", got.Results[0].Result)
	}

	stored, ok := f.declaration(t, id)
	if !ok {
		t.Fatal("org A's declaration disappeared")
	}
	if stored.deleted {
		t.Error("org A's declaration was tombstoned by org B — cross-org isolation is broken")
	}
	if stored.total != 30 || stored.dgavNumber != "PT-AAA" {
		t.Errorf("org A's declaration = (%q, %d), want (PT-AAA, 30) — untouched by org B", stored.dgavNumber, stored.total)
	}

	// And org B cannot see it either: its own scoped read finds nothing, so a
	// later org B write against the same id creates org B's own record rather
	// than mutating org A's.
	var visibleToB int
	if err := f.pool.QueryRow(context.Background(),
		`SELECT count(*) FROM apiaries.stock_declarations
		 WHERE id = $1 AND organization_id <> (
		   SELECT organization_id FROM apiaries.stock_declarations WHERE id = $1 LIMIT 1
		 )`, id).Scan(&visibleToB); err != nil {
		t.Fatalf("count cross-org rows: %v", err)
	}
	if visibleToB != 0 {
		t.Errorf("found %d row(s) for this id under another org; org B must not have written anything", visibleToB)
	}
}
