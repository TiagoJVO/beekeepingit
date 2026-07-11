package dbaccess_test

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

// auditImmutabilityFixture stands in for the production role/schema layout
// that infra/helm/beekeepingit/charts/postgres/templates/cluster.yaml and
// schema-grants-job.yaml set up: an app-owner role (`beekeepingit`) that owns
// the schema, and a least-privilege per-service runtime login role
// (`<schema>_svc`) granted only USAGE/CREATE on it — mirroring D-6 "schema
// per service". superuser is the testcontainers bootstrap role (stands in
// for whatever bootstraps the cluster; production never needs an actual
// Postgres superuser for any of this beyond role/db creation, which CNPG's
// operator already does out of band — see the Helm job's header comment).
//
// It also grants beekeepingit PERMANENT plain membership in apiaries_svc —
// schema-grants-job.yaml's job now does this for every `<schema>_svc` role,
// right alongside the existing `GRANT USAGE, CREATE ON SCHEMA`. Postgres
// role membership needs ADMIN OPTION to revoke (confirmed empirically: a
// bootstrap/superuser-granted plain membership can't be revoked by the
// grantee itself without it), and CNPG's declarative `managed.roles.inRoles`
// has no way to request ADMIN OPTION either (only plain GRANT — see
// cloudnative-pg/cloudnative-pg#10007, an open, unshipped feature request) —
// so granting once, permanently, via this same Job (which already retries
// until each `<schema>_svc` role exists) is the only mechanism actually
// available, and it's provably safe to leave in place: Postgres membership
// is one-way, so apiaries_svc gains nothing from beekeepingit being its
// member (see TestAuditImmutability_PermanentMembershipGrantsSvcRoleNothing).
type auditImmutabilityFixture struct {
	superuser *pgx.Conn // bootstrap-only: creates roles/db, nothing else
	owner     *pgx.Conn // beekeepingit: owns the schema, not the table (until locked down)
	svc       *pgx.Conn // apiaries_svc: creates the table via its "migration", is its owner until locked down
}

const (
	auditFixtureSchema  = "apiaries"
	auditFixtureSvcRole = "apiaries_svc"
	auditFixtureOwner   = "beekeepingit"
	auditFixtureDB      = "beekeepingit_test"
)

func newAuditImmutabilityFixture(t *testing.T) *auditImmutabilityFixture {
	t.Helper()
	ctx := context.Background()

	const (
		bootstrapUser = "postgres_test"
		bootstrapPass = "postgres_test"
	)
	container, err := tcpostgres.Run(ctx, "postgres:16-alpine",
		tcpostgres.WithUsername(bootstrapUser),
		tcpostgres.WithPassword(bootstrapPass),
		tcpostgres.WithDatabase(auditFixtureDB),
		tcpostgres.BasicWaitStrategies(),
	)
	if err != nil {
		t.Fatalf("start postgres container: %v", err)
	}
	t.Cleanup(func() {
		if err := container.Terminate(ctx); err != nil {
			t.Logf("terminate postgres container: %v", err)
		}
	})

	host, err := container.Host(ctx)
	if err != nil {
		t.Fatalf("container host: %v", err)
	}
	port, err := container.MappedPort(ctx, "5432/tcp")
	if err != nil {
		t.Fatalf("container mapped port: %v", err)
	}

	connect := func(user, password string) *pgx.Conn {
		t.Helper()
		cfg := dbaccess.Config{
			Host: host, Port: port.Port(), User: user, Password: password,
			Database: auditFixtureDB, SSLMode: "disable",
		}
		conn, err := pgx.Connect(ctx, cfg.DSN())
		if err != nil {
			t.Fatalf("connect as %s: %v", user, err)
		}
		t.Cleanup(func() { _ = conn.Close(ctx) })
		return conn
	}

	su := connect(bootstrapUser, bootstrapPass)

	// The testcontainers bootstrap user (analogous to a one-time cluster-init
	// superuser, never used again below) creates the two production-shaped,
	// NON-superuser roles and hands the schema to the owner role — exactly
	// cluster.yaml's `CREATE SCHEMA ... AUTHORIZATION beekeepingit` plus
	// schema-grants-job.yaml's `GRANT USAGE, CREATE ON SCHEMA ... TO
	// apiaries_svc` + its new permanent `GRANT apiaries_svc TO beekeepingit`.
	for _, stmt := range []string{
		`CREATE ROLE ` + auditFixtureOwner + ` WITH LOGIN PASSWORD 'owner_pw'`,
		`CREATE ROLE ` + auditFixtureSvcRole + ` WITH LOGIN PASSWORD 'svc_pw'`,
		`CREATE SCHEMA ` + auditFixtureSchema + ` AUTHORIZATION ` + auditFixtureOwner,
		`GRANT USAGE, CREATE ON SCHEMA ` + auditFixtureSchema + ` TO ` + auditFixtureSvcRole,
		`GRANT ` + auditFixtureSvcRole + ` TO ` + auditFixtureOwner,
	} {
		if _, err := su.Exec(ctx, stmt); err != nil {
			t.Fatalf("bootstrap (%q): %v", stmt, err)
		}
	}

	return &auditImmutabilityFixture{
		superuser: su,
		owner:     connect(auditFixtureOwner, "owner_pw"),
		svc:       connect(auditFixtureSvcRole, "svc_pw"),
	}
}

