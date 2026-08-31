package dbaccess_test

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

// Coverage for the ONE part of #545 that no other test layer can reach: the
// in-place transition of an already-deployed cluster, performed by
// infra/helm/beekeepingit/charts/postgres/templates/migrator-adopt-job.yaml.
//
// WHY IT HAS TO BE HERE. helm-e2e (.github/workflows/helm-e2e.yml) installs a
// fresh k3d cluster on every run, and a fresh install has nothing to adopt —
// the migrate Job creates every table AS `<schema>_migrator` from the first
// release, so the adopt Job is a seven-way no-op there. The transition only
// exists on a cluster that previously deployed #541, which is a state CI
// structurally cannot produce. That is the same blind spot ADR-0023 records
// for #541's own bug ("on a fresh cluster every migration runs before the
// lockdown has ever applied... an ordering that no fresh-install test can
// produce"), and it is why the transition is reproduced here instead.
//
// Everything below therefore starts from the REAL #541 end state — beekeepingit
// owning every relation, `<schema>_svc` holding grants issued BY beekeepingit,
// history tables already revoked, and `pg_default_acl` rows scoped to
// beekeepingit — and then runs the adopt transaction against it.

const (
	transitionSchema   = auditFixtureSchema // "apiaries", shared with the other fixtures
	transitionOwner    = "beekeepingit"
	transitionSvcRole  = auditFixtureSchema + "_svc"
	transitionMigrator = auditFixtureSchema + "_migrator"
)

type migratorTransitionFixture struct {
	superuser *pgx.Conn // stands in for CNPG's own privileged reconciliation connection
	owner     *pgx.Conn // beekeepingit — the principal the adopt Job authenticates as
	svc       *pgx.Conn // apiaries_svc — the live traffic served throughout the transition
	migrator  *pgx.Conn // apiaries_migrator — owns everything once adopt has run

	ownerDSN    string // search_path=apiaries, for driving the real dbaccess.Migrate
	migratorDSN string
}

// newMigratorTransitionFixture builds the pre-#545 (i.e. post-#541) state a
// staging-like cluster is actually in when the transition release lands.
func newMigratorTransitionFixture(t *testing.T) *migratorTransitionFixture {
	t.Helper()
	ctx := context.Background()

	configFor := startIsolationPostgres(t)
	connect := func(user, password string) *pgx.Conn {
		t.Helper()
		conn, err := pgx.Connect(ctx, configFor(user, password, "").DSN())
		if err != nil {
			t.Fatalf("connect as %s: %v", user, err)
		}
		t.Cleanup(func() { _ = conn.Close(ctx) })
		return conn
	}

	su := connect(isoBootstrapUser, isoBootstrapPass)
	exec := func(conn *pgx.Conn, what, stmt string) {
		t.Helper()
		if _, err := conn.Exec(ctx, stmt); err != nil {
			t.Fatalf("%s (%q): %v", what, stmt, err)
		}
	}

	for _, stmt := range []string{
		fmt.Sprintf(`CREATE ROLE %s WITH LOGIN PASSWORD '%s'`, transitionOwner, isoRolePassword),
		fmt.Sprintf(`CREATE ROLE %s WITH LOGIN PASSWORD '%s'`, transitionSvcRole, isoRolePassword),
		// The migrator role is NEW in the transition release. It exists from
		// the moment CNPG reconciles the updated managed.roles, before any
		// hook runs.
		fmt.Sprintf(`CREATE ROLE %s WITH LOGIN PASSWORD '%s'`, transitionMigrator, isoRolePassword),
		fmt.Sprintf(`CREATE SCHEMA %s AUTHORIZATION %s`, transitionSchema, transitionOwner),
		// #541's membership: beekeepingit in <schema>_svc, granted by CNPG's
		// operator connection (never by beekeepingit itself — see
		// TestAuditImmutability_SvcRoleGrantingSelfMembershipToOwnerFails).
		fmt.Sprintf(`GRANT %s TO %s`, transitionSvcRole, transitionOwner),
	} {
		exec(su, "pre-#545 bootstrap", stmt)
	}

	f := &migratorTransitionFixture{
		superuser:   su,
		owner:       connect(transitionOwner, isoRolePassword),
		svc:         connect(transitionSvcRole, isoRolePassword),
		migrator:    connect(transitionMigrator, isoRolePassword),
		ownerDSN:    configFor(transitionOwner, isoRolePassword, transitionSchema).DSN(),
		migratorDSN: configFor(transitionMigrator, isoRolePassword, transitionSchema).DSN(),
	}

	// schema-grants-job.yaml as it renders in the TRANSITION release (hook
	// weight 0, so this has already run when adopt fires at weight 1). The
	// migrator's CREATE on the schema is not cosmetic: `ALTER ... OWNER TO`
	// requires the NEW owner to hold CREATE on the containing schema, so
	// without this the adopt transaction fails outright.
	for _, stmt := range []string{
		fmt.Sprintf(`GRANT USAGE, CREATE ON SCHEMA %s TO %s`, transitionSchema, transitionMigrator),
		fmt.Sprintf(`GRANT USAGE ON SCHEMA %s TO %s`, transitionSchema, transitionSvcRole),
		fmt.Sprintf(`REVOKE CREATE ON SCHEMA %s FROM %s`, transitionSchema, transitionSvcRole),
	} {
		exec(f.owner, "schema-grants (weight 0)", stmt)
	}

	// #541's migrate Job: migrations run as beekeepingit, so it owns
	// apiaries.audit_log AND apiaries.goose_db_version. Driven through the
	// REAL dbaccess.Migrate rather than hand-written DDL, so the goose ledger
	// is genuinely goose's, with goose's own column shape and `serial`
	// sequence — the thing the adopt loop's relkind handling has to move.
	if err := dbaccess.Migrate(ctx, f.ownerDSN, onlyFirstMigration(t)); err != nil {
		t.Fatalf("pre-#545 migration as %s: %v", transitionOwner, err)
	}

	// The rest of the schema, also owned by beekeepingit. Deliberately more
	// than just tables: a view and a standalone sequence exercise the adopt
	// loop's `relkind` branches ('v' and 'S') that the real schemas do not
	// happen to contain today, so the CASE arm for each is executed here
	// rather than being dead code nobody has ever run.
	for _, stmt := range []string{
		`CREATE TABLE %s.things (id UUID PRIMARY KEY, note TEXT NOT NULL)`,
		`CREATE TABLE %s.sync_conflict_log (id UUID PRIMARY KEY, note TEXT NOT NULL)`,
		`CREATE SEQUENCE %s.thing_counter`,
		`CREATE VIEW %s.things_v AS SELECT id, note FROM %[1]s.things`,
		`INSERT INTO %s.audit_log (id, note) VALUES (gen_random_uuid(), 'seed')`,
		`INSERT INTO %s.sync_conflict_log (id, note) VALUES (gen_random_uuid(), 'seed')`,
		`INSERT INTO %s.things (id, note) VALUES (gen_random_uuid(), 'seed')`,
	} {
		exec(f.owner, "pre-#545 schema", fmt.Sprintf(stmt, transitionSchema))
	}

	// #541's table-grants-job.yaml, run as beekeepingit — which is what makes
	// beekeepingit the GRANTOR recorded in every one of these ACL entries, the
	// detail non-negotiable #4 of the adopt Job's header is about.
	for _, stmt := range []string{
		`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %s TO ` + transitionSvcRole,
		`GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %s TO ` + transitionSvcRole,
		// The pre-#545 default: FULL DML, scoped to beekeepingit. Both halves
		// are what the transition has to undo — the width, and the fact that
		// only beekeepingit can ever revoke it.
		`ALTER DEFAULT PRIVILEGES FOR ROLE ` + transitionOwner + ` IN SCHEMA %s GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ` + transitionSvcRole,
		`ALTER DEFAULT PRIVILEGES FOR ROLE ` + transitionOwner + ` IN SCHEMA %s GRANT USAGE, SELECT ON SEQUENCES TO ` + transitionSvcRole,
		`REVOKE UPDATE, DELETE, TRUNCATE ON %s.audit_log FROM ` + transitionSvcRole,
		`REVOKE UPDATE, DELETE, TRUNCATE ON %s.sync_conflict_log FROM ` + transitionSvcRole,
	} {
		exec(f.owner, "pre-#545 table-grants", fmt.Sprintf(stmt, transitionSchema))
	}

	return f
}

