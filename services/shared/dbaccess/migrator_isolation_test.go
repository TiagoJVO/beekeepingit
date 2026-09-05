package dbaccess_test

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	tcpostgres "github.com/testcontainers/testcontainers-go/modules/postgres"

	"github.com/TiagoJVO/beekeepingit/services/shared/dbaccess"
)

// This file is #545's acceptance proof: each service's migrate Job "can
// migrate its own schema and CANNOT touch another service's schema — with a
// test proving the negative".
//
// WHY THE NEGATIVE NEEDS ITS OWN FIXTURE. audit_immutability_test.go and
// migration_ownership_test.go both model ONE schema, which is enough to prove
// what the runtime role may do to a table it does not own — but structurally
// incapable of saying anything about cross-schema reach, because there is no
// second schema to reach into. #541's blast radius (one compromised service
// image holding database-owner rights over every other service's data and
// audit_log) is invisible in a one-schema world. So this fixture wires TWO,
// exactly the way the chart does after #545, and then tries to get from one to
// the other by every route that exists.
//
// helm-e2e cannot substitute for this. It installs a fresh cluster and asserts
// that the deploy succeeds; "apiaries_migrator failed to read
// organizations.audit_log" is not something a successful deploy demonstrates,
// and nothing in that suite ever attempts it.

const (
	isoSchemaA = "apiaries"      // the schema whose migrator does the reaching
	isoSchemaB = "organizations" // the schema it must not be able to reach
	isoDB      = "beekeepingit_test"
	isoOwner   = "beekeepingit" // database + schema owner; owns no TABLE after #545

	isoBootstrapUser = "postgres_test"
	isoBootstrapPass = "postgres_test"
	isoRolePassword  = "role_pw"
)

// migratorIsolationFixture reproduces the post-#545 role/schema layout of
// infra/helm/beekeepingit/charts/postgres — cluster.yaml's `managed.roles`,
// schema-grants-job.yaml (hook weight 0), the charts/services migrate Job
// (weight 2) and table-grants-job.yaml (weight 3) — for two schemas at once.
//
// The property under test is a property of the ROLE GRAPH, so what this
// fixture leaves OUT matters as much as what it sets up: no role here is a
// member of any other role, in any direction. That is the whole design.
// `beekeepingit` keeps its `inRoles` only while `postgres.migratorTransition
// .enabled` is on, and this fixture models steady state, where the flag is
// off and CNPG has revoked those memberships.
type migratorIsolationFixture struct {
	// superuser stands in for CNPG's own privileged operator reconciliation
	// connection (see audit_immutability_test.go's type comment for why that
	// distinction is load-bearing and not incidental): it is the only
	// principal that can create roles, and the only one that COULD grant role
	// membership — which is exactly what this fixture deliberately never asks
	// it to do.
	superuser *pgx.Conn

	// One live connection per production principal. Real connections, not
	// `SET ROLE` from the superuser session: `SET ROLE` is authorized against
	// session_user, so a superuser session can hop to any role and would make
	// TestMigratorIsolation_CannotSetRoleIntoAnotherSchemasMigrator pass
	// vacuously (verified: it does — the check reads session_user, not
	// current_user).
	aMigrator *pgx.Conn
	aSvc      *pgx.Conn
	bMigrator *pgx.Conn
	bSvc      *pgx.Conn

	// The migrator's DSN with its own schema as search_path, so a test can
	// drive the REAL dbaccess.Migrate as this role.
	aMigratorDSN string

	// connectAs opens a further connection for any role — used by the tests
	// that need a principal the fixture does not keep open (beekeepingit).
	connectAs func(t *testing.T, user string) *pgx.Conn
}