// createAuditLogAsService creates apiaries.audit_log AS apiaries_svc — the
// same role that runs it in production, since dbaccess.Migrate opens its
// connection with the service's own runtime Config/DSN (migrate.go), making
// whichever role that Config names both the query-serving role AND the
// migration-running role. This is step zero of the vulnerability: it makes
// apiaries_svc the table's OWNER, not just a grantee.
func (f *auditImmutabilityFixture) createAuditLogAsService(t *testing.T) {
	t.Helper()
	ctx := context.Background()
	if _, err := f.svc.Exec(ctx, `CREATE TABLE `+auditFixtureSchema+`.audit_log (
		id UUID PRIMARY KEY,
		note TEXT NOT NULL
	)`); err != nil {
		t.Fatalf("create audit_log as %s: %v", auditFixtureSvcRole, err)
	}
}

func (f *auditImmutabilityFixture) tableOwner(t *testing.T, table string) string {
	t.Helper()
	var owner string
	err := f.superuser.QueryRow(context.Background(),
		`SELECT tableowner FROM pg_tables WHERE schemaname = $1 AND tablename = $2`,
		auditFixtureSchema, table).Scan(&owner)
	if err != nil {
		t.Fatalf("query owner of %s.%s: %v", auditFixtureSchema, table, err)
	}
	return owner
}

// assertServiceCan/CannotDML exercise the four DML/DDL operations that
// matter for history.md §7.1's contract: INSERT/SELECT must keep working (the
// service still needs to append and read its own history), UPDATE/DELETE
// must be rejected (the immutability guarantee), and — since a plain REVOKE
// only blocks what Postgres treats as a genuine ACL-gated operation —
// TRUNCATE must be rejected too (owners bypass TRUNCATE's ACL entirely, so
// it's the sharpest empirical witness that ownership, not just grants,
// changed).
func (f *auditImmutabilityFixture) assertServiceCanInsertAndSelect(t *testing.T, table string) {
	t.Helper()
	ctx := context.Background()
	if _, err := f.svc.Exec(ctx, `INSERT INTO `+auditFixtureSchema+`.`+table+` (id, note) VALUES (gen_random_uuid(), 'ok')`); err != nil {
		t.Fatalf("%s INSERT on %s: want success, got %v", auditFixtureSvcRole, table, err)
	}
	var n int
	if err := f.svc.QueryRow(ctx, `SELECT count(*) FROM `+auditFixtureSchema+`.`+table).Scan(&n); err != nil {
		t.Fatalf("%s SELECT on %s: want success, got %v", auditFixtureSvcRole, table, err)
	}
	if n < 1 {
		t.Fatalf("%s SELECT on %s: got %d rows, want at least 1", auditFixtureSvcRole, table, n)
	}
}

func (f *auditImmutabilityFixture) assertServiceCannotUpdateDeleteOrTruncate(t *testing.T, table string) {
	t.Helper()
	ctx := context.Background()
	if _, err := f.svc.Exec(ctx, `UPDATE `+auditFixtureSchema+`.`+table+` SET note = 'tampered'`); err == nil {
		t.Fatalf("%s UPDATE on %s: want permission error, got success — immutability NOT enforced", auditFixtureSvcRole, table)
	}
	if _, err := f.svc.Exec(ctx, `DELETE FROM `+auditFixtureSchema+`.`+table); err == nil {
		t.Fatalf("%s DELETE on %s: want permission error, got success — immutability NOT enforced", auditFixtureSvcRole, table)
	}
	if _, err := f.svc.Exec(ctx, `TRUNCATE `+auditFixtureSchema+`.`+table); err == nil {
		t.Fatalf("%s TRUNCATE on %s: want permission error, got success — table owner bypasses TRUNCATE's ACL check regardless of REVOKE, so this passing means %s is STILL the owner", auditFixtureSvcRole, table, auditFixtureSvcRole)
	}
}

