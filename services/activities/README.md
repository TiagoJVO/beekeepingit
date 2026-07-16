# services/activities

The **activities** service — owner of activity records
([#38](https://github.com/TiagoJVO/beekeepingit/issues/38), EPIC-03, M3). It
owns the `activities.activities`, `activities.sync_conflict_log` and
`activities.audit_log` tables (`docs/architecture/service-decomposition.md`
§3) and the per-type JSONB attribute model + server-side validation
(FR-AC-1, D-2, D-6, D-19, D-20's "extensible enums" convention).

**#38's scope was the data model, not the CRUD API** — it exposed only a
thin internal validate-only endpoint. [#39](https://github.com/TiagoJVO/beekeepingit/issues/39)
(FR-AC-2, FR-TEN-2, FR-HIS-1) adds the real **create** write path on top of
that same wiring: the client-facing `POST /v1/activities` REST route
(online-only/direct callers) and the internal `/internal/sync/validate` +
`/internal/sync/apply` endpoints the write-back coordinator
(`services/sync`) calls so an activity created offline (queued via
PowerSync) reconciles on sync (FR-OF-1). Both write paths verify a
client-supplied `apiary_id` belongs to the caller's organization via the
**apiaries service itself** (`api/apiaries_client.go`'s `ApiaryVerifier`,
calling apiaries' own org-scoped `GET /v1/apiaries/{id}`) before writing
anything — this service has no database access to the apiaries schema
(ownership rule 1), so that check can only be an HTTP call, not a query;
this is the direct carry-over of #38's review finding, closed here the same
way apiaries closed its own cross-tenant IDOR on counter sync (#284).
Edit/delete/list are later EPIC-03 stories (#40-#43).

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
2026-07-16 as committed v1 scope):

| Type        | Required attributes                                   | Optional attributes                                                                                     |
| ----------- | ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `harvest`   | `honey_supers` (int ≥ 0 — the primary yield metric)   | `honey_kg`, `hives_involved`, `notes`                                                                   |
| `feeding`   | `feed_type` (vocab), `feed_amount`                    | `hives_involved`, `notes`                                                                               |
| `treatment` | `treatment_context` (vocab), `treatment_type` (vocab) | `disease` (**required** when context is `disease_specific`/`detection_only`), `hives_involved`, `notes` |
| `generic`   | —                                                     | `notes`                                                                                                 |

Controlled candidate vocabularies (extensible, **not** a closed DB enum —
validated in Go against `FeedTypes`/`TreatmentTypes`/`TreatmentContexts`):

- **Feed type:** Xarope 1:1, Xarope 2:1, Candi, Pólen.
- **Treatment type:** Apivar/amitraz, Ácido oxálico, Timol, Outro.
- **Treatment context:** general/preventive, disease-specific, detection-only
  (D-19's "future-relevant data point", confirmed into v1 scope 2026-07-16).

**Extensibility (FR-AC-1 AC):** a new activity type, or a new attribute on an
existing type, is a **code-only** change — append to `typeSchemas` in
`api/types.go` (and the client mirror,
`client/lib/features/activities/activity_types.dart` +
`activity_attributes.dart`) — no migration to `activities.activities` or its
`attributes` JSONB column.

## Surface

| Route                                | Auth                 | Purpose                                                                                                                                                                                                                                                                                      |
| ------------------------------------ | -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /internal/activities/validate` | OIDC JWT + org scope | Stateless attribute-schema validation of `{type, occurred_at, attributes}`; never persists (#38). 200 `{"valid":true}` or 422 RFC 9457 with field detail.                                                                                                                                    |
| `POST /v1/activities`                | OIDC JWT + org scope | Create an activity (#39, online-only/direct callers -- the field PWA creates through sync instead). Verifies `apiary_id` ownership, derives `performed_by` from claims (FR-TEN-2), records history (FR-HIS-1). 201 with the created activity, or 422/409 on validation/idempotency conflict. |
| `POST /internal/sync/validate`       | OIDC JWT + org scope | Dry-runs a batch of `entity_type: "activity"` sync ops (create-only in this version) -- the counterpart of `services/apiaries/api/sync.go`'s own route, called by `services/sync`'s coordinator.                                                                                             |
| `POST /internal/sync/apply`          | OIDC JWT + org scope | Applies a batch of `entity_type: "activity"` ops in one local transaction -- idempotent on the client-generated id, records history, logs a content conflict on a differing resend.                                                                                                          |
| `GET /healthz`, `GET /readyz`        | none                 | Liveness / readiness.                                                                                                                                                                                                                                                                        |

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
                 # validate endpoint, the POST /v1/activities create path (including the
                 # cross-org apiary_id rejection, #39's carry-over from #38's review), the
                 # sync validate/apply endpoints, and store-layer insert/read + cross-org
                 # isolation.
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
database access to verify directly (ownership rule 1) — both write paths
(`api/write.go`'s `createActivity`, `api/sync.go`'s `applyActivityOp`) call
`api/apiaries_client.go`'s `ApiaryVerifier.BelongsToOrg` (apiaries' own
org-scoped `GET /v1/apiaries/{id}`, forwarding the caller's own bearer —
zero-trust) BEFORE any row is written, exactly mirroring how apiaries closed
its own cross-tenant IDOR on counter sync (#284). Covered by
`TestActivitiesRest_Create_CrossOrgApiaryIdIsRejected`,
`TestActivitiesSync_Validate_RejectsCrossOrgApiaryId` and
`TestActivitiesSync_Apply_CrossOrgApiaryIdIsNoOp` (`main_test.go`), plus
`api/apiaries_client_test.go`'s pure-unit coverage of the verifier itself.

**Attribution (FR-TEN-2):** `performed_by` is derived server-side from the
authenticated caller's resolved claims (`requireOrg`), never from a
client-supplied field — neither `activityCreateRequest` (REST) nor
`activityData` (sync) has a `performed_by` field at all, so a spoofed
attribution isn't even representable on the wire. Covered by
`TestActivitiesRest_Create_AttributionIsFromClaims_NeverClientSupplied` and
the attribution assertion in
`TestActivitiesSync_ValidateThenApply_CreateActivity_Success`.
