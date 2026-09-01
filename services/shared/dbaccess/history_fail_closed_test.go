package dbaccess_test

import (
	"context"
	"strings"
	"testing"
)

// This file is #553's acceptance proof: adding a history table under a name
// the table-grants pass does not know must either lock it down or FAIL the
// release — it must never silently stay mutable.
//
// THE GAP THIS CLOSES. `postgres.runtimeGrantsPsqlArgs` (charts/postgres/
// templates/_helpers.tpl) grants blanket DML to `<schema>_svc` and then
// revokes UPDATE/DELETE/TRUNCATE off the history tables by name. That list
// used to be two literals inlined in the template, so a history table under a
// third name kept full DML after the blanket GRANT, forever, with no failure
// signal — fail-open. #545 narrowed half of it (the SELECT,INSERT default
// privileges mean such a table is at least never mutable AT CREATION), but the
// weight-3 blanket GRANT still opened it in steady state.
//
// THE FIX UNDER TEST, mirrored here by runRuntimeGrants
// (migrator_isolation_test.go): the list moved to `postgres.historyTables` in
// chart values, and the DO block gained a guard that RAISEs an EXCEPTION for
// any table whose name ends `_log` (the convention every history table
// follows) that the list does not classify. The guard runs INSIDE the same
// transaction as the blanket GRANT, so tripping it rolls the GRANT back — the
// release fails at deploy time with the table's name in the log, and the
// table is never mutable at any instant, on any attempt.
//
// helm-e2e cannot substitute for this: it deploys schemas whose tables all
// follow the convention and are all classified, so the guard never fires
// there. The negative — an oddly-named history table — has to be provoked,
// which is what this fixture-based file does.

// TestHistoryFailClosed_UnclassifiedLogTableFailsTheRelease is the AC's core:
// a deliberately oddly-named history table (`event_log` — history-shaped, not
// in the list) makes the table-grants pass ERROR, naming the table, and the
// runtime role never holds UPDATE/DELETE/TRUNCATE on it at any point.
func TestHistoryFailClosed_UnclassifiedLogTableFailsTheRelease(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()

	// A future migration (hook weight 2) ships two tables the chart has never
	// heard of: a history-style `event_log`, and an ordinary domain table in
	// the same release — the latter exists to make the guard's rollback
	// observable below.
	for _, stmt := range []string{
		`CREATE TABLE apiaries.event_log (id UUID PRIMARY KEY, note TEXT NOT NULL)`,
		`CREATE TABLE apiaries.gadgets (id UUID PRIMARY KEY, note TEXT NOT NULL)`,
		`INSERT INTO apiaries.event_log (id, note) VALUES (gen_random_uuid(), 'seed')`,
		`INSERT INTO apiaries.gadgets (id, note) VALUES (gen_random_uuid(), 'seed')`,
	} {
		if _, err := f.aMigrator.Exec(ctx, stmt); err != nil {
			t.Fatalf("future migration (%q): %v", stmt, err)
		}
	}

	// The next table-grants pass (weight 3) must fail, not succeed —
	// succeeding is exactly the fail-open outcome #553 removes.
	err := runRuntimeGrants(f.aMigrator, isoSchemaA, defaultHistoryTables)
	if err == nil {
		t.Fatalf("table-grants over an unclassified event_log: want the #553 guard to abort the pass, got success — the fail-open gap is back")
	}
	// The failure must land with the table's name, so whoever is staring at a
	// failed release knows which table to classify or rename.
	if !strings.Contains(err.Error(), "event_log") {
		t.Fatalf("guard error must name the unclassified table so the failed release is actionable, got: %v", err)
	}

	// THE NEGATIVE THE ISSUE DEMANDS: at no point — not before the failed
	// pass, not after it — is event_log mutable by the runtime role. Before
	// the pass, #545's SELECT,INSERT default privileges are all it has; after,
	// the guard rolled the blanket GRANT back in the same transaction.
	for _, tc := range []struct{ what, stmt string }{
		{"UPDATE", `UPDATE apiaries.event_log SET note = 'tampered'`},
		{"DELETE", `DELETE FROM apiaries.event_log`},
		{"TRUNCATE", `TRUNCATE apiaries.event_log`},
	} {
		if _, err := f.aSvc.Exec(ctx, tc.stmt); err == nil {
			t.Fatalf("%s_svc can %s an UNCLASSIFIED history table after the guard tripped: want a permission error, got success — the table stayed silently mutable, which is the exact #553 outcome", isoSchemaA, tc.what)
		}
	}

	// It is still append-only usable, not bricked: the default privileges
	// grant SELECT, INSERT from birth, guard or no guard.
	if _, err := f.aSvc.Exec(ctx, `INSERT INTO apiaries.event_log (id, note) VALUES (gen_random_uuid(), 'ok')`); err != nil {
		t.Fatalf("%s_svc INSERT on event_log: want success via #545's default privileges, got %v", isoSchemaA, err)
	}
	if _, err := f.aSvc.Exec(ctx, `SELECT count(*) FROM apiaries.event_log`); err != nil {
		t.Fatalf("%s_svc SELECT on event_log: want success via #545's default privileges, got %v", isoSchemaA, err)
	}

	// And the rollback is real, not assumed: had the failed pass committed its
	// blanket GRANT before erroring (the pre-#541 autocommit bug this repo
	// already shipped once — see table-grants-job.yaml's header), the domain
	// table from the same release would now hold full DML. It must not.
	if _, err := f.aSvc.Exec(ctx, `UPDATE apiaries.gadgets SET note = 'tampered'`); err == nil {
		t.Fatalf("%s_svc holds UPDATE on a domain table from the same FAILED table-grants pass: want a permission error — the guard must abort the whole transaction, not error after the blanket GRANT committed", isoSchemaA)
	}
}

