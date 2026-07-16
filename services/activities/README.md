# services/activities

The **activities** service — owner of activity records
([#38](https://github.com/TiagoJVO/beekeepingit/issues/38), EPIC-03, M3). It
owns the `activities.activities`, `activities.sync_conflict_log` and
`activities.audit_log` tables (`docs/architecture/service-decomposition.md`
§3) and the per-type JSONB attribute model + server-side validation
(FR-AC-1, D-2, D-6, D-19, D-20's "extensible enums" convention).

**Scope of this PR (#38) is the data model, not the CRUD API.** The
client-facing create/edit/delete/list REST surface and the sync
validate/apply endpoints are [#39](https://github.com/TiagoJVO/beekeepingit/issues/39)
and later EPIC-03 stories — see `docs/architecture/service-decomposition.md`
§3's "activities" row and D-14's phase plan ("build #38 first — nearly
everything downstream needs it"). This service currently exposes only a thin
internal validate-only endpoint proving the tenancy + validation wiring
end-to-end; #39 grows it into the real write path on top of the same wiring.

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

| Route                                | Auth                 | Purpose                                                                                                                                        |
| ------------------------------------ | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `POST /internal/activities/validate` | OIDC JWT + org scope | Validates `{type, occurred_at, attributes}` against the type registry; never persists. 200 `{"valid":true}` or 422 RFC 9457 with field detail. |
| `GET /healthz`, `GET /readyz`        | none                 | Liveness / readiness.                                                                                                                          |

## Configuration

Inherits the template's env vars, plus the org-resolver's in-cluster URLs
(same as apiaries):

| Variable                     | Notes                            |
| ---------------------------- | -------------------------------- |
| `INTERNAL_IDENTITY_URL`      | e.g. `http://identity:8080`      |
| `INTERNAL_ORGANIZATIONS_URL` | e.g. `http://organizations:8080` |

## Development

```sh
cd services/activities
sqlc generate -f store/sqlc/sqlc.yaml
go build ./...
go test ./...   # api/... is fast, pure-Go unit tests (type-registry validation, no DB);
                 # the top-level package needs testcontainers/Postgres (postgres:16-alpine —
                 # no PostGIS columns here, unlike apiaries): schema tenancy check, the
                 # validate endpoint, and store-layer insert/read + cross-org isolation.
```

## Tenancy (FR-TEN-2)

The validate route runs behind OIDC authn + `authn.NewOrgResolver` +
`authn.RequireRole` (mirroring apiaries), and every owned table carries
`organization_id`, verified by an automated schema check
(`TestActivitiesSchema_EveryOwnedTableCarriesOrganizationID`, using
[`dbaccess.UnscopedTables`](../shared/dbaccess/tenancy.go)). Store-layer
cross-org isolation (a foreign org's `GetActivity`/`ListActivitiesByOrg` call
never sees another org's rows) is covered directly against the generated
sqlc queries in `main_test.go`, ahead of #39's HTTP write surface existing to
exercise it end-to-end.