// enableMigratorTransitionAsIfByCNPGOperator performs the membership half of
// flipping `postgres.migratorTransition.enabled` on: cluster.yaml replaces
// beekeepingit's `inRoles` list, and CNPG's reconciler both GRANTs the new
// entries and REVOKEs the dropped ones (verified against its role reconciler,
// which diffs the declared list against pg_auth_members).
//
// It uses the privileged connection, never f.owner, for the same reason every
// other fixture in this package does: Postgres requires CREATEROLE + ADMIN
// OPTION on the target role to grant its membership, and beekeepingit — a
// plain login role — has neither.
func (f *migratorTransitionFixture) enableMigratorTransitionAsIfByCNPGOperator(t *testing.T) {
	t.Helper()
	ctx := context.Background()
	for _, stmt := range []string{
		fmt.Sprintf(`GRANT %s TO %s`, transitionMigrator, transitionOwner),
		fmt.Sprintf(`REVOKE %s FROM %s`, transitionSvcRole, transitionOwner),
	} {
		if _, err := f.superuser.Exec(ctx, stmt); err != nil {
			t.Fatalf("CNPG-operator-equivalent reconcile (%q): %v", stmt, err)
		}
	}
}

// adoptStatements mirrors the transaction in
// charts/postgres/templates/migrator-adopt-job.yaml, statement for statement
// and in the same order.
//
// It is a MIRROR, not the literal rendered script: that template emits
// Helm-rendered `psql -c` arguments wrapped in a shell script, and executing it
// verbatim would need helm plus a shell inside the test container — an approach
// this package already tried and abandoned once (see the closing NOTE in
// audit_immutability_test.go, where driving a rendered Job script through
// Container.Exec hung unreliably). The statements below must be kept in step
// with that file by hand; the ORDER is the part that carries the meaning, so
// each grouping is annotated with which non-negotiable it implements.
func adoptStatements(schema string) []string {
	ownershipLoop := fmt.Sprintf(`DO $do$
DECLARE
  target_schema CONSTANT text    := '%[1]s';
  target_role   CONSTANT text    := '%[1]s_migrator';
  target_owner  CONSTANT regrole := '%[1]s_migrator'::regrole;
  unhandled text;
  r record;
  moved int := 0;
BEGIN
  SELECT string_agg(p.proname, ', ' ORDER BY p.proname) INTO unhandled
    FROM pg_proc p
   WHERE p.pronamespace = target_schema::regnamespace;
  IF unhandled IS NOT NULL THEN
    RAISE EXCEPTION '%%: holds routine(s) this transition cannot move: %%.', target_schema, unhandled;
  END IF;

  SELECT string_agg(t.typname, ', ' ORDER BY t.typname) INTO unhandled
    FROM pg_type t
   WHERE t.typnamespace = target_schema::regnamespace
     AND (t.typrelid = 0
          OR (SELECT c.relkind FROM pg_class c WHERE c.oid = t.typrelid) = 'c')
     AND NOT EXISTS (SELECT 1 FROM pg_type el WHERE el.oid = t.typelem AND el.typarray = t.oid);
  IF unhandled IS NOT NULL THEN
    RAISE EXCEPTION '%%: holds standalone type(s) this transition cannot move: %%.', target_schema, unhandled;
  END IF;

  SELECT string_agg(c.oid::regclass::text || ' (owned by ' || c.relowner::regrole::text || ')',
                    ', ' ORDER BY c.oid::regclass::text) INTO unhandled
    FROM pg_class c
   WHERE c.relnamespace = target_schema::regnamespace
     AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
     AND c.relowner <> target_owner
     AND NOT pg_has_role(current_user, c.relowner, 'USAGE');
  IF unhandled IS NOT NULL THEN
    RAISE EXCEPTION '%%: relation(s) owned by a role this Job cannot act for: %%. This cluster predates #541.', target_schema, unhandled;
  END IF;

  FOR r IN
    SELECT c.oid, c.relkind, c.oid::regclass AS ident
      FROM pg_class c
     WHERE c.relnamespace = target_schema::regnamespace
       AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
       AND c.relowner <> target_owner
     ORDER BY CASE c.relkind
                WHEN 'r' THEN 1 WHEN 'p' THEN 1 WHEN 'f' THEN 2
                WHEN 'S' THEN 3 WHEN 'v' THEN 4 ELSE 5
              END
  LOOP
    CONTINUE WHEN (SELECT c.relowner FROM pg_class c WHERE c.oid = r.oid) = target_owner;
    EXECUTE format('ALTER %%s %%s OWNER TO %%I',
                   CASE r.relkind
                     WHEN 'r' THEN 'TABLE'
                     WHEN 'p' THEN 'TABLE'
                     WHEN 'f' THEN 'FOREIGN TABLE'
                     WHEN 'S' THEN 'SEQUENCE'
                     WHEN 'v' THEN 'VIEW'
                     WHEN 'm' THEN 'MATERIALIZED VIEW'
                   END,
                   r.ident, target_role);
    moved := moved + 1;
  END LOOP;
  RAISE NOTICE '%%: moved %% relation(s) to %%', target_schema, moved, target_role;
END
$do$`, schema)

	return []string{
		// Non-negotiables 1 + 2: a per-relation loop scoped by relnamespace,
		// guarded against the object kinds it cannot move.
		ownershipLoop,
		// Non-negotiable 4, first half — as beekeepingit, because only
		// beekeepingit can revoke its own pg_default_acl rows and its own
		// grants, and because a revoke issued by the new owner cannot be
		// relied on to match grants recorded against a different grantor.
		fmt.Sprintf(`ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA %s REVOKE ALL ON TABLES FROM %s_svc`, transitionOwner, schema, schema),
		fmt.Sprintf(`ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA %s REVOKE ALL ON SEQUENCES FROM %s_svc`, transitionOwner, schema, schema),
		fmt.Sprintf(`REVOKE ALL ON ALL TABLES IN SCHEMA %s FROM %s_svc`, schema, schema),
		fmt.Sprintf(`REVOKE ALL ON ALL SEQUENCES IN SCHEMA %s FROM %s_svc`, schema, schema),
		// Non-negotiable 4, second half — everything after this point is the
		// new owner speaking.
		fmt.Sprintf(`SET LOCAL ROLE %s_migrator`, schema),
		// The shared steady-state ACL (_helpers.tpl's
		// postgres.runtimeGrantsPsqlArgs), identical to what table-grants-job
		// applies at weight 3.
		fmt.Sprintf(`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %s TO %s_svc`, schema, schema),
		fmt.Sprintf(`GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %s TO %s_svc`, schema, schema),
		fmt.Sprintf(`ALTER DEFAULT PRIVILEGES FOR ROLE %s_migrator IN SCHEMA %s GRANT SELECT, INSERT ON TABLES TO %s_svc`, schema, schema, schema),
		fmt.Sprintf(`ALTER DEFAULT PRIVILEGES FOR ROLE %s_migrator IN SCHEMA %s GRANT USAGE, SELECT ON SEQUENCES TO %s_svc`, schema, schema, schema),
		fmt.Sprintf(`REVOKE UPDATE, DELETE, TRUNCATE ON %s.audit_log FROM %s_svc`, schema, schema),
		fmt.Sprintf(`REVOKE UPDATE, DELETE, TRUNCATE ON %s.sync_conflict_log FROM %s_svc`, schema, schema),
		fmt.Sprintf(`REVOKE ALL ON %s.goose_db_version FROM %s_svc`, schema, schema),
	}
}

