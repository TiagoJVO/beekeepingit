# services/journeys

The **journeys** service — owner of journey records
([#45](https://github.com/TiagoJVO/beekeepingit/issues/45), EPIC-04, M4). It
owns the `journeys.journeys`, `journeys.journey_plan_items`,
`journeys.sync_conflict_log` and `journeys.audit_log` tables
(`docs/architecture/service-decomposition.md` §3/§4) and this service's own
small main-activity-type/status registry (`api/types.go`).

A **journey** aggregates seasonal work across apiaries (FR-JO-4): a name, one
main activity type (D-21 narrows FR-JO-4 to a single main activity type per
journey — a manual per-apiary planned-activity-type list is an explicitly
deferred future extension), the set of apiaries to visit (the "plan"), and a
lifecycle status — **open** (selectable and auto-matched by default in the
activity-form picker, [#46](https://github.com/TiagoJVO/beekeepingit/issues/46))
or **closed** (hidden by default there, but still selectable with a
confirm-to-proceed warning). Unlike activities'/apiaries' own #38→#39 split,
this story ships the **full** CRUD surface (create, edit including the plan
replace, close, delete) in one go — `api/write.go`'s REST routes and
`api/sync.go`'s internal sync validate/apply endpoints, exactly mirroring
their combined shape.

Stamped from [`services/servicetemplate`](../servicetemplate/README.md); DB
access via [`services/shared/dbaccess`](../shared/README.md). Its own Go
module, linked through the repo-root `go.work`.

## Data model (FR-JO-4, FR-TEN-2)

`journeys.journeys`: `id`, `organization_id` (NOT NULL, tenancy), `name`,
`main_activity_type` (extensible, validated in Go against this service's own
hand-kept mirror of `services/activities/api/types.go`'s registry — see
`api/types.go`'s doc comment for why this is a mirror, not an import),
`status` (`open`|`closed`, D-21, extensible-enum-as-text like `main_activity_type`
— not a fixed boolean), and the usual audit/tombstone columns
(`created_at`/`updated_at`/`recorded_at`/`deleted_at`).

`journeys.journey_plan_items`: the "apiaries to visit" plan — `id`,
`organization_id`, `journey_id` (FK, same schema), `apiary_id` (a
**cross-service soft reference** — no FK, per
`docs/architecture/service-decomposition.md` §4 rule 2 — verified against the
apiaries service itself, see below), `created_at`, `deleted_at` (its own soft
tombstone — an apiary removed from the plan, then re-added, is a fresh row
rather than an "undelete", so it never collides with its own tombstoned
predecessor under the table's partial unique index on `(journey_id,
apiary_id) WHERE deleted_at IS NULL`). Unlike `apiaries.apiary_counters`
(upsert-keyed by `(apiary_id, counter_type)`, no delete op), a plan item's
`id` is a real, stable, client-generated identity shared by client and
server — like `activities.activities`' own convention — so removing an
apiary from the plan is a plain idempotent tombstone-by-id, with no
composite-key enrichment of the queued delete op needed.

### Journey attribution (D-21)

An activity carries the attribution link, **not** this schema: a **stored,
nullable `activities.journey_id`** column (already present in
`services/activities/store/migrations/00001_create_activities.sql`, wired by
[#46](https://github.com/TiagoJVO/beekeepingit/issues/46)'s activity-form
picker — see `services/activities/README.md`'s own "Cross-service journey
ownership" section) — this is a deliberate, already-confirmed decision
(D-21, supersedes the pre-D-21 idea of a `journeys`-owned
`journey_activities` link table, `docs/architecture/data-model.md` §7). This
service therefore never writes to the `activities` schema (ownership rule

1. and doesn't need to know which activities are attributed to a given
   journey to satisfy this story's own acceptance criteria. It does, however,
   now serve as the **verification target** for that link: activities'
   `JourneyVerifier` (`services/activities/api/journeys_client.go`) confirms a
   client-supplied `journey_id` belongs to the caller's org by calling this
   service's own `GET /v1/journeys/{id}` below — the same "ask the owning
   service" pattern `services/apiaries`' `getApiary` already serves for
   `apiary_id`.

## Surface

| Route                          | Auth                 | Purpose                                                                                                                                                                                                                                                                                                                  |
| ------------------------------ | -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `GET /v1/journeys/{id}`        | OIDC JWT + org scope | Fetch a single journey by id (including its current live plan). Org-scoped; a journey belonging to a different org 404s, indistinguishable from a nonexistent id (ADR-0002 scope-hiding) — also the target activities' `JourneyVerifier` calls ([#46](https://github.com/TiagoJVO/beekeepingit/issues/46)). 200, or 404. |
| `POST /v1/journeys`            | OIDC JWT + org scope | Create a journey (name, main_activity_type, apiary_ids) — status always starts `open`. Verifies every `apiary_id`'s ownership, records history. 201, or 422/409.                                                                                                                                                         |
| `PATCH /v1/journeys/{id}`      | OIDC JWT + org scope | Edit a journey: name/main_activity_type/apiary_ids are a full resubmit (diffed against the stored plan — an unaffected apiary's row is untouched); `status` is optional (D-21's close/reopen transition rides this same PATCH). 200, or 404/422.                                                                         |
| `DELETE /v1/journeys/{id}`     | OIDC JWT + org scope | Delete a journey — a tombstone (`deleted_at`), not a hard delete. Plan items are left in place (inert), mirroring apiaries' own apiary+counter delete convention. Records history. 204, or 404.                                                                                                                          |
| `POST /internal/sync/validate` | OIDC JWT + org scope | Dry-runs a batch mixing `entity_type: "journey"` and `"journey_plan_item"` ops — the counterpart of `services/apiaries/api/sync.go`'s own route.                                                                                                                                                                         |
| `POST /internal/sync/apply`    | OIDC JWT + org scope | Applies a batch of `journey`/`journey_plan_item` ops in one local transaction — idempotent, LWW-compared for `journey` ops, folds a plan add/remove into a `journey`-entity history row.                                                                                                                                 |
| `GET /healthz`, `GET /readyz`  | none                 | Liveness / readiness.                                                                                                                                                                                                                                                                                                    |

## Configuration

Inherits the template's env vars, plus the org-resolver's in-cluster URLs
(same as activities) and apiaries' own URL for the cross-service apiary-
ownership check:

| Variable                     | Notes                            |
| ---------------------------- | -------------------------------- |
| `INTERNAL_IDENTITY_URL`      | e.g. `http://identity:8080`      |
| `INTERNAL_ORGANIZATIONS_URL` | e.g. `http://organizations:8080` |
| `INTERNAL_APIARIES_URL`      | e.g. `http://apiaries:8080`      |

## Development

```sh
cd services/journeys
sqlc generate -f store/sqlc/sqlc.yaml
go build ./...
go test ./...   # api/... is fast, pure-Go unit tests (type-registry validation, the
                 # ApiaryVerifier's HTTP behavior against an httptest fake — no real DB);
                 # the top-level package needs testcontainers/Postgres (postgres:16-alpine):
                 # schema tenancy check, the create/edit/close/delete REST paths (including
                 # the cross-org apiary_id/journey_id IDOR regressions), the sync validate/
                 # apply endpoints (journey + journey_plan_item ops, LWW, idempotent replay),
                 # and store-layer insert/read + cross-org isolation.
```

## Tenancy (FR-TEN-2)

Every route runs behind OIDC authn + `authn.NewOrgResolver` +
`authn.RequireRole` (mirroring activities/apiaries), and every owned table
carries `organization_id`, verified by an automated schema check
(`TestJourneysSchema_EveryOwnedTableCarriesOrganizationID`, using
[`dbaccess.UnscopedTables`](../shared/dbaccess/tenancy.go)).

**Cross-service apiary ownership (CRITICAL, carry-over from activities'
#39/#38 review):** `apiary_id` is a cross-service reference this service has
no database access to verify directly (ownership rule 1) — every write path
that touches it (`api/write.go`'s `createJourney`/`updateJourney`,
`api/sync.go`'s `applyJourneyPlanItemOp`) calls
`api/apiaries_client.go`'s `ApiaryVerifier.BelongsToOrg` (apiaries' own
org-scoped `GET /v1/apiaries/{id}`, forwarding the caller's own bearer —
zero-trust) BEFORE any row is written, de-duplicated to one upstream call
per distinct apiary_id, and resolved BEFORE any DB transaction opens (the
same HIGH-severity fix activities' own review closed). `journey_id` itself
(a same-schema reference) is verified with a plain org-scoped DB read
instead — no HTTP call needed, since this service owns the `journeys` table
directly.
