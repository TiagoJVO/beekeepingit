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
// per service".
//
// superuser is the testcontainers bootstrap role, and it now stands in
// SPECIFICALLY for CNPG's own operator reconciliation connection (not just
// generic cluster bring-up) — this is the fix for a real production bug an
// earlier version of this fixture masked: `beekeepingit`'s membership in
// each `<schema>_svc` role (needed so it can later `ALTER TABLE ... OWNER
// TO beekeepingit`) can ONLY be granted by a role with CREATEROLE + ADMIN
// OPTION on the target role — `beekeepingit` itself (a plain login role)
// has neither, so a manual `GRANT apiaries_svc TO beekeepingit` run BY
// beekeepingit fails with a permission error. This was shipped once (a
// Job running `psql` as `beekeepingit` in a retry loop) and only caught by
// CI's live k3d/helm-e2e run — the `until ... done` retry loop couldn't
// distinguish "role not ready yet" from "permanently denied", so it spun
// until `activeDeadlineSeconds` killed it (helm-e2e run 29146587211). The
// EARLIER version of this fixture bootstrapped that membership using `su`
// too, but framed as "any cluster-init superuser, incidental" — which
// missed that granting ROLE MEMBERSHIP specifically requires privileges
// `beekeepingit` doesn't have, so the test never exercised (and couldn't
// have caught) the broken "beekeepingit grants itself membership" path. The
// production fix moves this into cluster.yaml's declarative
// `spec.managed.roles` (a `beekeepingit` entry with `inRoles`), which CNPG's
// own operator reconciles using ITS privileged connection — never
// `beekeepingit`'s own. TestAuditImmutability_SvcRoleGrantingSelfMembership
// ToOwnerFails below proves the broken path fails; superuser standing in for
// CNPG's operator in this fixture is what makes the rest of this file
// consistent with how production now actually establishes that membership.
type auditImmutabilityFixture struct {
	superuser *pgx.Conn // bootstrap-only: stands in for CNPG's own privileged reconciliation connection — creates roles/db AND grants the beekeepingit/svc-role membership (mirrors managed.roles.inRoles, never a manual GRANT run by beekeepingit itself)
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

	// The testcontainers bootstrap user (standing in for CNPG's own
	// privileged operator connection, NOT a generic one-off cluster-init
	// step — see the type comment above) creates the two production-shaped,
	// NON-superuser roles and hands the schema to the owner role — exactly
	// cluster.yaml's `CREATE SCHEMA ... AUTHORIZATION beekeepingit` plus
	// schema-grants-job.yaml's `GRANT USAGE, CREATE ON SCHEMA ... TO
	// apiaries_svc`. It does NOT yet grant beekeepingit membership in
	// apiaries_svc — callers that need that (i.e. everything except
	// TestAuditImmutability_SvcRoleGrantingSelfMembershipToOwnerFails) call
	// grantOwnerMembershipInSvcRoleAsIfByCNPGOperator below, which performs
	// the SAME grant using su (privileged) rather than the owner role
	// itself, matching how cluster.yaml's `managed.roles` entry for
	// `beekeepingit` now actually gets this membership in production —
	// never a manual GRANT run by beekeepingit's own connection.
	for _, stmt := range []string{
		`CREATE ROLE ` + auditFixtureOwner + ` WITH LOGIN PASSWORD 'owner_pw'`,
		`CREATE ROLE ` + auditFixtureSvcRole + ` WITH LOGIN PASSWORD 'svc_pw'`,
		`CREATE SCHEMA ` + auditFixtureSchema + ` AUTHORIZATION ` + auditFixtureOwner,
		`GRANT USAGE, CREATE ON SCHEMA ` + auditFixtureSchema + ` TO ` + auditFixtureSvcRole,
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

// grantOwnerMembershipInSvcRoleAsIfByCNPGOperator grants beekeepingit
// permanent, plain membership in apiaries_svc THE WAY PRODUCTION ACTUALLY
// DOES IT: via a privileged connection (here, the testcontainers bootstrap
// role standing in for CNPG's own operator reconciliation — see
// cluster.yaml's `managed.roles` entry for `beekeepingit`, with `inRoles`),
// never via beekeepingit's own connection. Postgres requires CREATEROLE +
// ADMIN OPTION on the target role to grant its membership — beekeepingit
// (a plain login role) has neither, so this step CANNOT be performed by
// f.owner; see TestAuditImmutability_SvcRoleGrantingSelfMembershipToOwner
// Fails for the proof.
func (f *auditImmutabilityFixture) grantOwnerMembershipInSvcRoleAsIfByCNPGOperator(t *testing.T) {
	t.Helper()
	if _, err := f.superuser.Exec(context.Background(), `GRANT `+auditFixtureSvcRole+` TO `+auditFixtureOwner); err != nil {
		t.Fatalf("GRANT %s TO %s (as the privileged/CNPG-operator-equivalent connection): %v", auditFixtureSvcRole, auditFixtureOwner, err)
	}
}

// TestAuditImmutability_SvcRoleGrantingSelfMembershipToOwnerFails is the
// regression test for a real production bug this PR shipped once already:
// an earlier version of audit-immutability-job.yaml/schema-grants-job.yaml
// tried to establish beekeepingit's membership in apiaries_svc with `GRANT
// apiaries_svc TO beekeepingit` run FROM beekeepingit's OWN connection (the
// `-app` Secret credential, exactly f.owner here). That shipped, passed this
// file's OTHER tests (because they all bootstrapped the membership via a
// superuser and never exercised HOW beekeepingit itself would try to get it),
// and only failed in CI's live k3d/helm-e2e run: the schema-grants Job's
// `until psql ... ; do sleep 5; done` retry loop can't distinguish "role not
// ready yet" from "permanently denied", so `helm upgrade --install` spun
// until `activeDeadlineSeconds: 300` killed it with DeadlineExceeded
// (github.com/TiagoJVO/beekeepingit/actions/runs/29146587211).
//
// This test proves WHY that failed, directly: Postgres requires CREATEROLE
// + ADMIN OPTION on apiaries_svc to grant its membership to anyone, and
// beekeepingit (a plain login role — LOGIN only, per cluster.yaml's
// `managed.roles` entry) has neither. The fix moves this grant to a
// connection that DOES have the necessary privileges — CNPG's own operator
// reconciliation, via cluster.yaml's declarative `managed.roles` `inRoles`
// field (see grantOwnerMembershipInSvcRoleAsIfByCNPGOperator, which mirrors
// that by using f.superuser instead of f.owner).
func TestAuditImmutability_SvcRoleGrantingSelfMembershipToOwnerFails(t *testing.T) {
	f := newAuditImmutabilityFixture(t)

	_, err := f.owner.Exec(context.Background(), `GRANT `+auditFixtureSvcRole+` TO `+auditFixtureOwner)
	if err == nil {
		t.Fatalf("GRANT %s TO %s run BY %s itself: want a permission error (beekeepingit lacks CREATEROLE/ADMIN OPTION on %s), got success — if Postgres now allows this, the whole reason cluster.yaml routes this through CNPG's managed.roles instead of a manual GRANT is stale, re-verify",
			auditFixtureSvcRole, auditFixtureOwner, auditFixtureOwner, auditFixtureSvcRole)
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
	f.grantOwnerMembershipInSvcRoleAsIfByCNPGOperator(t)
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
	f.grantOwnerMembershipInSvcRoleAsIfByCNPGOperator(t)
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
	f.grantOwnerMembershipInSvcRoleAsIfByCNPGOperator(t)
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
	f.grantOwnerMembershipInSvcRoleAsIfByCNPGOperator(t)

	lockDownHistoryTable(t, f.owner, auditFixtureSchema, auditFixtureSvcRole, "audit_log")
	lockDownHistoryTable(t, f.owner, auditFixtureSchema, auditFixtureSvcRole, "audit_log")

	if owner := f.tableOwner(t, "audit_log"); owner != auditFixtureOwner {
		t.Fatalf("audit_log owner after repeated lock-down = %q, want %q", owner, auditFixtureOwner)
	}
	f.assertServiceCanInsertAndSelect(t, "audit_log")
	f.assertServiceCannotUpdateDeleteOrTruncate(t, "audit_log")
}