// runAdopt executes the adopt statements as beekeepingit, in ONE transaction —
// non-negotiable 3. The atomicity is not an implementation detail of this
// helper: TestMigratorTransition_IsAtomic depends on it, and so does the
// production guarantee that no serving session ever observes the ACL midway
// through.
func (f *migratorTransitionFixture) runAdopt(t *testing.T) error {
	t.Helper()
	ctx := context.Background()

	tx, err := f.owner.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin adopt transaction: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	for _, stmt := range adoptStatements(transitionSchema) {
		if _, err := tx.Exec(ctx, stmt); err != nil {
			return fmt.Errorf("adopt statement failed: %w", err)
		}
	}
	return tx.Commit(ctx)
}

func (f *migratorTransitionFixture) mustRunAdopt(t *testing.T) {
	t.Helper()
	if err := f.runAdopt(t); err != nil {
		t.Fatalf("adopt transaction: want success, got %v", err)
	}
}

// relationOwners returns every relation in the schema with its owner, so a
// test can assert about ALL of them rather than the two or three it remembered
// to name. A relation the transition silently skipped is exactly the failure
// mode worth catching.
func (f *migratorTransitionFixture) relationOwners(t *testing.T) map[string]string {
	t.Helper()
	rows, err := f.superuser.Query(context.Background(), `
		SELECT c.relname, pg_get_userbyid(c.relowner)
		  FROM pg_class c
		 WHERE c.relnamespace = $1::regnamespace
		   AND c.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')`, transitionSchema)
	if err != nil {
		t.Fatalf("query relation owners: %v", err)
	}
	defer rows.Close()

	owners := map[string]string{}
	for rows.Next() {
		var name, owner string
		if err := rows.Scan(&name, &owner); err != nil {
			t.Fatalf("scan relation owner: %v", err)
		}
		owners[name] = owner
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate relation owners: %v", err)
	}
	if len(owners) == 0 {
		t.Fatal("no relations found in the fixture schema — the fixture is broken and every ownership assertion is vacuous")
	}
	return owners
}