// TestAuditImmutability_NaiveRevokeDoesNotDurablyBlockOwner is the
// fail-first half of the #62 proof this issue demands: it shows that
// REVOKE UPDATE, DELETE FROM apiaries_svc — the naive reading of the AC
// ("the service runtime role has INSERT/SELECT but not UPDATE/DELETE") —
// does NOT durably restrict apiaries_svc, because apiaries_svc is the
// table's OWNER (it ran the CREATE TABLE, see createAuditLogAsService). Two
// independent cracks in the naive approach, both demonstrated here:
//  1. TRUNCATE bypasses ACL/REVOKE entirely for owners — no REVOKE can ever
//     block it.
//  2. Even for UPDATE/DELETE, where the REVOKE does take initial effect,
//     the owner can trivially GRANT the privilege straight back to itself
//     at any time — nothing stops it, because ownership itself was never
//     revoked. So the restriction is not durable, only a suggestion the
//     restricted role can lift unilaterally.
//
// This is why the fix (proven in TestAuditImmutability_OwnershipTransfer_
// BlocksUpdateDeleteTruncate below) must move OWNERSHIP off apiaries_svc,
// not just revoke a couple of privileges from it.
func TestAuditImmutability_NaiveRevokeDoesNotDurablyBlockOwner(t *testing.T) {
	f := newAuditImmutabilityFixture(t)
	f.createAuditLogAsService(t)
	ctx := context.Background()

	if owner := f.tableOwner(t, "audit_log"); owner != auditFixtureSvcRole {
		t.Fatalf("audit_log owner = %q, want %q (the naive-revoke premise this test depends on)", owner, auditFixtureSvcRole)
	}

	// The naive fix: just revoke UPDATE/DELETE from the runtime role.
	if _, err := f.svc.Exec(ctx, `REVOKE UPDATE, DELETE ON `+auditFixtureSchema+`.audit_log FROM `+auditFixtureSvcRole); err != nil {
		t.Fatalf("revoke update/delete: %v", err)
	}

	// Crack 1: TRUNCATE is unaffected — owners bypass it regardless of REVOKE.
	if _, err := f.svc.Exec(ctx, `TRUNCATE `+auditFixtureSchema+`.audit_log`); err != nil {
		t.Fatalf("TRUNCATE after REVOKE: want success (proving the gap), got error %v — if Postgres now blocks owner TRUNCATE via REVOKE this test's premise is stale, re-verify", err)
	}

	// Reset for the next crack (TRUNCATE emptied the table but didn't
	// change ownership/grants).
	if _, err := f.svc.Exec(ctx, `INSERT INTO `+auditFixtureSchema+`.audit_log (id, note) VALUES (gen_random_uuid(), 'ok')`); err != nil {
		t.Fatalf("re-seed row: %v", err)
	}

	// Crack 2: the owner can just grant itself the "revoked" privilege back.
	if _, err := f.svc.Exec(ctx, `GRANT UPDATE, DELETE ON `+auditFixtureSchema+`.audit_log TO `+auditFixtureSvcRole); err != nil {
		t.Fatalf("self-regrant update/delete: %v", err)
	}
	if _, err := f.svc.Exec(ctx, `UPDATE `+auditFixtureSchema+`.audit_log SET note = 'tampered'`); err != nil {
		t.Fatalf("UPDATE after self-regrant: want success (proving the gap), got error %v", err)
	}
}

