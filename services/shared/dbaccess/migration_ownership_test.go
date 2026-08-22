package dbaccess_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"

	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

// These are the regression tests for #541: #62's immutability hardening moves
// `<schema>.audit_log` ownership off `<schema>_svc` onto `beekeepingit`, but
// migrations ran AS `<schema>_svc` (dbaccess.Migrate called from each
// service's main.go with the service's own DSN). Postgres requires table
// OWNERSHIP for ALTER TABLE — it is not a grantable privilege — so once the
// lockdown had run, that service could never migrate its own history table
// again.
//
// It shipped in v0.0.1-rc8 as organizations migration 00005 (#470, adding
// audit_log.actor_scope) and crashlooped 7113 times over 25 days on staging
// while the previous ReplicaSet kept serving, so every health check stayed
// green and nothing alerted.
//
// WHY CI NEVER CAUGHT IT, and what these tests therefore have to do: on a
// FRESH cluster every migration runs at pod startup BEFORE the lockdown
// (a post-install/post-upgrade Helm hook, weight 2) has ever applied, so
// versions 1..N all succeed and the bug is invisible. It only bites on a
// cluster where a PREVIOUS deploy already locked the table and a LATER
// migration then arrives. So a test that merely migrates a fresh schema
// proves nothing — the ordering (lock first, THEN migrate) is the entire
// bug, and both tests below reproduce it explicitly.

// historyTableMigrations is a two-step goose sequence shaped like the real
// one that broke: create the history table, then — in a LATER migration, the
// way 00005 arrived long after 00003 — alter it.
func historyTableMigrations() fstest.MapFS {
	return fstest.MapFS{
		"00001_create_audit_log.sql": &fstest.MapFile{Data: []byte(`
-- +goose Up
CREATE TABLE ` + auditFixtureSchema + `.audit_log (
    id   UUID PRIMARY KEY,
    note TEXT NOT NULL
);
`)},
		"00002_add_actor_scope.sql": &fstest.MapFile{Data: []byte(`
-- +goose Up
ALTER TABLE ` + auditFixtureSchema + `.audit_log
    ADD COLUMN actor_scope TEXT NOT NULL DEFAULT 'member';
`)},
	}
}

// onlyFirstMigration returns just the CREATE step, so a test can simulate the
// already-deployed state (history table created and locked down by an earlier
// release) before the second migration ever exists.
func onlyFirstMigration(t *testing.T) fstest.MapFS {
	t.Helper()
	all := historyTableMigrations()
	return fstest.MapFS{"00001_create_audit_log.sql": all["00001_create_audit_log.sql"]}
}

// TestMigrate_ServiceRoleCannotMigrateLockedDownHistoryTable is the direct
// proof of #541's root cause, reproducing the exact production sequence:
// deploy N creates and locks the table, deploy N+1 ships a migration that
// alters it, and the service role — no longer the owner — cannot apply it.
//
// This test documents BROKEN behaviour deliberately: it asserts the failure,
// so it passes both before and after the fix. Its job is to pin down WHY
// migrations may never run as `<schema>_svc`, so nobody reintroduces that
// wiring later and rediscovers this the way staging did.
func TestMigrate_ServiceRoleCannotMigrateLockedDownHistoryTable(t *testing.T) {
	ctx := context.Background()
	f := newAuditImmutabilityFixture(t)
	f.grantOwnerMembershipInSvcRoleAsIfByCNPGOperator(t)

	// Deploy N: the service creates its history table (as production did
	// until this fix), then the immutability hook locks it down.
	if err := dbaccess.Migrate(ctx, f.svcDSN, onlyFirstMigration(t)); err != nil {
		t.Fatalf("first migration as %s: want success, got %v", auditFixtureSvcRole, err)
	}
	lockDownHistoryTable(t, f.owner, auditFixtureSchema, auditFixtureSvcRole, "audit_log")

	// Deploy N+1: the new ALTER migration arrives. This is the crashloop.
	err := dbaccess.Migrate(ctx, f.svcDSN, historyTableMigrations())
	if err == nil {
		t.Fatalf("second migration as %s against a locked-down audit_log: want a permission error (ALTER TABLE requires ownership, and #62 moved it to %s), got success — if this now succeeds, #541's premise changed and the migrator-role split can be revisited",
			auditFixtureSvcRole, auditFixtureOwner)
	}
	if !strings.Contains(err.Error(), "must be owner of table") {
		t.Fatalf("second migration as %s: want a 'must be owner of table' error (SQLSTATE 42501), got %v", auditFixtureSvcRole, err)
	}
}