func (f *migratorTransitionFixture) beekeepingitDefaultACLRows(t *testing.T) int {
	t.Helper()
	var n int
	if err := f.superuser.QueryRow(context.Background(),
		`SELECT count(*) FROM pg_default_acl WHERE defaclrole = $1::regrole`, transitionOwner).Scan(&n); err != nil {
		t.Fatalf("count beekeepingit-scoped default ACL rows: %v", err)
	}
	return n
}

// TestMigratorTransition_AdoptMovesOwnershipAndKeepsTheServiceServing is the
// transition's main proof, and it checks both halves of what "no downtime"
// has to mean here.
//
// Ownership must move completely — every relation, including goose's ledger
// and its `serial` sequence, the view and the standalone sequence — because a
// single relation left behind means the next migration that touches it fails
// with `must be owner`, which is #541's bug in a new costume.
//
// And the runtime ACL must come out the other side unchanged in effect: the
// outgoing ReplicaSet is serving live `<schema>_svc` traffic throughout (Helm
// applies Deployments before hooks and this chart installs without `--wait`),
// so a transition that "succeeds" while leaving the service unable to write is
// an outage, and one that leaves the audit log mutable is a silent regression
// of the guarantee history.md §7.1 exists for.
func TestMigratorTransition_AdoptMovesOwnershipAndKeepsTheServiceServing(t *testing.T) {
	f := newMigratorTransitionFixture(t)
	ctx := context.Background()

	before := f.relationOwners(t)
	for name, owner := range before {
		if owner != transitionOwner {
			t.Fatalf("pre-state: %s.%s owned by %q, want %q — the fixture is not reproducing the #541 end state this transition adopts",
				transitionSchema, name, owner, transitionOwner)
		}
	}
	if got := f.beekeepingitDefaultACLRows(t); got == 0 {
		t.Fatal("pre-state: no beekeepingit-scoped pg_default_acl rows — the fixture is not reproducing #541's ALTER DEFAULT PRIVILEGES, so the cleanup assertion below would be vacuous")
	}

	f.enableMigratorTransitionAsIfByCNPGOperator(t)
	f.mustRunAdopt(t)

	for name, owner := range f.relationOwners(t) {
		if owner != transitionMigrator {
			t.Fatalf("%s.%s still owned by %q after adopt, want %q — a relation the ownership loop did not move is a `must be owner of table` failure waiting for the next migration",
				transitionSchema, name, owner, transitionMigrator)
		}
	}

	// The service keeps serving: append and read its own history.
	if _, err := f.svc.Exec(ctx, `INSERT INTO `+transitionSchema+`.audit_log (id, note) VALUES (gen_random_uuid(), 'still writing')`); err != nil {
		t.Fatalf("%s INSERT on audit_log after adopt: want success (this is live traffic), got %v", transitionSvcRole, err)
	}
	if _, err := f.svc.Exec(ctx, `SELECT count(*) FROM `+transitionSchema+`.audit_log`); err != nil {
		t.Fatalf("%s SELECT on audit_log after adopt: want success, got %v", transitionSvcRole, err)
	}
	// ...and full DML on its domain tables.
	for _, stmt := range []string{
		`INSERT INTO ` + transitionSchema + `.things (id, note) VALUES (gen_random_uuid(), 'x')`,
		`UPDATE ` + transitionSchema + `.things SET note = 'y'`,
		`DELETE FROM ` + transitionSchema + `.things WHERE note = 'y'`,
	} {
		if _, err := f.svc.Exec(ctx, stmt); err != nil {
			t.Fatalf("%s on its own domain table after adopt (%q): want success, got %v", transitionSvcRole, stmt, err)
		}
	}

	// The append-only guarantee survives the ownership move.
	for _, tc := range []struct{ what, stmt string }{
		{"UPDATE audit_log", `UPDATE ` + transitionSchema + `.audit_log SET note = 'tampered'`},
		{"DELETE audit_log", `DELETE FROM ` + transitionSchema + `.audit_log`},
		{"TRUNCATE audit_log", `TRUNCATE ` + transitionSchema + `.audit_log`},
		{"UPDATE sync_conflict_log", `UPDATE ` + transitionSchema + `.sync_conflict_log SET note = 'tampered'`},
		{"DELETE sync_conflict_log", `DELETE FROM ` + transitionSchema + `.sync_conflict_log`},
		{"TRUNCATE sync_conflict_log", `TRUNCATE ` + transitionSchema + `.sync_conflict_log`},
		{"read the goose ledger", `SELECT count(*) FROM ` + transitionSchema + `.goose_db_version`},
	} {
		t.Run(tc.what, func(t *testing.T) {
			if _, err := f.svc.Exec(ctx, tc.stmt); err == nil {
				t.Fatalf("%s: %s after adopt — want a permission error, got success", transitionSvcRole, tc.what)
			}
		})
	}

	// The beekeepingit-scoped default privileges are gone. If they survive,
	// every table a FUTURE migration creates is granted full DML to the
	// runtime role by a grantor nothing in the steady state can revoke —
	// including a new audit_log.
	if got := f.beekeepingitDefaultACLRows(t); got != 0 {
		t.Fatalf("%d beekeepingit-scoped pg_default_acl row(s) left after adopt, want 0 — these keep granting full DML on every future table, and only beekeepingit can ever revoke them (which the steady state no longer runs)", got)
	}
}