// lockDownHistoryTable performs, from Go, the EXACT same two SQL steps
// infra/helm/beekeepingit/charts/postgres/templates/audit-immutability-job.yaml
// runs in production (as the `beekeepingit` app-owner connection, which
// already has permanent plain membership in svcRole by the time this runs —
// see newAuditImmutabilityFixture and schema-grants-job.yaml) — kept
// byte-for-byte equivalent deliberately, so this test is a real proof of what
// ships, not just of "a" fix. If that Job's SQL ever changes, this helper
// must change with it (and vice versa).
func lockDownHistoryTable(t *testing.T, owner *pgx.Conn, schema, svcRole, table string) {
	t.Helper()
	ctx := context.Background()

	// beekeepingit already inherits svc_role's privileges (incl. ownership)
	// via the permanent membership granted in fixture setup, so it can move
	// ownership off the runtime role directly, then grant back only
	// INSERT/SELECT.
	if _, err := owner.Exec(ctx, `ALTER TABLE `+schema+`.`+table+` OWNER TO `+auditFixtureOwner); err != nil {
		t.Fatalf("ALTER TABLE %s.%s OWNER TO %s: %v", schema, table, auditFixtureOwner, err)
	}
	if _, err := owner.Exec(ctx, `GRANT INSERT, SELECT ON `+schema+`.`+table+` TO `+svcRole); err != nil {
		t.Fatalf("GRANT INSERT, SELECT ON %s.%s TO %s: %v", schema, table, svcRole, err)
	}
}

// TestAuditImmutability_OwnershipTransferBlocksUpdateDeleteTruncate is the
// pass half of the #62 proof: after lockDownHistoryTable runs (the real
// fix), apiaries_svc can still INSERT/SELECT (the AC's other half) but can
// no longer UPDATE/DELETE/TRUNCATE apiaries.audit_log — including the two
// specific cracks the naive-revoke test above demonstrated. It also proves
// apiaries_svc can't just self-GRANT its way back in, since — unlike the
// naive-revoke case — it no longer owns the table AND was never granted
// membership in beekeepingit (only the reverse direction is ever granted,
// permanently, to the owner role — see newAuditImmutabilityFixture).
func TestAuditImmutability_OwnershipTransferBlocksUpdateDeleteTruncate(t *testing.T) {
	f := newAuditImmutabilityFixture(t)
	f.createAuditLogAsService(t)
	ctx := context.Background()

	if owner := f.tableOwner(t, "audit_log"); owner != auditFixtureSvcRole {
		t.Fatalf("audit_log owner = %q, want %q before lock-down", owner, auditFixtureSvcRole)
	}

	lockDownHistoryTable(t, f.owner, auditFixtureSchema, auditFixtureSvcRole, "audit_log")

	if owner := f.tableOwner(t, "audit_log"); owner != auditFixtureOwner {
		t.Fatalf("audit_log owner after lock-down = %q, want %q", owner, auditFixtureOwner)
	}

	// AC's positive half: INSERT/SELECT still work.
	f.assertServiceCanInsertAndSelect(t, "audit_log")

	// AC's negative half, incl. both cracks the naive-revoke test found.
	f.assertServiceCannotUpdateDeleteOrTruncate(t, "audit_log")

	// The self-regrant crack specifically: apiaries_svc no longer owns the
	// table and was never made a member of beekeepingit, so this must be a
	// no-op (Postgres silently grants nothing rather than erroring — the
	// real assertion is the subsequent UPDATE still failing).
	if _, err := f.svc.Exec(ctx, `GRANT UPDATE, DELETE ON `+auditFixtureSchema+`.audit_log TO `+auditFixtureSvcRole); err != nil {
		t.Fatalf("self-grant attempt itself errored (want silent no-op): %v", err)
	}
	if _, err := f.svc.Exec(ctx, `UPDATE `+auditFixtureSchema+`.audit_log SET note = 'tampered'`); err == nil {
		t.Fatalf("UPDATE after apiaries_svc's own self-GRANT attempt: want still-rejected, got success — self-regrant crack NOT closed")
	}

	// Purge/anonymization stays reachable via the (still usable, non-revoked)
	// owner role — history.md §7.2/§7.1 "a separate, privileged maintenance
	// role, not the service role". beekeepingit can still UPDATE/DELETE.
	if _, err := f.owner.Exec(ctx, `DELETE FROM `+auditFixtureSchema+`.audit_log WHERE false`); err != nil {
		t.Fatalf("beekeepingit (the new owner, standing in for a future privileged purge role) DELETE: want success, got %v", err)
	}
}