// TestHistoryFailClosed_ClassifyingTheTableLocksItDown is the other half of
// the AC's "either": once the oddly-named table IS classified (the values
// edit the guard's message demands), the same pass succeeds and the table
// gets the identical append-only treatment as audit_log — proving the guard
// forces a real resolution, not a dead end.
func TestHistoryFailClosed_ClassifyingTheTableLocksItDown(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()

	for _, stmt := range []string{
		`CREATE TABLE apiaries.event_log (id UUID PRIMARY KEY, note TEXT NOT NULL)`,
		`INSERT INTO apiaries.event_log (id, note) VALUES (gen_random_uuid(), 'seed')`,
	} {
		if _, err := f.aMigrator.Exec(ctx, stmt); err != nil {
			t.Fatalf("future migration (%q): %v", stmt, err)
		}
	}

	classified := append(append([]string{}, defaultHistoryTables...), "event_log")
	if err := runRuntimeGrants(f.aMigrator, isoSchemaA, classified); err != nil {
		t.Fatalf("table-grants with event_log classified in historyTables: want success, got %v", err)
	}

	// Same contract as audit_log: append and read, never mutate.
	if _, err := f.aSvc.Exec(ctx, `INSERT INTO apiaries.event_log (id, note) VALUES (gen_random_uuid(), 'ok')`); err != nil {
		t.Fatalf("%s_svc INSERT on a classified event_log: want success, got %v", isoSchemaA, err)
	}
	if _, err := f.aSvc.Exec(ctx, `SELECT count(*) FROM apiaries.event_log`); err != nil {
		t.Fatalf("%s_svc SELECT on a classified event_log: want success, got %v", isoSchemaA, err)
	}
	for _, tc := range []struct{ what, stmt string }{
		{"UPDATE", `UPDATE apiaries.event_log SET note = 'tampered'`},
		{"DELETE", `DELETE FROM apiaries.event_log`},
		{"TRUNCATE", `TRUNCATE apiaries.event_log`},
	} {
		if _, err := f.aSvc.Exec(ctx, tc.stmt); err == nil {
			t.Fatalf("%s_svc can %s a CLASSIFIED history table: want a permission error, got success — classification did not lock it down", isoSchemaA, tc.what)
		}
	}
}

// TestHistoryFailClosed_QuotedMixedCaseCannotSlipPast pins the lower() in the
// guard's pattern match: a quoted `"Audit_Log"` is a DIFFERENT table from
// `audit_log` to Postgres, so the list does not classify it — but its
// lower-cased name still matches the `%_log` pattern, so the guard trips
// rather than letting a case-mangled history table ride through as
// "not history-looking".
func TestHistoryFailClosed_QuotedMixedCaseCannotSlipPast(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()

	if _, err := f.aMigrator.Exec(ctx, `CREATE TABLE apiaries."Audit_Log" (id UUID PRIMARY KEY, note TEXT NOT NULL)`); err != nil {
		t.Fatalf("create quoted mixed-case table: %v", err)
	}

	err := runRuntimeGrants(f.aMigrator, isoSchemaA, defaultHistoryTables)
	if err == nil {
		t.Fatalf(`table-grants over apiaries."Audit_Log": want the #553 guard to trip (the quoted name is unclassified — it is not the audit_log the list names), got success`)
	}
	if !strings.Contains(err.Error(), "Audit_Log") {
		t.Fatalf("guard error must name the unclassified table, got: %v", err)
	}
}