// TestMigratorTransition_IsIdempotent covers the fact that the adopt Job is a
// post-install/post-upgrade hook with no owner check gating it: while the flag
// is on it re-runs on EVERY `helm upgrade`, including the second and third one
// after the transition has already completed. Re-running must be a no-op, not
// an error and not a different end state.
func TestMigratorTransition_IsIdempotent(t *testing.T) {
	f := newMigratorTransitionFixture(t)
	f.enableMigratorTransitionAsIfByCNPGOperator(t)

	f.mustRunAdopt(t)
	first := f.relationOwners(t)

	f.mustRunAdopt(t)
	second := f.relationOwners(t)

	if len(first) != len(second) {
		t.Fatalf("relation set changed across a repeated adopt: %v then %v", first, second)
	}
	for name, owner := range second {
		if owner != transitionMigrator {
			t.Fatalf("%s.%s owned by %q after a repeated adopt, want %q", transitionSchema, name, owner, transitionMigrator)
		}
	}
	if got := f.beekeepingitDefaultACLRows(t); got != 0 {
		t.Fatalf("%d beekeepingit-scoped pg_default_acl row(s) after a repeated adopt, want 0", got)
	}

	// The runtime ACL must also be unchanged, not just ownership — a second
	// pass that re-granted the blanket DML without re-revoking would leave
	// audit_log mutable, which is the shape of the bug #541's own
	// table-grants job had to be rewritten to avoid.
	ctx := context.Background()
	if _, err := f.svc.Exec(ctx, `INSERT INTO `+transitionSchema+`.audit_log (id, note) VALUES (gen_random_uuid(), 'ok')`); err != nil {
		t.Fatalf("%s INSERT after a repeated adopt: want success, got %v", transitionSvcRole, err)
	}
	if _, err := f.svc.Exec(ctx, `UPDATE `+transitionSchema+`.audit_log SET note = 'tampered'`); err == nil {
		t.Fatalf("%s can UPDATE audit_log after a repeated adopt: want a permission error, got success", transitionSvcRole)
	}
}

// TestMigratorTransition_MigrateWorksImmediatelyAfterAdopt is the weight-1 ->
// weight-2 handoff, and it is the reason adopt and migrate ship in the SAME
// release rather than across two.
//
// The migrate Job at weight 2 authenticates as `<schema>_migrator` and runs
// the service's real migrations through dbaccess.Migrate. That has to work on
// the very first release where the credential changes — against a goose ledger
// that already exists with rows in it, written by a DIFFERENT role, and now
// owned by this one. If it does not, the transition release fails its own
// deploy.
func TestMigratorTransition_MigrateWorksImmediatelyAfterAdopt(t *testing.T) {
	ctx := context.Background()
	f := newMigratorTransitionFixture(t)
	f.enableMigratorTransitionAsIfByCNPGOperator(t)
	f.mustRunAdopt(t)

	// The same later migration that #541 crashlooped on, shaped like #470's
	// `ALTER TABLE audit_log ADD COLUMN actor_scope`.
	if err := dbaccess.Migrate(ctx, f.migratorDSN, historyTableMigrations()); err != nil {
		t.Fatalf("dbaccess.Migrate as %s straight after adopt: want success, got %v — the transition release's own weight-2 hook would fail here",
			transitionMigrator, err)
	}

	// goose recorded the new version in the ledger it now owns.
	var version int64
	if err := f.superuser.QueryRow(ctx,
		`SELECT max(version_id) FROM `+transitionSchema+`.goose_db_version`).Scan(&version); err != nil {
		t.Fatalf("read goose ledger: %v", err)
	}
	if version != 2 {
		t.Fatalf("goose ledger max version = %d, want 2 — the migration did not record, so the next deploy would replay it", version)
	}

	// And #62's guarantee still holds on the freshly-altered table.
	if _, err := f.svc.Exec(ctx, `UPDATE `+transitionSchema+`.audit_log SET note = 'tampered'`); err == nil {
		t.Fatalf("%s can UPDATE audit_log after the post-adopt migration: want a permission error, got success", transitionSvcRole)
	}
}

// TestMigratorTransition_IsAtomic pins non-negotiable 3 — the whole per-schema
// transition is ONE transaction — by the only means a test can: rolling it
// back and showing that nothing survived.
//
// Why this matters more than it looks. Between the REVOKE and the re-GRANT
// there is an instant where `<schema>_svc` holds nothing at all, and between
// the blanket GRANT and the history REVOKE there is an instant where it holds
// UPDATE/DELETE on `audit_log`. The outgoing ReplicaSet's pods are serving
// with live `<schema>_svc` connections for the entire duration of the hook, so
// "briefly" is not the same as "unobservably". #541's own table-grants job
// shipped exactly this bug once — the blanket GRANT committed in one psql
// process and the REVOKE applied in a later, separate one — and it opened a
// real UPDATE/DELETE window on the audit log on every upgrade.
//
// If someone later splits this Job's psql invocation into several, or drops
// `--single-transaction`, this test is what says so.
func TestMigratorTransition_IsAtomic(t *testing.T) {
	ctx := context.Background()
	f := newMigratorTransitionFixture(t)
	f.enableMigratorTransitionAsIfByCNPGOperator(t)

	tx, err := f.owner.Begin(ctx)
	if err != nil {
		t.Fatalf("begin: %v", err)
	}
	for _, stmt := range adoptStatements(transitionSchema) {
		if _, err := tx.Exec(ctx, stmt); err != nil {
			t.Fatalf("adopt statement inside the transaction (%q): %v", stmt, err)
		}
	}
	if err := tx.Rollback(ctx); err != nil {
		t.Fatalf("rollback: %v", err)
	}

	for name, owner := range f.relationOwners(t) {
		if owner != transitionOwner {
			t.Fatalf("%s.%s owned by %q after a ROLLED BACK adopt, want %q — the transition is not atomic, so a session CAN observe an intermediate ACL",
				transitionSchema, name, owner, transitionOwner)
		}
	}
	if got := f.beekeepingitDefaultACLRows(t); got == 0 {
		t.Fatal("beekeepingit-scoped pg_default_acl rows were removed by a ROLLED BACK adopt — the transition is not atomic")
	}
	// The pre-state ACL is intact too: still append-only, still writable.
	if _, err := f.svc.Exec(ctx, `INSERT INTO `+transitionSchema+`.audit_log (id, note) VALUES (gen_random_uuid(), 'ok')`); err != nil {
		t.Fatalf("%s INSERT after a rolled-back adopt: want success, got %v", transitionSvcRole, err)
	}
	if _, err := f.svc.Exec(ctx, `UPDATE `+transitionSchema+`.audit_log SET note = 'tampered'`); err == nil {
		t.Fatalf("%s can UPDATE audit_log after a rolled-back adopt: want a permission error, got success", transitionSvcRole)
	}
}

