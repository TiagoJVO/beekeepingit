# 0024 — Each schema gets its own `<schema>_migrator` owner role

- **Status:** Accepted
- **Date:** 2026-08-23
- **Issue / Epic:** #545 · raised by the security review of #541
- **Requirements:** NFR-SEC-1, FR-HIS-1, NFR-CMP-1
- **Decisions:** [D-6](../../requirements/decisions.md) (schema-per-service)
- **Amends:** [ADR-0023](0023-migrations-as-a-deploy-time-admin-process.md) §2 — the migrator and
  the runtime role stay different principals; the migrator stops being **one shared** principal.
  Resolves the corrected "Alternatives considered" entry that ADR left open.
- **Design:** [history.md](../architecture/history.md) §7.1,
  [platform.md](../architecture/platform.md), `infra/README.md` (transition runbook)

## Context

[ADR-0023](0023-migrations-as-a-deploy-time-admin-process.md) moved migrations out of the serving
process into a per-service, deploy-time Job. That Job authenticates as `beekeepingit` — the
database owner, which owns all seven schemas and was a member of every `<schema>_svc`.

**The Job runs the service's own application image.** Not a neutral migration image: the same
artifact that serves untrusted HTTP, `args: ["migrate"]` instead of the default entrypoint. So the
`identity` migrate Job holds full DDL and DML over `organizations`, `apiaries`, `activities` and
every other schema — including their `audit_log` tables, where **ownership bypasses the DML-only
restriction entirely**, taking the append-only guarantee with it.

Before ADR-0023 a compromised service was confined to its own schema: `<schema>_svc` had no
cross-schema grants at all. ADR-0023 widened that to "every schema" in exchange for fixing a defect
that was live and shipping, and recorded the trade honestly rather than pretending it cost nothing.
This ADR pays it back.

## Decision

### 1. One `<schema>_migrator` login role per schema, owning that schema's relations

`<schema>_migrator` is a plain `LOGIN` role and **a member of nothing**. It holds `USAGE, CREATE`
on its own schema and no privilege of any kind anywhere else. It **owns every relation in that
schema** — domain tables, `audit_log`, `sync_conflict_log`, indexes, and
`<schema>.goose_db_version`.

On a fresh install that ownership needs no separate step. The migrate Job connects as this role
with `DB_SEARCH_PATH=<schema>`, so goose creates its ledger and every table under it from the first
release onward.

`<schema>_svc` is unchanged — `USAGE` on the schema with `CREATE` revoked, DML on domain tables,
`INSERT`/`SELECT` only on history tables, owner of nothing, member of nothing — with one tightening:
it is also revoked everything on `<schema>.goose_db_version`. Nothing in the serving path has read
the goose ledger since ADR-0023, so that costs nothing.

