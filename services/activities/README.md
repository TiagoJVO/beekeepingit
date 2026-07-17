# services/activities

The **activities** service — owner of activity records
([#38](https://github.com/TiagoJVO/beekeepingit/issues/38), EPIC-03, M3). It
owns the `activities.activities`, `activities.sync_conflict_log` and
`activities.audit_log` tables (`docs/architecture/service-decomposition.md`
§3) and the per-type JSONB attribute model + server-side validation
(FR-AC-1, D-2, D-6, D-19, D-20's "extensible enums" convention).

**#38's scope was the data model, not the CRUD API** — it exposed only a
thin internal validate-only endpoint. [#39](https://github.com/TiagoJVO/beekeepingit/issues/39)
(FR-AC-2, FR-TEN-2, FR-HIS-1) added the **create** write path on top of that
same wiring: the client-facing `POST /v1/activities` REST route
(online-only/direct callers) and the internal `/internal/sync/validate` +
`/internal/sync/apply` endpoints the write-back coordinator
(`services/sync`) calls so an activity created offline (queued via
PowerSync) reconciles on sync (FR-OF-1).
[#40](https://github.com/TiagoJVO/beekeepingit/issues/40)/[#41](https://github.com/TiagoJVO/beekeepingit/issues/41)
(FR-AC-3/FR-AC-4) extend the same REST + sync surface with **edit**
(`PATCH /v1/activities/{id}`, sync `patch`) and **delete**
(`DELETE /v1/activities/{id}`, sync `delete` — a **tombstone**, `deleted_at`,
never a hard delete, so the PowerSync Sync Rules'
`deleted_at IS NULL` filter propagates it to every device) — both LWW-compared
against the stored row's `updated_at` on the sync-apply path
(`api/sync.go`'s `applyActivityOp`/`mergeActivityOp`, mirroring apiaries'
own `applyOp`/`mergeOp`). Every write path that touches (or re-points)
`apiary_id` verifies it belongs to the caller's organization via the
**apiaries service itself** (`api/apiaries_client.go`'s `ApiaryVerifier`,
calling apiaries' own org-scoped `GET /v1/apiaries/{id}`) before writing
anything — this service has no database access to the apiaries schema
(ownership rule 1), so that check can only be an HTTP call, not a query;
this is the direct carry-over of #38's review finding, closed here the same
way apiaries closed its own cross-tenant IDOR on counter sync (#284). An
edit that doesn't touch `apiary_id` (the common case — the client's edit UI
never exposes moving an activity to a different apiary) makes no
cross-service call at all. List is a later EPIC-03 story (#42/#43).

Stamped from [`services/servicetemplate`](../servicetemplate/README.md); DB
access via [`services/shared/dbaccess`](../shared/README.md). Its own Go
module, linked through the repo-root `go.work`.

## Data model (FR-AC-1, FR-TEN-2)

`activities.activities`: `id`, `organization_id` (NOT NULL, tenancy),
`apiary_id` / `performed_by` / `journey_id` (cross-service **soft
references** — no FK, per the data-ownership rule "cross-context references
are by ID, not FK"; `journey_id` is nullable and unused until M4/#46, but
D-21 calls out that this column belongs to #38's schema), `type` (extensible,
validated in Go — not a DB enum/CHECK), `occurred_at` (a real `DATE` column,
not part of the JSONB bag, so FR-AC-5/FR-AC-6 date-range filtering doesn't
need to unpack JSON), `attributes` (the per-type JSONB bag), and the usual
audit/tombstone columns (`created_at`/`updated_at`/`recorded_at`/`deleted_at`,
matching apiaries' shape so the future sync-apply LWW path — #39 — has
nothing to add).

### Type registry (`api/types.go`)

The four initial types and their attribute schemas (FR-AC-1, confirmed
2026-07-16 as committed v1 scope; treatment's conditional `treatment_type`
and the `disease` vocabulary, and harvest's `lot_batch`, added by #291/#292):

| Type        | Required attributes                                                                                          | Optional attributes                                                                                            |
| ----------- | ------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------- |
| `harvest`   | `honey_supers` (int ≥ 0 — the primary yield metric)                                                          | `honey_kg`, `hives_involved`, `lot_batch` (#292, capture-only — export is EPIC-09-NEW-C), `notes`              |
| `feeding`   | `feed_type` (vocab), `feed_amount`                                                                           | `hives_involved`, `notes`                                                                                      |
| `treatment` | `treatment_context` (vocab); `treatment_type` (vocab, **required unless** context is `detection_only`, #291) | `disease` (vocab; **required** when context is `disease_specific`/`detection_only`), `hives_involved`, `notes` |
| `generic`   | —                                                                                                            | `notes`                                                                                                        |

Controlled candidate vocabularies (extensible, **not** a closed DB enum —
validated in Go against `FeedTypes`/`TreatmentTypes`/`TreatmentContexts`/`DiseaseConditions`):

- **Feed type:** Xarope 1:1, Xarope 2:1, Candi, Pólen.
- **Treatment type:** Apivar/amitraz, Ácido oxálico, Timol, Outro.
- **Treatment context:** general/preventive, disease-specific, detection-only
  (D-19's "future-relevant data point", confirmed into v1 scope 2026-07-16).
  A `detection_only` treatment does **not** require `treatment_type` (#291
  AC: "a detection can be logged with no treatment applied yet").
- **Disease/condition** (#291, D-19): Varroose, Loque americana, Loque
  europeia, Nosemose, Acariose, Aethina tumida (pequeno besouro da colmeia),
  Tropilaelaps spp., Outro — sourced from DGAV's mandatory-notification bee
  disease list (DDO) per `docs/research/regulatory-pt-eu-beekeeping.md` §B.6.
  The initial set is sourced directly from that research note and has not
  been separately confirmed by product.

**Extensibility (FR-AC-1 AC):** a new activity type, or a new attribute on an
existing type, is a **code-only** change — append to `typeSchemas` in
`api/types.go` (and the client mirror,
`client/lib/features/activities/activity_types.dart` +
`activity_attributes.dart`) — no migration to `activities.activities` or its
`attributes` JSONB column.

## Surface

| Route                                | Auth                 | Purpose                                                                                                                                                                                                                                                                                        |
| ------------------------------------ | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /internal/activities/validate` | OIDC JWT + org scope | Stateless attribute-schema validation of `{type, occurred_at, attributes}`; never persists (#38). 200 `{"valid":true}` or 422 RFC 9457 with field detail.                                                                                                                                      |
| `POST /v1/activities`                | OIDC JWT + org scope | Create an activity (#39, online-only/direct callers -- the field PWA creates through sync instead). Verifies `apiary_id` ownership, derives `performed_by` from claims (FR-TEN-2), records history (FR-HIS-1). 201 with the created activity, or 422/409 on validation/idempotency conflict.   |
| `PATCH /v1/activities/{id}`          | OIDC JWT + org scope | Edit an activity (#40, FR-AC-3, online-only/direct callers). Re-validates type/occurred_at/attributes, re-verifies `apiary_id` ownership only when the request carries one, records history. 200 with the updated activity, or 404/422.                                                        |
| `DELETE /v1/activities/{id}`         | OIDC JWT + org scope | Delete an activity (#41, FR-AC-4, online-only/direct callers) -- a **tombstone** (`deleted_at`), not a hard delete. Records history. 204, or 404 if already gone.                                                                                                                              |
| `POST /internal/sync/validate`       | OIDC JWT + org scope | Dry-runs a batch of `entity_type: "activity"` sync ops (`put`/`patch`/`delete`, #40/#41) -- the counterpart of `services/apiaries/api/sync.go`'s own route, called by `services/sync`'s coordinator.                                                                                           |
| `POST /internal/sync/apply`          | OIDC JWT + org scope | Applies a batch of `entity_type: "activity"` ops in one local transaction -- idempotent on the client-generated id, LWW-compared against the stored row's `updated_at` for edit/delete (#40/#41), records history, logs a conflict (server wins) on an LWW-losing or differing-content resend. |
| `GET /healthz`, `GET /readyz`        | none                 | Liveness / readiness.                                                                                                                                                                                                                                                                          |

## Configuration

Inherits the template's env vars, plus the org-resolver's in-cluster URLs
(same as apiaries) and, since #39, apiaries' own URL for the cross-service
apiary-ownership check:

| Variable                     | Notes                             |
| ---------------------------- | --------------------------------- |
| `INTERNAL_IDENTITY_URL`      | e.g. `http://identity:8080`       |
| `INTERNAL_ORGANIZATIONS_URL` | e.g. `http://organizations:8080`  |
| `INTERNAL_APIARIES_URL`      | e.g. `http://apiaries:8080` (#39) |

## Development

```sh
cd services/activities
sqlc generate -f store/sqlc/sqlc.yaml
go build ./...
go test ./...   # api/... is fast, pure-Go unit tests (type-registry validation, the
                 # ApiaryVerifier's HTTP behavior against an httptest fake — no real DB);
                 # the top-level package needs testcontainers/Postgres (postgres:16-alpine —
                 # no PostGIS columns here, unlike apiaries): schema tenancy check, the
                 # validate endpoint, the create/edit/delete REST paths (including the
                 # cross-org apiary_id rejection, #39's carry-over from #38's review, and
                 # #40's own re-verification on edit), the sync validate/apply endpoints
                 # (create/edit/delete, LWW, tombstone-exclusion-from-list, offline op
                 # idempotency), and store-layer insert/read + cross-org isolation.
```

## Tenancy (FR-TEN-2)

Every route runs behind OIDC authn + `authn.NewOrgResolver` +
`authn.RequireRole` (mirroring apiaries), and every owned table carries
`organization_id`, verified by an automated schema check
(`TestActivitiesSchema_EveryOwnedTableCarriesOrganizationID`, using
[`dbaccess.UnscopedTables`](../shared/dbaccess/tenancy.go)). Store-layer
cross-org isolation (a foreign org's `GetActivity`/`ListActivitiesByOrg` call
never sees another org's rows) is covered directly against the generated
sqlc queries in `main_test.go`.

**Cross-service apiary ownership (#39, CRITICAL carry-over from #38's
review):** `apiary_id` is a cross-service reference this service has no
database access to verify directly (ownership rule 1) — every write path
that touches it (`api/write.go`'s `createActivity`/`updateActivity`,
`api/sync.go`'s `applyActivityOp`) calls `api/apiaries_client.go`'s
`ApiaryVerifier.BelongsToOrg` (apiaries' own org-scoped
`GET /v1/apiaries/{id}`, forwarding the caller's own bearer — zero-trust)
BEFORE any row is written, exactly mirroring how apiaries closed its own
cross-tenant IDOR on counter sync (#284). An edit (#40) that doesn't carry
`apiary_id` at all — the common case, since the client's edit UI never
exposes moving an activity to a different apiary — makes no ownership call:
the row's own `organization_id`, already enforced by every lookup, is what
matters when `apiary_id` itself isn't changing. Covered by
`TestActivitiesRest_Create_CrossOrgApiaryIdIsRejected`,
`TestActivitiesRest_Update_CrossOrgApiaryIdIsRejected`,
`TestActivitiesSync_Validate_RejectsCrossOrgApiaryId`,
`TestActivitiesSync_Apply_CrossOrgApiaryIdIsNoOp` and
`TestActivitiesSync_Apply_Patch_CrossOrgApiaryIdIsNoOp` (`main_test.go`),
plus `api/apiaries_client_test.go`'s pure-unit coverage of the verifier
itself.

**Tombstones (#41, FR-AC-4, FR-OF-1):** delete is a soft-delete
(`deleted_at`), never a hard `DELETE`, on both the REST (`deleteActivity`)
and sync-apply (`applyActivityOp`'s `delete` op) paths — every read query
(`GetActivity`/`ListActivitiesByApiary`/`ListActivitiesByOrg`) filters
`deleted_at IS NULL`, and the PowerSync Sync Rules
(`infra/helm/beekeepingit/charts/powersync/values.yaml`) apply the identical
filter so a delete propagates to every device on their next sync. A
tombstoned row still physically exists (`GetActivityForUpdate` carries no
`deleted_at` filter) so a strictly-newer offline `put`/`patch` can
legitimately "undelete" it under LWW, and a stale offline `delete` loses to
a newer edit/create the same way any other op does. Covered by
`TestActivitiesRest_Delete_TombstoneRowExcludedFromListQuery`,
`TestActivitiesSync_Apply_Delete_TombstonesRow`,
`TestActivitiesSync_Apply_Delete_IdempotentReplay` and
`TestActivitiesSync_Apply_Delete_OlderThanLastEditIsSuperseded`.

**Attribution (FR-TEN-2):** `performed_by` is derived server-side from the
authenticated caller's resolved claims (`requireOrg`), never from a
client-supplied field — neither `activityCreateRequest` (REST) nor
`activityData` (sync) has a `performed_by` field at all, so a spoofed
attribution isn't even representable on the wire. Covered by
`TestActivitiesRest_Create_AttributionIsFromClaims_NeverClientSupplied` and
the attribution assertion in
`TestActivitiesSync_ValidateThenApply_CreateActivity_Success`.