// TestMigratorTransition_GuardRejectsObjectKindsItCannotMove proves the guard
// from non-negotiable 2 actually fires, rather than being a comment about an
// eventuality nobody tested.
//
// The ownership loop reads `pg_class`, so functions (`pg_proc`) and standalone
// types (`pg_type`) are invisible to it and would be left owned by
// `beekeepingit` — a schema transitioned 90% of the way, with no error and no
// symptom until something needed to alter one of them. None exist in these
// schemas today (every enum-like value is validated in Go, per
// docs/CODEMAPS/data.md's extensible-enum convention, and PostGIS installs
// into `public`), which is precisely why the guard is what keeps it true.
func TestMigratorTransition_GuardRejectsObjectKindsItCannotMove(t *testing.T) {
	ctx := context.Background()

	for _, tc := range []struct {
		what   string
		create string
		want   string
	}{
		{
			what:   "a function",
			create: `CREATE FUNCTION ` + transitionSchema + `.noop() RETURNS int LANGUAGE sql AS 'SELECT 1'`,
			want:   "routine(s)",
		},
		{
			what:   "an enum type",
			create: `CREATE TYPE ` + transitionSchema + `.priority AS ENUM ('low', 'high')`,
			want:   "standalone type(s)",
		},
		{
			what:   "a standalone composite type",
			create: `CREATE TYPE ` + transitionSchema + `.pair AS (a int, b int)`,
			want:   "standalone type(s)",
		},
		{
			what:   "a domain",
			create: `CREATE DOMAIN ` + transitionSchema + `.positive AS int CHECK (VALUE > 0)`,
			want:   "standalone type(s)",
		},
	} {
		t.Run(tc.what, func(t *testing.T) {
			f := newMigratorTransitionFixture(t)
			f.enableMigratorTransitionAsIfByCNPGOperator(t)

			if _, err := f.owner.Exec(ctx, tc.create); err != nil {
				t.Fatalf("create %s: %v", tc.what, err)
			}

			err := f.runAdopt(t)
			if err == nil {
				t.Fatalf("adopt with %s present: want the guard to fail the release, got success — the schema would be left half-transitioned with no symptom until something tried to alter it",
					tc.what)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("adopt with %s present: want an error naming %q, got %v", tc.what, tc.want, err)
			}

			// And nothing moved — the guard runs before the loop, inside the
			// same transaction, so a rejected schema is left exactly as it was.
			for name, owner := range f.relationOwners(t) {
				if owner != transitionOwner {
					t.Fatalf("%s.%s owned by %q after a GUARD-REJECTED adopt, want %q", transitionSchema, name, owner, transitionOwner)
				}
			}
		})
	}
}

// reverseAdoptStatements mirrors the recovery SQL published in
// infra/README.md → "Transitioning an existing cluster (#545)". Same
// keep-in-sync caveat as adoptStatements above.
//
// It runs as a SUPERUSER, which is the one thing about it that is not
// symmetrical with the forward direction: in steady state `beekeepingit` is a
// member of no migrator role, so it cannot alter the ownership of relations
// the migrators now own. There is no non-superuser path back.
func reverseAdoptStatements(schema string) []string {
	ownershipLoop := fmt.Sprintf(`DO $do$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT c.oid::regclass AS ident, c.relkind
      FROM pg_class c
     WHERE c.relnamespace = '%[1]s'::regnamespace
       AND c.relkind IN ('r','p','S','v','m','f')
       AND c.relowner <> '%[2]s'::regrole
     ORDER BY CASE c.relkind WHEN 'r' THEN 1 WHEN 'p' THEN 1 WHEN 'f' THEN 2
                             WHEN 'S' THEN 3 WHEN 'v' THEN 4 ELSE 5 END
  LOOP
    EXECUTE format('ALTER %%s %%s OWNER TO %[2]s',
                   CASE r.relkind WHEN 'r' THEN 'TABLE' WHEN 'p' THEN 'TABLE'
                                  WHEN 'f' THEN 'FOREIGN TABLE' WHEN 'S' THEN 'SEQUENCE'
                                  WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW' END,
                   r.ident);
  END LOOP;
END
$do$`, schema, transitionOwner)

	return []string{
		ownershipLoop,
		fmt.Sprintf(`ALTER DEFAULT PRIVILEGES FOR ROLE %s_migrator IN SCHEMA %s REVOKE ALL ON TABLES FROM %s_svc`, schema, schema, schema),
		fmt.Sprintf(`ALTER DEFAULT PRIVILEGES FOR ROLE %s_migrator IN SCHEMA %s REVOKE ALL ON SEQUENCES FROM %s_svc`, schema, schema, schema),
		fmt.Sprintf(`REVOKE ALL ON ALL TABLES IN SCHEMA %s FROM %s_svc`, schema, schema),
		fmt.Sprintf(`REVOKE ALL ON ALL SEQUENCES IN SCHEMA %s FROM %s_svc`, schema, schema),
		fmt.Sprintf(`SET LOCAL ROLE %s`, transitionOwner),
		fmt.Sprintf(`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %s TO %s_svc`, schema, schema),
		fmt.Sprintf(`GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %s TO %s_svc`, schema, schema),
		fmt.Sprintf(`ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA %s GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO %s_svc`, transitionOwner, schema, schema),
		fmt.Sprintf(`ALTER DEFAULT PRIVILEGES FOR ROLE %s IN SCHEMA %s GRANT USAGE, SELECT ON SEQUENCES TO %s_svc`, transitionOwner, schema, schema),
		fmt.Sprintf(`REVOKE UPDATE, DELETE, TRUNCATE ON %s.audit_log FROM %s_svc`, schema, schema),
		fmt.Sprintf(`REVOKE UPDATE, DELETE, TRUNCATE ON %s.sync_conflict_log FROM %s_svc`, schema, schema),
	}
}