The Secret name is **derived** from the service's schema in `charts/services/templates/
migrate-job.yaml` (`{{ $svc.db.schema }}-migrator-credentials`) and `db.migratorSecret` is deleted.
There is deliberately no per-service override: a service pointed at another schema's migrator
credential is precisely the bug this ADR removes, nothing would fail if someone wired it, so it is
made unrepresentable rather than documented as a footgun.

### 2. `beekeepingit` keeps schema ownership, and that is not an oversight

It stays the database owner and the owner of all seven **schemas**, because
`schema-grants-job.yaml` has to `GRANT ... ON SCHEMA` and a non-owner cannot. It is never again a
migrate Job's credential.

Handing schema ownership to the migrators as well would break that Job and buy nothing: **a
schema's owner cannot read or alter a table it does not own.** Owning a schema is authority over
the namespace, not over its contents. This is asserted rather than assumed —
`TestMigratorIsolation_SchemaOwnerCannotReadTablesItDoesNotOwn` fails if a future Postgres changes
it.

Its `managed.roles.inRoles` list is **dropped in steady state**. Nothing `beekeepingit` does now
requires the privileges of another role, and a standing membership in all seven `<schema>_svc`
roles was itself the cross-schema bridge this ADR deletes.

### 3. Hook ordering

```text
0  schema-grants        beekeepingit    powersync DB grant, then schema USAGE/CREATE
1  migrator-adopt (x7)  beekeepingit    [gated] ownership transition, one tx per schema
2  <service>-migrate    <schema>_migrator   migrations, owning what they create
3  table-grants (x7)    <schema>_migrator   DML grants, history + ledger revokes, one tx
```

`schema-grants` moves from weight 1 to **0** to free a slot, and its `powersync` database grant
stays the first thing it does. That grant gates PowerSync's rollout and must remain free of any
dependency on migrations — ADR-0023 §3's rule, learned from the ~55-minute retry incident.

`table-grants` becomes seven Jobs because its credential is now per-schema and comes from a
`secretKeyRef`. The cost is six extra short-lived pods per release. The benefit is that the last
shared cross-schema credential leaves the weight-3 hook. All fourteen new pods keep
`app.kubernetes.io/name: postgres`, so the existing `postgres-jobs-to-postgres` NetworkPolicy edge
covers them; a new pod identity with no edge cannot reach Postgres under default-deny, which this
repo has been bitten by on activities, journeys, todos and ADR-0023's own migrate Jobs.

`ALTER DEFAULT PRIVILEGES ... ON TABLES` is narrowed from full DML to **`SELECT, INSERT`**. Under
the old default, a history table created by this release's migration (weight 2) was fully mutable
by the runtime role until the REVOKE landed at weight 3 — a real window, on every release that adds
one, while the outgoing ReplicaSet is serving. Narrowing closes it by construction. A new _domain_
table still reaches full DML at weight 3 via the blanket GRANT, on a table nothing has written to
yet.

> **Update (#553).** The REVOKE half of that weight-3 pass originally keyed on two table names
> written literally into the template, which was fail-open in steady state: a future history table
> under a third name kept the blanket DML silently, forever, and nothing in CI noticed. The list
> now lives in chart values (`postgres.historyTables`, one central definition still shared by both
> Jobs via `postgres.runtimeGrantsPsqlArgs`), and the shared DO block gained a fail-closed guard:
> any table whose name ends `_log` that the list does not classify raises an exception, failing the
> release with the table's name — inside the same transaction as the blanket GRANT, so the table is
> never mutable even on the failed release. The `_log` suffix is thereby reserved for append-only
> history; a mis-suffixed domain table fails the deploy until renamed or classified. Proven in
> `services/shared/dbaccess/history_fail_closed_test.go`.

### 4. Existing clusters transition through a gated, one-off Job

`postgres.migratorTransition.enabled` (default **false**) renders `migrator-adopt-job.yaml` and
gives `beekeepingit` `inRoles: [<schema>_migrator, ...]`. Fresh installs never need it. Runbook:
`infra/README.md`.

Four constraints shape that Job, each of which was a way to get this wrong:

- **Never `REASSIGN OWNED BY beekeepingit`.** It is database-wide, and `beekeepingit` owns all
  seven schemas plus the databases — one statement would hand a single service's migrator
  everything. It is a one-word mistake that succeeds and leaves the cluster looking fine. The Job
  uses a per-relation `ALTER ... OWNER TO` loop over `pg_class` filtered by `relnamespace`, which
  is incapable of reaching outside the schema it was given.
- **Fail on object kinds the loop cannot move.** Functions and standalone types live in `pg_proc`
  and `pg_type`, so a `pg_class` loop leaves them owned by `beekeepingit` silently. None exist
  today; the guard keeps that true instead of discovering it later.
- **One transaction per schema.** Helm applies Deployments before hooks and this chart installs
  without `--wait`, so the outgoing ReplicaSet serves as `<schema>_svc` throughout. Between the
  REVOKE and the re-GRANT the role holds nothing; between the blanket GRANT and the history REVOKE
  it holds `UPDATE`/`DELETE` on `audit_log`. Neither may be observable. This is the same control
  `table-grants-job.yaml` documents, for the same incident.
- **REVOKE as `beekeepingit`, re-GRANT as the new owner.** On an existing cluster `<schema>_svc`'s
  privileges were granted BY `beekeepingit`. Measured on PostgreSQL 16 and 18, `ALTER ... OWNER TO`
  _does_ rewrite grantor references, so revoking as the new owner would in fact work today — but
  that is not documented as a guarantee, and if it ever stopped holding, a revoke by the new owner
  would match nothing, remove nothing, return success, and leave the audit log mutable while the
  Job reported a clean transition. Revoking as `beekeepingit` is correct under both behaviours for
  the cost of one statement in a transaction that already exists.
  `TestMigratorTransition_AlterOwnerRewritesGrantorReferences` is the tripwire if it changes.

`ALTER DEFAULT PRIVILEGES FOR ROLE beekeepingit ... REVOKE` is in the same Job for a harder reason:
that statement requires membership in `beekeepingit`, which `<schema>_migrator` does not have and
must never have. Only `beekeepingit` can clean up its own `pg_default_acl` rows, and left behind
they keep granting full DML on every table a future migration creates — from a grantor nothing in
the steady state can revoke.

**During a transition release, isolation is temporarily off.** `beekeepingit` is a member of every
migrator role for the duration. Per-schema isolation is a **steady-state** property, not an
every-instant one. Turning the flag back off genuinely removes the memberships — CNPG's role
reconciler diffs the declared `inRoles` against `pg_auth_members` and issues the `REVOKE` — so no
manual cleanup is owed, but leaving it on is not harmless.

**The transition requires ADR-0023's release to have been deployed first.** Flipping the flag
swaps `beekeepingit`'s `<schema>_svc` memberships for the migrator ones, so relations still owned
by `<schema>_svc` (a cluster that never deployed ADR-0023) become unreachable. The Job checks for
this up front and fails the release naming the offending relations, rather than emitting a bare
`must be owner of table`.

## Consequences

- **A compromised service image is confined to its own schema again**, as it was before ADR-0023 —
  including that schema's `audit_log`. This is the acceptance criterion of #545 and it is proven
  negatively in `services/shared/dbaccess/migrator_isolation_test.go`, against a two-schema
  fixture, with a positive control so the negatives cannot pass on a broken fixture.
- **It is a narrowing, not a closure, and this ADR will not pretend otherwise.** The migrate Job
  still runs the service's own image with an owner credential for its own schema, and the
  migration SQL ships **inside that image** — so a malicious `.sql` file is as good as a malicious
  binary against that one schema, including its audit log. That cannot be closed within this
  design. Running migrations from a neutral image buys nothing (the SQL still comes from the
  service's repo and must be applied by a role that owns the tables), and keeping history tables
  under a role the image never holds recreates ADR-0023's deadlock exactly — `audit_log.actor_scope`
  (#470) is the forcing counterexample: a migration that must alter the audit log, run by something
  that must not be able to alter the audit log.

  The correct framing, and the one `history.md` §7.1 now carries: **append-only is a guarantee
  against the service's runtime role, not against its deploy artifact.** Closing the latter needs
  an out-of-band append-only sink — WAL archive, or an external WORM store — which is EPIC-14
  territory, not a chart change.

- **`helm rollback` does not work across this change.** The pre-#545 `table-grants` Job connects as
  `beekeepingit` and issues `GRANT ... ON ALL TABLES`, which a non-owner cannot do once ownership
  has moved, so the rollback release's weight-3 hook fails. Recovery is forward-only, or via a
  reverse adopt run — the SQL for which is in `infra/README.md`.
- **Seven more Secrets and seven more managed roles**, plus six extra Jobs per release. This is the
  "strictly more moving parts" ADR-0023 weighed and, at the time, priced as buying nothing. The
  parts are real; the isolation is too.
- **A migrator role exists for schemas with no service yet** (`ai`, and each schema before its
  service ships). CNPG reconciles roles from the declared list, not from what is deployed, and an
  unused login role with `USAGE, CREATE` on one empty schema conveys nothing until someone holds
  its credential.
- **`beekeepingit` still exists and is still powerful** — database owner, schema owner, and the
  principal for `schema-grants` and the gated adopt Job. What changed is that its credential is no
  longer mounted into any pod running application code.

## Alternatives considered

- **Keep the shared owner and restrict at the network/RBAC layer.** Rejected: the credential grants
  what it grants once the pod holds it. A NetworkPolicy cannot stop a pod that legitimately reaches
  Postgres from issuing `DROP TABLE organizations.audit_log`.
- **Accept the widened radius explicitly and document it.** Defensible, and it was the status quo.
  Rejected because the cost of the alternative turned out to be seven Secrets and a gated
  transition Job, not an architecture change — a price worth paying for a property (`FR-HIS-1`,
  `NFR-CMP-1`) that a compliance conversation will eventually be held to.
- **Move schema ownership to the migrators too.** Rejected: it breaks `schema-grants-job.yaml` (a
  non-owner cannot `GRANT ... ON SCHEMA`) and buys nothing, since schema ownership conveys no
  access to tables owned by others. See §2.
- **`REASSIGN OWNED BY` for the transition.** Rejected as actively dangerous — see §4.
- **A dedicated, neutral migration image** holding the migrator credential instead of the service
  image. Rejected: the migration `.sql` files ship from the service's own repository and are
  applied by a role that owns its tables either way, so the artifact boundary moves without the
  authority boundary moving. It adds a build target and changes nothing about what a malicious
  migration can do.