// TestMigrate_MigratorRoleCanMigrateLockedDownHistoryTable is the fix's
// invariant: run the SAME later migration as the migrator/owner role and it
// applies cleanly, while the runtime role keeps exactly the access #62
// requires — INSERT/SELECT, never UPDATE/DELETE/TRUNCATE.
//
// This is the whole point of the new split. Because `<schema>_svc` never owns
// the table, immutability no longer needs an ownership-transfer dance at all
// (audit-immutability-job.yaml's job): it reduces to simply not granting
// UPDATE/DELETE, and the service cannot self-GRANT its way back in because
// Postgres silently no-ops a GRANT of a privilege the grantor doesn't hold.
func TestMigrate_MigratorRoleCanMigrateLockedDownHistoryTable(t *testing.T) {
	ctx := context.Background()
	f := newAuditImmutabilityFixture(t)
	f.grantOwnerMembershipInSvcRoleAsIfByCNPGOperator(t)

	// Same already-deployed starting state as the test above: table created
	// by an earlier release and already locked down.
	if err := dbaccess.Migrate(ctx, f.svcDSN, onlyFirstMigration(t)); err != nil {
		t.Fatalf("first migration: want success, got %v", err)
	}
	lockDownHistoryTable(t, f.owner, auditFixtureSchema, auditFixtureSvcRole, "audit_log")

	// The fix: the migrator role runs migrations, and owns the table.
	if err := dbaccess.Migrate(ctx, f.ownerDSN, historyTableMigrations()); err != nil {
		t.Fatalf("second migration as %s (the migrator/owner): want success, got %v", auditFixtureOwner, err)
	}

	if got := f.tableOwner(t, "audit_log"); got != auditFixtureOwner {
		t.Fatalf("audit_log owner after migration: got %q, want %q", got, auditFixtureOwner)
	}

	// #62's guarantee must survive the fix, not be traded away for it.
	f.assertServiceCanInsertAndSelect(t, "audit_log")
	f.assertServiceCannotUpdateDeleteOrTruncate(t, "audit_log")

	// And the runtime role still cannot perform DDL of its own.
	if _, err := f.svc.Exec(ctx, `ALTER TABLE `+auditFixtureSchema+`.audit_log ADD COLUMN sneaky TEXT`); err == nil {
		t.Fatalf("%s ALTER TABLE audit_log: want a permission error, got success — the runtime role must never hold DDL rights on a history table", auditFixtureSvcRole)
	}
}

// TestServices_DoNotRunMigrationsAtStartup is the architectural guard that
// keeps the fix in place. The integration tests above prove which ROLE can
// migrate; this one proves production actually wires it that way, because
// the bug was never about SQL semantics — it was about main.go calling
// dbaccess.Migrate with the service's own runtime DSN.
//
// Structural rather than behavioural on purpose: "the service process does
// not perform DDL" is a property of the deployment topology (12-factor XII,
// admin processes run as one-off jobs), and there is no runtime assertion
// that catches a service quietly reintroducing a startup migration.
func TestServices_DoNotRunMigrationsAtStartup(t *testing.T) {
	// services/shared is its own module (see go.work); its siblings are the
	// deployable services.
	entries, err := os.ReadDir(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("read services dir: %v", err)
	}

	var checked int
	for _, e := range entries {
		if !e.IsDir() || e.Name() == "shared" {
			continue
		}
		mainGo := filepath.Join("..", "..", e.Name(), "main.go")
		src, err := os.ReadFile(mainGo)
		if os.IsNotExist(err) {
			continue // not a deployable service (e.g. servicetemplate variants)
		}
		if err != nil {
			t.Fatalf("read %s: %v", mainGo, err)
		}
		checked++

		if strings.Contains(string(src), "dbaccess.Migrate(") {
			t.Errorf("%s calls dbaccess.Migrate at startup: migrations must run as the migrator role in the deploy-time migrate job, never as the service's runtime role (#541). The service's runtime credential must hold DML only — if it can migrate, it can also DROP/ALTER, which is exactly what #62 set out to prevent.", mainGo)
		}
	}

	if checked == 0 {
		t.Fatal("scanned no service main.go files — the layout assumption in this test is stale, fix the test rather than deleting it")
	}
}
