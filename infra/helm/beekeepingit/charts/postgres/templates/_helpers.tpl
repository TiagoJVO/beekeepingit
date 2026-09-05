{{- define "postgres.fullname" -}}
{{- printf "%s-postgres" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
postgres.runtimeGrantsPsqlArgs — the steady-state runtime ACL for ONE schema,
rendered as `psql -c` arguments. Takes a dict as its context:
  schema        — the schema name
  historyTables — .Values.historyTables, the append-only classification list

WHY THIS IS SHARED RATHER THAN WRITTEN TWICE. Exactly two Jobs establish this
ACL and they must produce a byte-identical end state:

  - table-grants-job.yaml (hook weight 3) — every release, connected AS
    `<schema>_migrator`, which owns every relation in the schema.
  - migrator-adopt-job.yaml (hook weight 1, gated) — the one-off #545
    transition, connected as `beekeepingit` and running this AFTER a
    `SET LOCAL ROLE <schema>_migrator`, so `current_user` is the same role and
    these statements mean the same thing in both places.

If the two ever drifted, a transitioned cluster would sit on a different ACL
than a fresh one until the next release quietly corrected it — and the
difference would be in the audit log's grants, which is the one place this repo
cannot afford a silent divergence (history.md §7.1). Hence one definition.

Every statement is idempotent and safe to re-run on each `helm upgrade`. A
schema whose service has not shipped yet simply has no tables and every
statement degrades to a no-op.

THE `ALTER DEFAULT PRIVILEGES` GRANT IS `SELECT, INSERT` — NOT FULL DML — AND
THAT NARROWING IS DELIBERATE (#545). It used to grant SELECT/INSERT/UPDATE/
DELETE, which meant a history table created by a FUTURE migration was fully
mutable by the runtime role from the moment it was created (weight 2) until
this Job's REVOKE landed (weight 3) — a real, recurring window on exactly the
table history.md §7.1 exists to protect, opened by every release that adds one.
With `SELECT, INSERT` as the default, a brand-new history table is never
mutable at any instant, and a brand-new DOMAIN table still reaches full DML at
weight 3 via the blanket GRANT below — the same release, seconds later, and on
a table nothing has written to yet.

THE LEDGER REVOKE (`<schema>.goose_db_version`) is new in #545 and is free:
since #541 nothing in the serving path reads the goose ledger, so the runtime
role has no reason to hold anything on it. Scoped to the TABLE only — its
`serial` sequence keeps the blanket USAGE/SELECT, because a sequence grant
conveys nothing about the table's rows and hunting it down through `pg_depend`
would be SQL spent on no threat.

Grant-then-revoke, rather than enumerating the domain tables to grant: the set
of history/ledger tables is small, fixed and known, while the domain tables are
not. A missed REVOKE fails loudly in
services/shared/dbaccess/audit_immutability_test.go, whereas a missed GRANT
would fail silently at runtime.

THE REVOKE LIST IS `.Values.historyTables`, AND UNCLASSIFIED `*_log` TABLES
FAIL THE RELEASE (#553). The list used to be two literal names inlined here,
which was a fail-open edge: a future history table under a third name would
keep the full DML the blanket GRANT above hands it, silently, forever — the
safe outcome depended on a developer remembering to edit an infra file when
adding a table in a service repo, and nothing in CI noticed when they did not.
#545 narrowed half of it (`ALTER DEFAULT PRIVILEGES` no longer makes such a
table mutable at creation) but left the steady state open. Two things close it:

  - The list moved to charts/postgres/values.yaml (`historyTables`), still one
    central definition for every schema — history tables are deliberately
    uniform across schemas (history.md §5) — and still shared by both callers
    of this helper, so fresh and transitioned clusters cannot drift.
  - The DO block below ends with a GUARD: any table in the schema whose name
    ends `_log` (the naming convention every history table follows — audit_log,
    sync_conflict_log) that is NOT in the list RAISEs an EXCEPTION naming it.
    That aborts psql with a script error (measured: exit 1 for a failed `-c`
    command under ON_ERROR_STOP — not the connection code 2 either way), which
    the table-grants retry loop deliberately does NOT retry, so the release
    fails on the first attempt with the table's name in the log. And because
    the callers wrap this in `--single-transaction`, the abort also rolls back
    the blanket GRANT — the unclassified table is never mutable, not even for
    the seconds a failed release lingers. Deploy-time error, never a silent
    privilege.

    The pattern is fixed here rather than configurable: a values overlay that
    could widen or drop it would be a per-environment hole in a guard whose
    whole point is that it cannot be forgotten. What remains honest to say is
    that a history table named WITHOUT the `_log` suffix evades the guard and
    lands back on the list being edited by hand — the guard enforces the
    naming convention and the list classifies, so the failure mode left is
    "broke the convention AND forgot the list", not "forgot the list".

The callers wrap this in `--single-transaction` so no session ever observes the
intermediate state — see table-grants-job.yaml's header for why that is a
security control and not a tidiness preference.
*/}}
{{- define "postgres.runtimeGrantsPsqlArgs" -}}
{{- $schema := .schema -}}
{{- $historyTables := .historyTables -}}
{{- if not $historyTables -}}
{{- fail "postgres.historyTables must be a non-empty list (charts/postgres/values.yaml) — an empty list would mean no history table is ever revoked and every *_log table trips the #553 guard, which is never the intent" -}}
{{- end -}}
{{- range $t := $historyTables -}}
{{- if not (regexMatch "^[a-z][a-z0-9_]*$" $t) -}}
{{- fail (printf "postgres.historyTables entry %q is not a plain lower-case identifier — these names are interpolated into SQL string literals, so anything else fails the render rather than the deploy (#553)" $t) -}}
{{- end -}}
{{- end -}}
-c "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA {{ $schema }} TO {{ $schema }}_svc;" \
-c "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA {{ $schema }} TO {{ $schema }}_svc;" \
-c "ALTER DEFAULT PRIVILEGES FOR ROLE {{ $schema }}_migrator IN SCHEMA {{ $schema }} GRANT SELECT, INSERT ON TABLES TO {{ $schema }}_svc;" \
-c "ALTER DEFAULT PRIVILEGES FOR ROLE {{ $schema }}_migrator IN SCHEMA {{ $schema }} GRANT USAGE, SELECT ON SEQUENCES TO {{ $schema }}_svc;" \
-c "DO \$do\$
    DECLARE
      history_tables CONSTANT text[] :=
        ARRAY[{{ range $i, $t := $historyTables }}{{ if $i }}, {{ end }}'{{ $t }}'{{ end }}]::text[];
      t text;
      unclassified text;
    BEGIN
      FOREACH t IN ARRAY history_tables LOOP
        IF EXISTS (SELECT 1 FROM pg_tables
                   WHERE schemaname = '{{ $schema }}' AND tablename = t) THEN
          EXECUTE format('REVOKE UPDATE, DELETE, TRUNCATE ON %I.%I FROM %I',
                         '{{ $schema }}', t, '{{ $schema }}_svc');
          RAISE NOTICE '%.%: append-only (INSERT/SELECT only for %)',
                       '{{ $schema }}', t, '{{ $schema }}_svc';
        END IF;
      END LOOP;
      IF EXISTS (SELECT 1 FROM pg_tables
                 WHERE schemaname = '{{ $schema }}' AND tablename = 'goose_db_version') THEN
        EXECUTE format('REVOKE ALL ON %I.%I FROM %I',
                       '{{ $schema }}', 'goose_db_version', '{{ $schema }}_svc');
        RAISE NOTICE '%.goose_db_version: no runtime access for %',
                     '{{ $schema }}', '{{ $schema }}_svc';
      END IF;
      -- FAIL-CLOSED GUARD (#553): a table named like a history table that this
      -- release cannot classify fails the release, in this transaction, so the
      -- blanket GRANT above rolls back with it and the table is never mutable.
      -- lower() so a quoted mixed-case name cannot slip past the pattern while
      -- also failing to match the (lower-case) list.
      SELECT string_agg(tablename, ', ' ORDER BY tablename) INTO unclassified
        FROM pg_tables
       WHERE schemaname = '{{ $schema }}'
         AND lower(tablename) LIKE '%\_log'
         AND NOT tablename = ANY (history_tables);
      IF unclassified IS NOT NULL THEN
        RAISE EXCEPTION '%: unclassified history-style table(s): %. Fail-closed (#553): the blanket DML GRANT would hand these UPDATE/DELETE, so this transaction aborts instead. If it is a history table, add it to postgres.historyTables (charts/postgres/values.yaml); if it is a domain table, rename it — the _log suffix is reserved for append-only history (history.md §7.1).',
                        '{{ $schema }}', unclassified;
      END IF;
    END
    \$do\$;"
{{- end -}}

{{/*
postgres.waitForRoleShellFn — a `wait_for_role` shell function for the Jobs
that run before CNPG has necessarily reconciled `spec.managed.roles`.

WHY THIS IS NOT `until psql ...; do sleep 5; done`. That was the previous shape
here, and it cannot tell "the operator has not reconciled this role yet" from
"this statement is permanently denied" — so a permission error is retried until
`activeDeadlineSeconds` kills the Job and the release fails with a
DeadlineExceeded that says nothing about the actual cause. That is not
hypothetical: schema-grants shipped once with a `GRANT <schema>_svc TO
beekeepingit` inside such a loop, which Postgres rejects outright (a plain login
role has neither CREATEROLE nor ADMIN OPTION), and CI's live k3d/helm-e2e run
spun for the full 300s before dying — run 29146587211, #62. The lesson was
recorded in that Job's comment and then not applied to the loop itself.

The fix is to separate the two questions. Poll ONLY the precondition that is
legitimately async — "does the role exist / am I a member of it yet" — as a
plain boolean SELECT that cannot fail for permission reasons, with a bounded
budget and a loud message when it runs out. Then run the real statements ONCE,
under `ON_ERROR_STOP=1`, so a permission error fails the Job immediately with
the actual Postgres error in the log.

A failed `psql` inside the `$(...)` condition (Postgres not up yet, connection
refused) yields an empty string, which is simply "not ready" — so server
start-up is still tolerated by the same loop, which is the other thing the
original blind retry was legitimately doing.

THE BUDGET IS ONE DEADLINE FOR THE WHOLE WAIT, NOT ONE PER CALL (#551). Every
wait_for_role call in a script is waiting on the same single event — CNPG's
operator reconciling spec.managed.roles — so a slow reconciliation must not
get its budget multiplied by however many schemas happen to be listed in
values.yaml. The clock starts when the script starts, so image pull is
excluded by construction, and on giving up the probe is re-run with stderr
attached so the failing psql output — not a bare deadline — is the last thing
in the log. The caller's activeDeadlineSeconds is a backstop above this, not
the budget.
*/}}
{{- define "postgres.waitForRoleShellFn" -}}
# ONE deadline shared by every wait_for_role call below (#551): the clock
# starts here, when the script starts — after image pull, which gets charged
# to nothing.
wait_budget=300
wait_deadline=$(( $(date +%s) + wait_budget ))

# wait_for_role <sql-boolean-predicate> <description>
# Polls a predicate that must become true once CNPG reconciles managed.roles.
wait_for_role() {
  predicate="$1"
  description="$2"
  until [ "$(psql -tAX -c "SELECT 1 WHERE ${predicate}" 2>/dev/null)" = "1" ]; do
    if [ "$(date +%s)" -ge "${wait_deadline}" ]; then
      echo "FATAL: ${description} still not true after ${wait_budget}s of WAITING (image pull excluded, #551)." >&2
      echo "CNPG has not reconciled spec.managed.roles, or the cluster is unreachable." >&2
      echo "The probe's own output below is the real state, not a readiness delay:" >&2
      psql -tAX -c "SELECT 1 WHERE ${predicate}" >&2 || true
      echo "Failing now rather than retrying to the activeDeadlineSeconds (see #62, #551)." >&2
      exit 1
    fi
    echo "${description}: not ready yet, retrying in 5s..."
    sleep 5
  done
}
{{- end -}}