// startIsolationPostgres boots a container and returns a connect helper.
// postgres:16-alpine matches every other testcontainers fixture in this repo.
// Production runs PostgreSQL 18 (charts/postgres/values.yaml pins CNPG's
// postgis:18.4 operand), so the ACL/ownership semantics every assertion here
// depends on were re-verified by hand against postgres:18-alpine before this
// file was written and behave identically on both — including the one that is
// genuinely version-sensitive (see
// TestMigratorTransition_AlterOwnerRewritesGrantorReferences in
// migrator_transition_test.go). Pinning 16 keeps CI to one Postgres image.
func startIsolationPostgres(t *testing.T) func(user, password, searchPath string) dbaccess.Config {
	t.Helper()
	ctx := context.Background()

	container, err := tcpostgres.Run(ctx, "postgres:16-alpine",
		tcpostgres.WithUsername(isoBootstrapUser),
		tcpostgres.WithPassword(isoBootstrapPass),
		tcpostgres.WithDatabase(isoDB),
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

	return func(user, password, searchPath string) dbaccess.Config {
		return dbaccess.Config{
			Host: host, Port: port.Port(), User: user, Password: password,
			Database: isoDB, SSLMode: "disable", SearchPath: searchPath,
		}
	}
}

func newMigratorIsolationFixture(t *testing.T) *migratorIsolationFixture {
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

	// cluster.yaml: bootstrap.initdb.owner + managed.roles. Three roles per
	// schema's worth of principals, and NOT ONE `GRANT <role> TO <role>`.
	exec(su, "bootstrap", fmt.Sprintf(`CREATE ROLE %s WITH LOGIN PASSWORD '%s'`, isoOwner, isoRolePassword))
	for _, schema := range []string{isoSchemaA, isoSchemaB} {
		for _, suffix := range []string{"migrator", "svc"} {
			exec(su, "bootstrap", fmt.Sprintf(`CREATE ROLE %s_%s WITH LOGIN PASSWORD '%s'`, schema, suffix, isoRolePassword))
		}
		// cluster.yaml postInitApplicationSQL. Schema ownership deliberately
		// stays with beekeepingit rather than moving to the migrator: a
		// non-owner cannot GRANT ON SCHEMA (which would break
		// schema-grants-job.yaml), and it buys nothing — a schema's owner
		// cannot read or alter a table it does not own, which is precisely
		// what TestMigratorIsolation_SchemaOwnerCannotReadTablesItDoesNotOwn
		// pins.
		exec(su, "bootstrap", fmt.Sprintf(`CREATE SCHEMA %s AUTHORIZATION %s`, schema, isoOwner))
	}

	owner := connect(isoOwner, isoRolePassword)

	// schema-grants-job.yaml, hook weight 0, run as beekeepingit.
	for _, schema := range []string{isoSchemaA, isoSchemaB} {
		exec(owner, "schema-grants", fmt.Sprintf(`GRANT USAGE, CREATE ON SCHEMA %s TO %s_migrator`, schema, schema))
		exec(owner, "schema-grants", fmt.Sprintf(`GRANT USAGE ON SCHEMA %s TO %s_svc`, schema, schema))
		exec(owner, "schema-grants", fmt.Sprintf(`REVOKE CREATE ON SCHEMA %s FROM %s_svc`, schema, schema))
	}

	f := &migratorIsolationFixture{
		superuser:    su,
		aMigrator:    connect(isoSchemaA+"_migrator", isoRolePassword),
		aSvc:         connect(isoSchemaA+"_svc", isoRolePassword),
		bMigrator:    connect(isoSchemaB+"_migrator", isoRolePassword),
		bSvc:         connect(isoSchemaB+"_svc", isoRolePassword),
		aMigratorDSN: configFor(isoSchemaA+"_migrator", isoRolePassword, isoSchemaA).DSN(),
		connectAs: func(t *testing.T, user string) *pgx.Conn {
			t.Helper()
			return connect(user, isoRolePassword)
		},
	}

	// charts/services migrate-job.yaml, hook weight 2: each schema's tables
	// are created BY that schema's own migrator, so it owns them from birth —
	// the reason a fresh install needs no ownership step at all.
	for schema, conn := range map[string]*pgx.Conn{isoSchemaA: f.aMigrator, isoSchemaB: f.bMigrator} {
		for _, stmt := range []string{
			`CREATE TABLE %s.things (id UUID PRIMARY KEY, note TEXT NOT NULL)`,
			`CREATE TABLE %s.audit_log (id UUID PRIMARY KEY, note TEXT NOT NULL)`,
			`CREATE TABLE %s.sync_conflict_log (id UUID PRIMARY KEY, note TEXT NOT NULL)`,
			// goose's own ledger shape, including the `serial` sequence, so
			// the ledger REVOKE below is exercised against the real thing.
			`CREATE TABLE %s.goose_db_version (id SERIAL PRIMARY KEY, version_id BIGINT NOT NULL)`,
		} {
			exec(conn, "migrate job", fmt.Sprintf(stmt, schema))
		}
		exec(conn, "migrate job", fmt.Sprintf(`INSERT INTO %s.audit_log (id, note) VALUES (gen_random_uuid(), 'seed')`, schema))
		applyRuntimeGrants(t, conn, schema)
	}

	return f
}

// defaultHistoryTables mirrors `historyTables` in
// charts/postgres/values.yaml — the central append-only classification list
// (#553). Kept in sync by hand, like the rest of the mirror below.
var defaultHistoryTables = []string{"audit_log", "sync_conflict_log"}

// applyRuntimeGrants mirrors the END STATE of
// charts/postgres/templates/_helpers.tpl's `postgres.runtimeGrantsPsqlArgs` —
// the single definition table-grants-job.yaml (weight 3) and the gated
// migrator-adopt-job.yaml (weight 1) both apply, run here as the schema's own
// migrator, with the production default history-table list.
func applyRuntimeGrants(t *testing.T, migrator *pgx.Conn, schema string) {
	t.Helper()
	if err := runRuntimeGrants(migrator, schema, defaultHistoryTables); err != nil {
		t.Fatalf("table-grants: %v", err)
	}
}

// runRuntimeGrants is the mirror itself, returning the error instead of
// failing the test, so history_fail_closed_test.go can assert that the #553
// guard trips — a t.Fatal-ing helper cannot express "this run MUST fail".
//
// Deliberately the END STATE and not the literal rendered SQL. That template
// emits Helm-rendered `psql -c` arguments wrapped in a shell script; executing
// it verbatim would need helm and a shell in the test, which the deleted
// audit-immutability-job coverage attempt already showed is a dead end (see the
// closing NOTE in audit_immutability_test.go — driving rendered job scripts
// through Container.Exec hung unreliably). What every assertion in this file
// actually checks is the resulting ACL, so that is what this reproduces. It
// must be kept in sync with the helper by hand; a divergence surfaces as this
// file's assertions describing an ACL production does not have.
//
// Everything runs in ONE transaction, mirroring the callers'
// `--single-transaction` — since #553 that matters to the tests, not just to
// production: the fail-closed guard aborting the transaction is what rolls the
// blanket GRANT back, and history_fail_closed_test.go asserts that rollback.
func runRuntimeGrants(migrator *pgx.Conn, schema string, historyTables []string) error {
	ctx := context.Background()

	tx, err := migrator.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin table-grants transaction: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	for _, stmt := range runtimeGrantsStatements(schema, historyTables) {
		if _, err := tx.Exec(ctx, stmt); err != nil {
			return fmt.Errorf("table-grants (%q): %w", stmt, err)
		}
	}
	return tx.Commit(ctx)
}

// runtimeGrantsStatements is the statement list itself, split out so
// migrator_transition_test.go's adopt mirror can append the SAME list after
// its `SET LOCAL ROLE` — reproducing in the tests the exact sharing production
// gets from both Jobs including one helper, which is what keeps a transitioned
// cluster and a fresh one on identical ACLs.
func runtimeGrantsStatements(schema string, historyTables []string) []string {
	quoted := make([]string, len(historyTables))
	for i, tbl := range historyTables {
		quoted[i] = "'" + tbl + "'"
	}
	// The template's DO block, with {schema} / {historyTables} in place of
	// Helm's interpolations. A replacer, not fmt.Sprintf — the block is full
	// of format()'s own %I/%s verbs.
	doBlock := strings.NewReplacer(
		"{schema}", schema,
		"{historyTables}", strings.Join(quoted, ", "),
	).Replace(`DO $do$
    DECLARE
      history_tables CONSTANT text[] := ARRAY[{historyTables}]::text[];
      t text;
      unclassified text;
    BEGIN
      FOREACH t IN ARRAY history_tables LOOP
        IF EXISTS (SELECT 1 FROM pg_tables
                   WHERE schemaname = '{schema}' AND tablename = t) THEN
          EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON %I.%I FROM %I',
                         '{schema}', t, '{schema}_svc');
        END IF;
      END LOOP;
      IF EXISTS (SELECT 1 FROM pg_tables
                 WHERE schemaname = '{schema}' AND tablename = 'goose_db_version') THEN
        EXECUTE format('REVOKE ALL ON %I.%I FROM %I',
                       '{schema}', 'goose_db_version', '{schema}_svc');
      END IF;
      -- FAIL-CLOSED GUARD (#553): a table named like a history table that this
      -- release cannot classify fails the release, in this transaction, so the
      -- blanket GRANT above rolls back with it and the table is never mutable.
      SELECT string_agg(tablename, ', ' ORDER BY tablename) INTO unclassified
        FROM pg_tables
       WHERE schemaname = '{schema}'
         AND lower(tablename) LIKE '%\_log'
         AND NOT tablename = ANY (history_tables);
      IF unclassified IS NOT NULL THEN
        RAISE EXCEPTION '%: unclassified history-style table(s): %. Fail-closed (#553).',
                        '{schema}', unclassified;
      END IF;
    END
    $do$`)

	return []string{
		fmt.Sprintf(`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %s TO %s_svc`, schema, schema),
		fmt.Sprintf(`GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %s TO %s_svc`, schema, schema),
		// SELECT, INSERT — not full DML (#545). A history table created by a
		// FUTURE migration must never be mutable, not even for the seconds
		// between the migrate Job creating it (weight 2) and the REVOKE below
		// landing (weight 3).
		fmt.Sprintf(`ALTER DEFAULT PRIVILEGES FOR ROLE %s_migrator IN SCHEMA %s GRANT SELECT, INSERT ON TABLES TO %s_svc`, schema, schema, schema),
		fmt.Sprintf(`ALTER DEFAULT PRIVILEGES FOR ROLE %s_migrator IN SCHEMA %s GRANT USAGE, SELECT ON SEQUENCES TO %s_svc`, schema, schema, schema),
		// The history and ledger REVOKEs, plus the #553 guard — one DO block,
		// exactly as the template ships it.
		doBlock,
	}
}

// TestMigratorIsolation_CannotReachAnotherSchema is the negative #545's
// acceptance criteria ask for, run over every route that could get
// `apiaries_migrator` at `organizations`' data or structure.
//
// Read them as a group rather than a list: reading the audit log, tampering
// with it, learning the other service's migration state from its goose ledger,
// altering or destroying its tables, and planting a table of its own inside
// another service's schema are five different attacks, and #541 permitted all
// five with one credential. Every one of them must fail, and it must fail for
// the migrator specifically — this role is the one that legitimately holds
// full DDL over ITS OWN schema, so "it has no DDL rights" is not the reason
// any of these are rejected.
func TestMigratorIsolation_CannotReachAnotherSchema(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()

	for _, tc := range []struct {
		what string
		stmt string
	}{
		{"SELECT another schema's audit_log", `SELECT count(*) FROM organizations.audit_log`},
		{"INSERT into another schema's audit_log", `INSERT INTO organizations.audit_log (id, note) VALUES (gen_random_uuid(), 'forged')`},
		{"UPDATE another schema's audit_log", `UPDATE organizations.audit_log SET note = 'tampered'`},
		{"DELETE from another schema's audit_log", `DELETE FROM organizations.audit_log`},
		{"TRUNCATE another schema's audit_log", `TRUNCATE organizations.audit_log`},
		{"SELECT another schema's goose ledger", `SELECT count(*) FROM organizations.goose_db_version`},
		{"SELECT another schema's domain table", `SELECT count(*) FROM organizations.things`},
		{"ALTER another schema's table", `ALTER TABLE organizations.audit_log ADD COLUMN sneaky TEXT`},
		{"DROP another schema's table", `DROP TABLE organizations.audit_log`},
		{"CREATE a table inside another schema", `CREATE TABLE organizations.planted (id UUID PRIMARY KEY)`},
		{"seize ownership of another schema's table", `ALTER TABLE organizations.audit_log OWNER TO apiaries_migrator`},
		{"become another schema's migrator", `SET ROLE organizations_migrator`},
		{"pre-authorize itself on another schema's FUTURE tables",
			`ALTER DEFAULT PRIVILEGES FOR ROLE organizations_migrator IN SCHEMA organizations GRANT ALL ON TABLES TO apiaries_migrator`},
	} {
		t.Run(tc.what, func(t *testing.T) {
			if _, err := f.aMigrator.Exec(ctx, tc.stmt); err == nil {
				t.Fatalf("%s_migrator: %s — want a permission error, got success. A migrate Job runs the service's own application image, so this is reachable by anything that compromises that image (#545).",
					isoSchemaA, tc.what)
			}
		})
	}
}

// TestMigratorIsolation_GrantAttemptConveysNothing covers the one route above
// that must NOT be asserted as "it errors".
//
// Postgres silently no-ops a GRANT of a privilege the grantor does not hold —
// it emits a WARNING and returns success. So a test written as "the GRANT
// errors" would be asserting an implementation detail of WHERE the check
// happens rather than the property that matters, and would keep passing while
// quietly meaning something weaker.
//
// Measured, on both PG16 and PG18: this particular GRANT does error, with
// `permission denied for schema organizations` — because resolving the
// qualified table name needs USAGE on the schema, and `apiaries_migrator`
// does not have it, so the statement never gets far enough to reach the
// silent-no-op path. That is a stronger outcome than the no-op, but it is
// contingent on the schema-level REVOKE staying in place. If someone ever
// grants the migrators USAGE on each other's schemas "for a read-only report",
// this statement flips from error to silent success and the assertion below —
// which is about the ESCALATION, not the error — still holds and still fails
// loudly if the escalation lands.
func TestMigratorIsolation_GrantAttemptConveysNothing(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()

	// Tolerated either way: error (today) or silent no-op (if schema USAGE is
	// ever widened). Only the outcome is asserted.
	if _, err := f.aMigrator.Exec(ctx, `GRANT SELECT ON organizations.audit_log TO apiaries_migrator`); err != nil {
		t.Logf("GRANT rejected outright (expected on the current wiring): %v", err)
	}

	if _, err := f.aMigrator.Exec(ctx, `SELECT count(*) FROM organizations.audit_log`); err == nil {
		t.Fatalf("%s_migrator can read %s.audit_log after self-GRANTing: want still-rejected, got success — a role granted itself a privilege it does not hold, which is a genuine escalation, not a no-op",
			isoSchemaA, isoSchemaB)
	}
}

// TestMigratorIsolation_CanDoAllOfThatToItsOwnSchema is the positive control,
// and it is not optional garnish: without it, every assertion above passes
// just as well when the fixture is broken — a role that was never granted
// anything, or a schema whose tables were never created, fails the same way.
// Each statement here is the same operation the corresponding negative
// rejects, pointed at the migrator's OWN schema, where it must succeed because
// running migrations is this role's entire job.
func TestMigratorIsolation_CanDoAllOfThatToItsOwnSchema(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()

	for _, tc := range []struct {
		what string
		stmt string
	}{
		{"SELECT its own audit_log", `SELECT count(*) FROM apiaries.audit_log`},
		{"INSERT into its own audit_log", `INSERT INTO apiaries.audit_log (id, note) VALUES (gen_random_uuid(), 'ok')`},
		{"UPDATE its own audit_log", `UPDATE apiaries.audit_log SET note = 'corrected'`},
		{"SELECT its own goose ledger", `SELECT count(*) FROM apiaries.goose_db_version`},
		{"ALTER its own table", `ALTER TABLE apiaries.audit_log ADD COLUMN actor_scope TEXT`},
		{"CREATE a table in its own schema", `CREATE TABLE apiaries.new_thing (id UUID PRIMARY KEY)`},
		{"set default privileges in its own schema",
			`ALTER DEFAULT PRIVILEGES FOR ROLE apiaries_migrator IN SCHEMA apiaries GRANT SELECT ON TABLES TO apiaries_svc`},
		{"DROP a table it owns", `DROP TABLE apiaries.new_thing`},
		{"TRUNCATE its own audit_log", `TRUNCATE apiaries.audit_log`},
	} {
		t.Run(tc.what, func(t *testing.T) {
			if _, err := f.aMigrator.Exec(ctx, tc.stmt); err != nil {
				t.Fatalf("%s_migrator: %s — want success, got %v. If this fails the fixture is under-privileged and every negative in this file is passing for the wrong reason.",
					isoSchemaA, tc.what, err)
			}
		})
	}
}

// TestMigratorIsolation_MigratorCanRunRealMigrations closes the loop between
// the SQL-level assertions above and the thing production actually runs: the
// migrate Job invokes dbaccess.Migrate with this role's DSN, so the role must
// be able to create goose's ledger and apply migrations under
// search_path=<schema> with no help from anybody.
//
// The fixture already created a ledger by hand, so this exercises the harder
// half — goose finding an existing ledger it owns and applying on top of it.
func TestMigratorIsolation_MigratorCanRunRealMigrations(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()

	// historyTableMigrations (migration_ownership_test.go) creates
	// apiaries.audit_log, which this fixture already made — so drop it first
	// and let the real migration path own its creation end to end.
	if _, err := f.aMigrator.Exec(ctx, `DROP TABLE apiaries.audit_log`); err != nil {
		t.Fatalf("drop fixture audit_log: %v", err)
	}
	if _, err := f.aMigrator.Exec(ctx, `DROP TABLE apiaries.goose_db_version`); err != nil {
		t.Fatalf("drop fixture ledger: %v", err)
	}

	if err := dbaccess.Migrate(ctx, f.aMigratorDSN, historyTableMigrations()); err != nil {
		t.Fatalf("dbaccess.Migrate as %s_migrator: want success, got %v", isoSchemaA, err)
	}

	// goose's ledger must land in the schema (via search_path) and be owned by
	// the migrator — not in `public`, where this role has nothing.
	var ledgerOwner string
	if err := f.superuser.QueryRow(ctx,
		`SELECT tableowner FROM pg_tables WHERE schemaname = $1 AND tablename = 'goose_db_version'`,
		isoSchemaA).Scan(&ledgerOwner); err != nil {
		t.Fatalf("locate goose ledger in %s: %v", isoSchemaA, err)
	}
	if want := isoSchemaA + "_migrator"; ledgerOwner != want {
		t.Fatalf("goose ledger owner = %q, want %q", ledgerOwner, want)
	}
}

// TestMigratorIsolation_RoleGraphHasNoBridge asserts the structural property
// every other test in this file silently depends on: no role can act as any
// other role, in any direction.
//
// This is the test that catches a future convenience `inRoles` — the exact
// shape #541 shipped and #545 removes. A membership added to cluster.yaml
// would not break a single behavioural assertion above until it happened to
// bridge the two schemas being probed; this one fails on the membership
// itself, whichever pair it connects.
//
// Both privilege kinds are checked because they are separately grantable and
// each is enough on its own: USAGE is inherited privileges (what
// `ALTER ... OWNER TO` checks), MEMBER is the right to `SET ROLE`. A NOINHERIT
// membership conveys only the second and would slip past a USAGE-only probe.
func TestMigratorIsolation_RoleGraphHasNoBridge(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()

	roles := []string{
		isoOwner,
		isoSchemaA + "_migrator", isoSchemaA + "_svc",
		isoSchemaB + "_migrator", isoSchemaB + "_svc",
	}

	rows, err := f.superuser.Query(ctx, `
		SELECT a.rolname, b.rolname, priv
		  FROM pg_roles a
		  CROSS JOIN pg_roles b
		  CROSS JOIN unnest(ARRAY['USAGE', 'MEMBER']) AS priv
		 WHERE a.rolname = ANY($1) AND b.rolname = ANY($1)
		   AND a.rolname <> b.rolname
		   AND pg_has_role(a.oid, b.oid, priv)`, roles)
	if err != nil {
		t.Fatalf("query role graph: %v", err)
	}
	defer rows.Close()

	var bridges []string
	for rows.Next() {
		var member, target, priv string
		if err := rows.Scan(&member, &target, &priv); err != nil {
			t.Fatalf("scan role graph: %v", err)
		}
		bridges = append(bridges, fmt.Sprintf("%s has %s of %s", member, priv, target))
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate role graph: %v", err)
	}

	if len(bridges) > 0 {
		t.Fatalf("role membership bridges found, want none in steady state: %v.\nEvery role in the post-#545 model is a member of nothing — see charts/postgres/templates/cluster.yaml. The only legitimate exception is beekeepingit's inRoles WHILE postgres.migratorTransition.enabled is on, which is a transition-only state this fixture does not model.", bridges)
	}
}

// TestMigratorIsolation_SchemaOwnerCannotReadTablesItDoesNotOwn pins the
// reasoning behind a decision that otherwise looks like an oversight: #545
// moves TABLE ownership to the per-schema migrators but deliberately leaves
// SCHEMA ownership with `beekeepingit`.
//
// The obvious objection is that this keeps a cross-schema principal around. It
// does — and it conveys nothing, because owning a schema is authority over the
// namespace, not over its contents. `beekeepingit` retains what
// schema-grants-job.yaml needs (a non-owner cannot `GRANT ... ON SCHEMA`, so
// moving ownership would break that Job for no gain) and nothing else.
//
// It can still DROP the schema, and CREATE new objects in it, both of which it
// could do anyway as the database owner — that is not what this bounds. What
// it bounds is reading and tampering with what is already there.
func TestMigratorIsolation_SchemaOwnerCannotReadTablesItDoesNotOwn(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()
	owner := f.connectAs(t, isoOwner)

	for _, tc := range []struct {
		what string
		stmt string
	}{
		{"read a migrator-owned audit_log", `SELECT count(*) FROM apiaries.audit_log`},
		{"tamper with a migrator-owned audit_log", `UPDATE apiaries.audit_log SET note = 'tampered'`},
		{"alter a migrator-owned table", `ALTER TABLE apiaries.audit_log ADD COLUMN sneaky TEXT`},
	} {
		t.Run(tc.what, func(t *testing.T) {
			if _, err := owner.Exec(ctx, tc.stmt); err == nil {
				t.Fatalf("%s (the SCHEMA owner) can %s: want a permission error, got success — if schema ownership now conveys access to its tables, leaving it with beekeepingit is no longer safe and ADR-0024's reasoning must be revisited",
					isoOwner, tc.what)
			}
		})
	}
}

// TestMigratorIsolation_RuntimeRoleKeepsAppendOnlyGuarantee re-proves #62's
// contract under the NEW wiring, which is #545's second acceptance criterion
// ("the append-only guarantee still holds afterwards"). audit_immutability
// _test.go proves it against the legacy fixture, where the runtime role once
// owned the table; here the owner is the schema's migrator and the runtime
// role never created anything, so immutability rests on nothing but the
// grants — which is the simpler and stronger position (ADR-0023 §2).
func TestMigratorIsolation_RuntimeRoleKeepsAppendOnlyGuarantee(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()

	// The service's own history table: append and read, never mutate.
	if _, err := f.aSvc.Exec(ctx, `INSERT INTO apiaries.audit_log (id, note) VALUES (gen_random_uuid(), 'ok')`); err != nil {
		t.Fatalf("%s_svc INSERT on its own audit_log: want success, got %v", isoSchemaA, err)
	}
	if _, err := f.aSvc.Exec(ctx, `SELECT count(*) FROM apiaries.audit_log`); err != nil {
		t.Fatalf("%s_svc SELECT on its own audit_log: want success, got %v", isoSchemaA, err)
	}
	for _, tc := range []struct{ what, stmt string }{
		{"UPDATE", `UPDATE apiaries.audit_log SET note = 'tampered'`},
		{"DELETE", `DELETE FROM apiaries.audit_log`},
		// TRUNCATE is the sharp one: an owner bypasses its ACL check
		// entirely, so this succeeding would mean the runtime role owns the
		// table after all.
		{"TRUNCATE", `TRUNCATE apiaries.audit_log`},
		{"DROP", `DROP TABLE apiaries.audit_log`},
		{"read the goose ledger", `SELECT count(*) FROM apiaries.goose_db_version`},
		{"create a table (CREATE was revoked on the schema)", `CREATE TABLE apiaries.svc_planted (id UUID PRIMARY KEY)`},
	} {
		t.Run(tc.what, func(t *testing.T) {
			if _, err := f.aSvc.Exec(ctx, tc.stmt); err == nil {
				t.Fatalf("%s_svc: %s on its own audit_log/schema — want a permission error, got success", isoSchemaA, tc.what)
			}
		})
	}

	// And it keeps full DML on its own DOMAIN tables — the narrowing in #545
	// applies to history and the ledger, not to the data the service serves.
	if _, err := f.aSvc.Exec(ctx, `INSERT INTO apiaries.things (id, note) VALUES (gen_random_uuid(), 'x')`); err != nil {
		t.Fatalf("%s_svc INSERT on its own domain table: want success, got %v", isoSchemaA, err)
	}
	if _, err := f.aSvc.Exec(ctx, `UPDATE apiaries.things SET note = 'y'`); err != nil {
		t.Fatalf("%s_svc UPDATE on its own domain table: want success, got %v", isoSchemaA, err)
	}
	if _, err := f.aSvc.Exec(ctx, `DELETE FROM apiaries.things`); err != nil {
		t.Fatalf("%s_svc DELETE on its own domain table: want success, got %v", isoSchemaA, err)
	}

	// The runtime role is confined to its own schema too. It always was —
	// `<schema>_svc` never had cross-schema grants, before or after #541 —
	// but asserting it here keeps the claim measured rather than remembered.
	if _, err := f.aSvc.Exec(ctx, `SELECT count(*) FROM organizations.things`); err == nil {
		t.Fatalf("%s_svc can read %s.things: want a permission error, got success", isoSchemaA, isoSchemaB)
	}
}

// TestMigratorIsolation_NewHistoryTableIsNeverMutable pins the #545 narrowing
// of `ALTER DEFAULT PRIVILEGES` from full DML to `SELECT, INSERT`.
//
// The bug it closes is an ordering one and easy to miss by reading the chart:
// migrations run at hook weight 2, table-grants at weight 3. Under the old
// full-DML default, a history table added by THIS release's migration was
// created already carrying UPDATE/DELETE for the runtime role, and stayed that
// way until weight 3 revoked it — a real window, on every release that adds a
// history table, while the outgoing ReplicaSet is serving live traffic
// (Helm applies Deployments before hooks, and this chart installs without
// `--wait`). Narrowing the default closes it by construction rather than by
// timing.
//
// The domain-table half is what makes the narrowing safe: a new domain table
// still reaches full DML, just at weight 3 instead of weight 2, on a table
// nothing has written to yet. (A new HISTORY table additionally needs its name
// in `postgres.historyTables` — charts/postgres/values.yaml, rendered into
// `postgres.runtimeGrantsPsqlArgs`'s REVOKE loop — exactly as audit_log and
// sync_conflict_log are today. The default privileges make it append-only from
// birth, the REVOKE keeps it that way once the blanket GRANT has run, and
// since #553 forgetting the list is a loud deploy failure, not a silently
// mutable table — see history_fail_closed_test.go.)
func TestMigratorIsolation_NewTableIsNeverMutableBeforeTableGrants(t *testing.T) {
	f := newMigratorIsolationFixture(t)
	ctx := context.Background()

	// A future migration adds a table (weight 2). No table-grants pass has
	// run since, so ALTER DEFAULT PRIVILEGES is the ONLY thing granting on it.
	if _, err := f.aMigrator.Exec(ctx, `CREATE TABLE apiaries.things_v2 (id UUID PRIMARY KEY, note TEXT NOT NULL)`); err != nil {
		t.Fatalf("create future table: %v", err)
	}
	if _, err := f.aMigrator.Exec(ctx, `INSERT INTO apiaries.things_v2 (id, note) VALUES (gen_random_uuid(), 'seed')`); err != nil {
		t.Fatalf("seed future table: %v", err)
	}

	if _, err := f.aSvc.Exec(ctx, `INSERT INTO apiaries.things_v2 (id, note) VALUES (gen_random_uuid(), 'ok')`); err != nil {
		t.Fatalf("%s_svc INSERT on a brand-new table: want success from ALTER DEFAULT PRIVILEGES, got %v", isoSchemaA, err)
	}
	if _, err := f.aSvc.Exec(ctx, `SELECT count(*) FROM apiaries.things_v2`); err != nil {
		t.Fatalf("%s_svc SELECT on a brand-new table: want success from ALTER DEFAULT PRIVILEGES, got %v", isoSchemaA, err)
	}
	if _, err := f.aSvc.Exec(ctx, `UPDATE apiaries.things_v2 SET note = 'tampered'`); err == nil {
		t.Fatalf("%s_svc can UPDATE a brand-new table before table-grants has run: want a permission error, got success — had this been a history table, that is the recurring audit-log window #545 closes by narrowing ALTER DEFAULT PRIVILEGES to SELECT, INSERT",
			isoSchemaA)
	}
	if _, err := f.aSvc.Exec(ctx, `DELETE FROM apiaries.things_v2`); err == nil {
		t.Fatalf("%s_svc can DELETE from a brand-new table before table-grants has run: want a permission error, got success", isoSchemaA)
	}

	// Weight 3 then grants full DML, which is what a new DOMAIN table needs —
	// so the narrowing costs the domain path nothing except its timing.
	applyRuntimeGrants(t, f.aMigrator, isoSchemaA)
	if _, err := f.aSvc.Exec(ctx, `UPDATE apiaries.things_v2 SET note = 'now allowed'`); err != nil {
		t.Fatalf("%s_svc UPDATE after table-grants: want success (a new DOMAIN table must reach full DML), got %v", isoSchemaA, err)
	}
	if _, err := f.aSvc.Exec(ctx, `DELETE FROM apiaries.things_v2`); err != nil {
		t.Fatalf("%s_svc DELETE after table-grants: want success, got %v", isoSchemaA, err)
	}
}