// TestMigratorTransition_ReverseAdoptRestoresThePre545State exercises the
// documented recovery path, because `helm rollback` does not work across this
// change and this SQL is therefore the only way back.
//
// Why rollback breaks: the pre-#545 `table-grants` Job connects as
// `beekeepingit` and issues `GRANT ... ON ALL TABLES`, which a non-owner
// cannot do once the migrators own everything — so the rolled-back release's
// own weight-3 hook fails and the rollback does not complete. That leaves this
// script as the last resort, and a last resort nobody has run is not one.
//
// The end state it restores is deliberately the PRE-#545 ACL, full-DML
// defaults included. It is a route back to a known-good older release, not a
// state to stop in.
func TestMigratorTransition_ReverseAdoptRestoresThePre545State(t *testing.T) {
	ctx := context.Background()
	f := newMigratorTransitionFixture(t)
	f.enableMigratorTransitionAsIfByCNPGOperator(t)
	f.mustRunAdopt(t)

	// Steady state: the transition flag has been turned back off, so CNPG has
	// revoked beekeepingit's migrator memberships. This is the situation an
	// operator is actually in when they need to reverse.
	if _, err := f.superuser.Exec(ctx, fmt.Sprintf(`REVOKE %s FROM %s`, transitionMigrator, transitionOwner)); err != nil {
		t.Fatalf("revoke the transition membership: %v", err)
	}

	// beekeepingit genuinely cannot do this alone any more — which is why the
	// runbook says superuser, and why that instruction has to be right.
	if _, err := f.owner.Exec(ctx, `ALTER TABLE `+transitionSchema+`.things OWNER TO `+transitionOwner); err == nil {
		t.Fatalf("%s could reverse an ownership move without a superuser: the runbook's superuser requirement is wrong, or a membership survived the flag going off", transitionOwner)
	}

	tx, err := f.superuser.Begin(ctx)
	if err != nil {
		t.Fatalf("begin reverse transaction: %v", err)
	}
	for _, stmt := range reverseAdoptStatements(transitionSchema) {
		if _, err := tx.Exec(ctx, stmt); err != nil {
			_ = tx.Rollback(ctx)
			t.Fatalf("reverse adopt statement (%q): %v", stmt, err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatalf("commit reverse transaction: %v", err)
	}

	for name, owner := range f.relationOwners(t) {
		if owner != transitionOwner {
			t.Fatalf("%s.%s owned by %q after the reverse, want %q — the pre-#545 table-grants Job would fail on it", transitionSchema, name, owner, transitionOwner)
		}
	}
	if got := f.beekeepingitDefaultACLRows(t); got == 0 {
		t.Fatal("no beekeepingit-scoped pg_default_acl rows after the reverse — the pre-#545 release expects them, so its default privileges would be missing")
	}

	// The service is unharmed by the round trip, and the audit log is still
	// append-only — a recovery path that quietly unlocks history would be
	// worse than no recovery path.
	if _, err := f.svc.Exec(ctx, `INSERT INTO `+transitionSchema+`.audit_log (id, note) VALUES (gen_random_uuid(), 'ok')`); err != nil {
		t.Fatalf("%s INSERT after the reverse: want success, got %v", transitionSvcRole, err)
	}
	if _, err := f.svc.Exec(ctx, `UPDATE `+transitionSchema+`.audit_log SET note = 'tampered'`); err == nil {
		t.Fatalf("%s can UPDATE audit_log after the reverse: want a permission error, got success", transitionSvcRole)
	}
	if _, err := f.svc.Exec(ctx, `UPDATE `+transitionSchema+`.things SET note = 'y'`); err != nil {
		t.Fatalf("%s UPDATE on its own domain table after the reverse: want success, got %v", transitionSvcRole, err)
	}

	// And the pre-#545 weight-3 Job — `beekeepingit` granting on ALL TABLES —
	// works again, which is the actual definition of "back on the old release".
	if _, err := f.owner.Exec(ctx,
		`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA `+transitionSchema+` TO `+transitionSvcRole); err != nil {
		t.Fatalf("the pre-#545 table-grants statement as %s after the reverse: want success, got %v", transitionOwner, err)
	}
}

// TestMigratorTransition_GuardRejectsAPre541Cluster covers the deploy-ORDER
// hazard, which is the one failure mode of this transition that is a
// deployment mistake rather than a code mistake.
//
// `ALTER ... OWNER TO` needs the caller to be the relation's current owner or
// a member of the owning role. Flipping `migratorTransition.enabled` on
// replaces beekeepingit's `inRoles` — it gains the migrator roles and LOSES
// the `<schema>_svc` memberships #541 gave it. On a cluster running #541 that
// is exactly right: beekeepingit owns everything, so there is nothing left
// that needs an `<schema>_svc` membership to reach.
//
// On a cluster that never deployed #541, tables created by the old
// pod-startup migration path are still owned by `<schema>_svc` — and the
// membership that could move them has just been revoked. Running this
// transition there fails, and it SHOULD fail; the point of the guard is that
// it fails saying what to do about it, instead of `must be owner of table
// apiaries.things`, which reads like a bug in the Job.
func TestMigratorTransition_GuardRejectsAPre541Cluster(t *testing.T) {
	ctx := context.Background()
	f := newMigratorTransitionFixture(t)

	// The pre-#541 world: the service migrated as its own runtime role, so it
	// created — and therefore owns — its tables. (CREATE on the schema is
	// granted and re-revoked here because #541's schema-grants already took
	// it away; the leftover OWNERSHIP is what outlives that.)
	for _, stmt := range []string{
		`GRANT CREATE ON SCHEMA ` + transitionSchema + ` TO ` + transitionSvcRole,
	} {
		if _, err := f.owner.Exec(ctx, stmt); err != nil {
			t.Fatalf("grant CREATE for the legacy setup: %v", err)
		}
	}
	if _, err := f.svc.Exec(ctx, `CREATE TABLE `+transitionSchema+`.legacy_owned (id UUID PRIMARY KEY)`); err != nil {
		t.Fatalf("create a legacy %s-owned table: %v", transitionSvcRole, err)
	}
	if _, err := f.owner.Exec(ctx, `REVOKE CREATE ON SCHEMA `+transitionSchema+` FROM `+transitionSvcRole); err != nil {
		t.Fatalf("re-revoke CREATE: %v", err)
	}

	f.enableMigratorTransitionAsIfByCNPGOperator(t)

	err := f.runAdopt(t)
	if err == nil {
		t.Fatal("adopt against a pre-#541 cluster: want the guard to fail the release, got success")
	}
	if !strings.Contains(err.Error(), "predates #541") {
		t.Fatalf("adopt against a pre-#541 cluster: want an error pointing at the deploy order, got %v", err)
	}
	if !strings.Contains(err.Error(), "legacy_owned") {
		t.Fatalf("adopt against a pre-#541 cluster: want the offending relation named in the error, got %v", err)
	}
}

// TestMigratorTransition_AlterOwnerRewritesGrantorReferences pins the Postgres
// behaviour that non-negotiable 4 of migrator-adopt-job.yaml deliberately
// refuses to depend on.
//
// The question is whether `ALTER TABLE ... OWNER TO new_owner` rewrites the
// GRANTOR recorded in that table's ACL. If it does NOT, then a `REVOKE` issued
// by the new owner matches no grant, removes nothing, and returns success —
// leaving `audit_log` mutable while the adopt Job reports a clean transition.
// A silent failure, on the one table whose entire purpose is that it cannot be
// tampered with.
//
// MEASURED, on both PostgreSQL 16 and 18 (production runs 18): Postgres DOES
// rewrite the grantor. `apiaries_svc=ar/beekeepingit` becomes
// `apiaries_svc=ar/apiaries_migrator`, so the shortcut would in fact work
// today.
//
// The adopt Job still revokes as `beekeepingit` anyway, and that is not
// belt-and-braces for its own sake: it is correct under BOTH behaviours (as
// grantor, or as a member of whatever role the grantor became), whereas the
// shortcut is correct only under this one, which is documented nowhere as a
// guarantee. The cost of not depending on it is one extra statement inside a
// transaction that is already there.
//
// This test is the tripwire. If a future Postgres stops rewriting the grantor,
// it fails here — loudly, in a file that explains what to do — rather than
// somewhere downstream where an audit log quietly stayed mutable.
func TestMigratorTransition_AlterOwnerRewritesGrantorReferences(t *testing.T) {
	ctx := context.Background()
	f := newMigratorTransitionFixture(t)
	f.enableMigratorTransitionAsIfByCNPGOperator(t)

	grantorOf := func(stage string) string {
		t.Helper()
		var acl []string
		if err := f.superuser.QueryRow(ctx,
			`SELECT coalesce(relacl::text[], ARRAY[]::text[]) FROM pg_class
			  WHERE oid = ($1 || '.things')::regclass`, transitionSchema).Scan(&acl); err != nil {
			t.Fatalf("read relacl %s: %v", stage, err)
		}
		for _, item := range acl {
			// aclitem text form is `grantee=privs/grantor`.
			if strings.HasPrefix(item, transitionSvcRole+"=") {
				parts := strings.SplitN(item, "/", 2)
				if len(parts) == 2 {
					return parts[1]
				}
			}
		}
		t.Fatalf("no ACL entry for %s %s: %v", transitionSvcRole, stage, acl)
		return ""
	}

	if got := grantorOf("before the ownership move"); got != transitionOwner {
		t.Fatalf("grantor before the ownership move = %q, want %q — the fixture is not reproducing #541's grant-by-beekeepingit state, so this test proves nothing",
			got, transitionOwner)
	}

	if _, err := f.owner.Exec(ctx, `ALTER TABLE `+transitionSchema+`.things OWNER TO `+transitionMigrator); err != nil {
		t.Fatalf("ALTER TABLE ... OWNER TO %s: %v", transitionMigrator, err)
	}

	if got := grantorOf("after the ownership move"); got != transitionMigrator {
		t.Fatalf(`grantor after ALTER ... OWNER TO = %q, want %q.

Postgres has STOPPED rewriting grantor references on an ownership change. That
is the behaviour migrator-adopt-job.yaml's non-negotiable 4 is written to be
safe against, so the Job itself is still correct — it revokes as beekeepingit.
What is no longer safe is any FUTURE shortcut that revokes as the new owner,
and the assumption should be re-checked anywhere else it may have crept in
(charts/postgres/templates/_helpers.tpl's runtimeGrantsPsqlArgs runs as the
migrator and revokes grants the migrator itself made, which stays fine).`,
			got, transitionMigrator)
	}
}