// TestAuditImmutability_SyncConflictLogGetsTheSameTreatment proves the fix
// isn't audit_log-specific: apiaries.sync_conflict_log (history.md §6's
// conflict-specific sibling of audit_log, same per-service/in-tx placement)
// needs and gets the identical lock-down.
func TestAuditImmutability_SyncConflictLogGetsTheSameTreatment(t *testing.T) {
	f := newAuditImmutabilityFixture(t)
	ctx := context.Background()
	if _, err := f.svc.Exec(ctx, `CREATE TABLE `+auditFixtureSchema+`.sync_conflict_log (
		id UUID PRIMARY KEY,
		note TEXT NOT NULL
	)`); err != nil {
		t.Fatalf("create sync_conflict_log as %s: %v", auditFixtureSvcRole, err)
	}

	lockDownHistoryTable(t, f.owner, auditFixtureSchema, auditFixtureSvcRole, "sync_conflict_log")

	if owner := f.tableOwner(t, "sync_conflict_log"); owner != auditFixtureOwner {
		t.Fatalf("sync_conflict_log owner after lock-down = %q, want %q", owner, auditFixtureOwner)
	}
	f.assertServiceCanInsertAndSelect(t, "sync_conflict_log")
	f.assertServiceCannotUpdateDeleteOrTruncate(t, "sync_conflict_log")
}

// TestAuditImmutability_PermanentMembershipGrantsSvcRoleNothing proves the
// piece the ownership-transfer fix now depends on being safe to leave in
// place forever (schema-grants-job.yaml's permanent `GRANT apiaries_svc TO
// beekeepingit`, set up by every fixture in this file): apiaries_svc gains
// NOTHING from beekeepingit being its member, because Postgres role
// membership is strictly one-directional. Even with that membership active
// and no table ever locked down, apiaries_svc still can't touch a table it
// doesn't own via that channel — this isolates the membership grant itself
// (as opposed to the ownership-transfer test above, which exercises it
// combined with the ALTER/GRANT).
func TestAuditImmutability_PermanentMembershipGrantsSvcRoleNothing(t *testing.T) {
	f := newAuditImmutabilityFixture(t)
	ctx := context.Background()

	// A table beekeepingit owns directly (never touched by apiaries_svc at
	// all) — if the membership direction were somehow reversed or leaking,
	// apiaries_svc would gain access to THIS table too, which it must not.
	if _, err := f.owner.Exec(ctx, `CREATE TABLE `+auditFixtureSchema+`.owner_only (id UUID PRIMARY KEY, note TEXT NOT NULL)`); err != nil {
		t.Fatalf("create owner_only as %s: %v", auditFixtureOwner, err)
	}
	if _, err := f.svc.Exec(ctx, `SELECT count(*) FROM `+auditFixtureSchema+`.owner_only`); err == nil {
		t.Fatalf("%s SELECT on a table it was never granted anything on: want permission error, got success — membership direction is leaking", auditFixtureSvcRole)
	}
	if _, err := f.svc.Exec(ctx, `INSERT INTO `+auditFixtureSchema+`.owner_only (id, note) VALUES (gen_random_uuid(), 'x')`); err == nil {
		t.Fatalf("%s INSERT on a table it was never granted anything on: want permission error, got success — membership direction is leaking", auditFixtureSvcRole)
	}
}

// TestAuditImmutability_LockDownIsIdempotent proves lockDownHistoryTable (and
// so the Helm Job it mirrors) is safe to re-run on every helm upgrade
// (post-install,post-upgrade, ADR-0009's GitOps cadence) without erroring
// once a table is already locked down — the Job's "already owned by
// beekeepingit, nothing to do" skip path depends on this being safe to call
// twice; here we call the underlying ALTER/GRANT sequence twice directly to
// prove the sequence itself tolerates re-application (the Job's shell wraps
// it with an owner check first, which is the actual skip mechanism, but the
// SQL sequence itself must also not corrupt state if ever invoked again,
// e.g. a future manual re-run).
func TestAuditImmutability_LockDownIsIdempotent(t *testing.T) {
	f := newAuditImmutabilityFixture(t)
	f.createAuditLogAsService(t)

	lockDownHistoryTable(t, f.owner, auditFixtureSchema, auditFixtureSvcRole, "audit_log")
	lockDownHistoryTable(t, f.owner, auditFixtureSchema, auditFixtureSvcRole, "audit_log")

	if owner := f.tableOwner(t, "audit_log"); owner != auditFixtureOwner {
		t.Fatalf("audit_log owner after repeated lock-down = %q, want %q", owner, auditFixtureOwner)
	}
	f.assertServiceCanInsertAndSelect(t, "audit_log")
	f.assertServiceCannotUpdateDeleteOrTruncate(t, "audit_log")
}
