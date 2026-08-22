# 0023 — Migrations run as a deploy-time admin process, not at service startup

- **Status:** Accepted
- **Date:** 2026-08-22
- **Issue / Epic:** #541 · caused by the interaction of #62 and #470
- **Requirements:** NFR-SEC-1, NFR-MNT-1, FR-HIS-1
- **Decisions:** [D-6](../../requirements/decisions.md) (schema-per-service),
  [D-27](../../requirements/decisions.md) (release-triggered deploy)
- **Amends:** [ADR-0007](0007-history-audit-append-only-per-service-in-transaction-capture.md) §4 —
  the append-only guarantee is unchanged, but the mechanism that enforces it is replaced
- **Design:** [history.md](../architecture/history.md) §7.1,
  [platform.md](../architecture/platform.md)

## Context

Two decisions were individually sound and jointly impossible.

**ADR-0007 §4 / #62** requires the audit trail to be append-only: the service runtime role has
`INSERT`/`SELECT` on `audit_log` and `sync_conflict_log`, but not `UPDATE`/`DELETE`. A plain
`REVOKE` cannot achieve that against a table's owner — an owner can re-`GRANT` to itself at will
and retains `TRUNCATE`/`ALTER`/`DROP` regardless. So #62 moved ownership off the runtime role,
onto the `beekeepingit` app owner, via a post-install Helm Job.

**Migrations, meanwhile, ran at pod startup** inside the serving process, using the service's own
runtime role — `dbaccess.Migrate` called from each `main.go` with `cfg.DB.DSN()`.

Postgres requires table **ownership** for `ALTER TABLE`; it is not a grantable privilege. So once
#62's job had run, the service could never migrate its own history table again. The two
requirements are mutually exclusive: a role that may migrate a table may also drop it.

This was not a latent risk — it shipped. `v0.0.1-rc8` carried organizations migration `00005`
(#470, adding `audit_log.actor_scope`), which failed with `must be owner of table audit_log`
(SQLSTATE 42501) and crashlooped **7113 times over 25 days** on staging. The previous ReplicaSet
kept serving throughout, so `/api/organizations/healthz` returned 200 the whole time and nothing
alerted. Staging silently ran split versions for 25 days.

**Why CI never caught it.** On a fresh cluster every migration runs at pod startup _before_ the
lockdown hook has ever applied, so versions 1..N all succeed. The bug requires a cluster where a
_previous_ deploy already locked the table and a _later_ migration then arrives — an ordering that
no fresh-install test can produce.

## Decision

### 1. Migrations become a deploy-time admin process

Each service binary gains a `migrate` subcommand (12-factor XII, admin processes). The serving
path performs no DDL at all. `ENTRYPOINT` is unchanged, so the Job passes `args: ["migrate"]` —
no separate image, no Dockerfile change.

`config.LoadDB` loads only database settings. `config.Load` would reject a migration Job with
`OIDC_ISSUER_URL is required`, and giving that job OIDC credentials it never uses would recreate
the over-provisioning this split exists to remove.

### 2. The migrator and the runtime role are different principals

`beekeepingit` runs migrations and owns every table from creation. `<schema>_svc` gets `USAGE` on
the schema (`CREATE` revoked), DML on domain tables, and `INSERT`/`SELECT` only on history tables.

This is the part that makes the whole problem dissolve rather than move: **because the runtime
role never creates a table, it never owns one, so there is nothing to take away.** Immutability
reduces to not granting `UPDATE`/`DELETE`. The role cannot self-`GRANT` its way back in — Postgres
silently no-ops a `GRANT` of a privilege the grantor does not hold — and it is never a member of
`beekeepingit` (only the reverse membership is granted, via CNPG's `managed.roles.inRoles`).

`audit-immutability-job.yaml` is therefore **deleted**, not relocated. Its per-table polling goes
with it: that polling existed only because a Helm hook could not sequence itself against
pod-startup migrations, and now it can.

### 3. Hook ordering is the design

```text
1  schema-grants-job     schema USAGE + the powersync database grant
2  <service>-migrate     migrations, as the migrator/owner role
3  table-grants-job      table DML grants, history-table REVOKEs, ownership transition
```

Weight 1 is deliberately kept free of any dependency on migrations. It gates PowerSync's rollout
and must stay fast and predictable — putting migrations ahead of it would let a slow or stuck
migration stall PowerSync, which is the exact failure shape behind the ~55-minute retry incident
recorded in the deleted job. Only table-level grants, which genuinely cannot run before the tables
exist, move behind migrations.

**`post-install`/`post-upgrade`, not `pre-install`:** on a first install the Postgres cluster is
itself one of this release's resources, so a `pre-install` hook would have nothing to connect to.

### 4. Existing clusters transition in place

`REASSIGN OWNED BY <schema>_svc TO beekeepingit` adopts tables the old startup-migration path left
behind. Fresh installs no-op. No goose ledger surgery is needed: Postgres satisfies the ownership
check through inherited membership, so the migrate Job can alter a legacy `<schema>_svc`-owned
table and write its `<schema>_svc`-owned ledger without any prior step — verified in
`services/shared/dbaccess/migration_ownership_test.go`.

### 5. Migrations are squashed into a per-service baseline

Each service's migrations collapse into a single `0000N_baseline.sql`, so a fresh database gets
the final shape in one step instead of replaying create-then-alter.

**Numbered at the then-current max, not `00001`.** goose applies any version above the database's
max, so a baseline sitting exactly at that max is a no-op on an already-migrated cluster while a
fresh database applies it and lands on the _same version number_. Both end with identical schema
and identical ledger state. Numbering it `00001` would strand fresh and existing clusters on
different versions permanently.

**Generated, not hand-written.** The baselines come from `pg_dump --schema-only` run against a
database migrated by the real migration files. A hand-written baseline is precisely how a fresh
database and a long-lived one drift apart. goose's own `goose_db_version` and `CREATE SCHEMA` are
stripped — goose owns its ledger, infra owns schemas.

**The hard constraint:** a baseline may only be cut when _every_ live environment is at or above
its version, otherwise goose will try to apply it over tables that already exist. Verified before
cutting these: staging was at exactly the file max for all six services. The local k3d dev cluster
was behind (organizations at 4) and must be recreated rather than upgraded — it is disposable,
which is the only reason this was acceptable.

Baselines have **no Down section**. There is no meaningful target to migrate down to past a
squash, and the steps that would be unwound no longer exist.

Honest scoping note: at 26 migrations across six services this buys very little today. It was
done because the replay path was going to keep growing and the constraint above only gets harder
to satisfy as more environments appear — not because fresh installs were slow.

## Consequences

- The runtime credential no longer carries DDL. A compromised service can no longer `DROP` or
  `ALTER` — a least-privilege improvement independent of the bug that prompted it.
- A failed migration now fails the Helm release rather than crashlooping a pod behind a healthy
  older ReplicaSet. The specific way this bug hid itself is closed.
- Services no longer self-bootstrap their schema. A service pod started against an unmigrated
  database will serve errors rather than fixing itself. This is intended — the deploy is
  responsible for schema state — but it means the migrate Job failing is now a deploy-blocking
  event, which is the point.
- Migrations are coupled to the deploy rather than the process, so expand/contract
  (Fowler's _ParallelChange_) becomes the required discipline for breaking schema changes.
- **On an upgrade, the rollout races the hooks.** Helm applies the release's Deployments before
  running `post-install`/`post-upgrade` hooks, and this chart is installed without `--wait`
  (see `infra/README.md`). So a new-version pod can pass `/readyz` — which checks DB connectivity,
  never migration state — and start taking traffic while the migrate Job is still running. If that
  pod's code needs this deploy's schema change, requests 5xx for those few seconds. This is why the
  expand/contract discipline above is a requirement rather than a preference, and it is the reason
  it is stated as one. Note it is a far weaker version of the failure this ADR fixes: bounded to
  seconds instead of 25 days, and it fails loudly per-request instead of hiding behind a green
  health check. Closing it entirely would mean either a migration-aware readiness check or gating
  the rollout on hook completion; neither is done here.
- `services/*/store/sqlc/schema.sql` remains sqlc codegen input only and is **not** a bootstrap
  baseline — it is never applied to a database. Its header used to name the individual migration
  files it mirrored; those no longer exist, so each now points at the baseline instead. Drift
  between the two surfaces as wrong generated Go types, not as a failed migration.
- Re-cutting a baseline is now a release-coordination step, not a refactor: it requires knowing
  every live environment's goose version first. Recorded in `FOLLOWUPS.md` so the constraint
  survives this PR.

## Alternatives considered

- **Pre-upgrade unlock Job** — hand ownership back to `<schema>_svc` for the duration of the
  deploy, then re-lock. Smallest change, mirrors the existing job. Rejected: it reopens an
  `UPDATE`/`DELETE` window on the audit trail on _every_ upgrade, and makes correctness depend on
  migrations finishing inside that window. It times around the conflict instead of removing it.
- **`SECURITY DEFINER` helper** owned by `beekeepingit`, executable by the runtime role. Rejected:
  every new DDL shape needs a new helper, and any loosening of its scope becomes a
  privilege-escalation path — a standing hazard in exchange for avoiding a one-time restructure.
- **Per-service `<schema>_migrator` role** owning that service's tables. Initially rejected here as
  more moving parts than reusing `beekeepingit`, "for no additional isolation".

  > **That rejection was wrong on the isolation point, and is corrected here.** The security review
  > of this change established that it _does_ buy isolation, and materially. `beekeepingit` owns
  > every schema and is a member of every `<schema>_svc`, and each migrate Job runs **the service's
  > own application image** — the same artifact that serves untrusted HTTP. So compromising any one
  > service image yields database-owner reach over _every other_ service's schema and `audit_log`,
  > where ownership bypasses the DML-only restriction entirely. Before this ADR, a compromised
  > service was confined to its own schema.
  >
  > This is now tracked as [#545](https://github.com/TiagoJVO/beekeepingit/issues/545) and is a
  > genuine open trade-off, not a settled one. It was not treated as blocking this change: the
  > defect this ADR fixes was live and shipping, and the widened blast radius is a knowingly
  > accepted cost rather than a regression from a previously-safe state — but it should not be left
  > recorded as though it cost nothing.

- **Keeping startup migrations and dropping #62's guarantee.** Rejected: the append-only audit
  trail is a compliance-facing property (`FR-HIS-1`, `NFR-CMP-1`), not a nice-to-have.
