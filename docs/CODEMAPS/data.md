<!-- Generated: 2026-07-14 | Files scanned: 30 | Token estimate: ~950 -->

# Data Codemap

Postgres (CloudNativePG) + PostGIS. Schema-per-service (no cross-schema FKs;
services own their data). Every owned row carries `organization_id` (tenancy).
Soft-delete via `deleted_at`. Append-only `audit_log` per schema (`FR-HIS`).
Migrations: goose, `services/<svc>/store/migrations/*.sql`, applied at boot.

## Schemas & tables

### `identity`

```text
users        (id PK, oidc_sub UNIQUE, name, email, locale, created_at, updated_at)
audit_log    (id PK, organization_id NULL, entity_type, entity_id, change_type,
              actor_user_id, occurred_at, recorded_at, changed_fields[], change JSONB)
```

`organization_id` is NULL here — users are global, not org-owned (history.md §9).

### `organizations`

```text
organizations (id PK, name, address, created_by, created_at, updated_at)
memberships   (id PK, organization_id FK→organizations, user_id, role[admin|user],
               status[active|invited|removed], UNIQUE(organization_id,user_id))
invitations   (id PK, organization_id FK→organizations, email, role,
               status[pending|accepted|expired|revoked], invited_by, timestamps)
audit_log     (… entity_type[organization|membership|invitation], change JSONB)
```

### `apiaries`

```text
apiaries          (id PK, organization_id, name, created_at, updated_at, recorded_at,
                   deleted_at, location geography(Point,4326) NULL, notes NULL≤10k,
                   place_label NULL≤200)          -- hive_count column RETIRED (#256)
apiary_counters   (id PK, organization_id, apiary_id FK→apiaries ON DELETE CASCADE,
                   counter_type, value≥0, UNIQUE(apiary_id,counter_type))   -- 1-N (#256)
sync_conflict_log (id PK, org_id, entity_type, entity_id, winning/losing_payload JSONB,
                   winner[server|client], actor_user_id, occurred_at, recorded_at)
audit_log         (… change_type[create|update|delete], changed_fields[], change JSONB)
```

`counter_type` validated in Go (`api/counters.go`), not a DB enum (extensible-enum convention).

### `activities`

```text
activities        (id PK, organization_id, apiary_id NULL-FK(soft), performed_by NULL-FK(soft),
                   journey_id NULL(soft, unused until M4), type, occurred_at DATE,
                   attributes JSONB, created_at, updated_at, recorded_at, deleted_at)
sync_conflict_log  (… same shape as apiaries.sync_conflict_log)
audit_log          (… same shape as apiaries.audit_log)
```

`type` + per-type `attributes` keys validated in Go (`api/types.go`'s type registry), not a
DB enum/CHECK (extensible-enum convention). #38 shipped the schema + validation only; #39
added create, #40/#41 added edit/delete (delete via `deleted_at` tombstone, same convention
as `apiaries.apiaries`) — both REST (`api/write.go`) and sync-apply (`api/sync.go`, LWW on
`updated_at`).

## Relationships

```text
identity.users ──(oidc_sub ← JWT sub; user_id ref, no FK)──► organizations.memberships
organizations.organizations ─1─N─► memberships, invitations
apiaries.apiaries ─1─N─► apiary_counters (hive count lives here, not on apiaries)
apiaries.apiaries ─1─N─► audit_log / sync_conflict_log  (by entity_id, same schema)
```

Cross-service links are by id only (id resolved via internal APIs, e.g. org-resolver),
never SQL FKs — each schema is independently owned.

## Client-side (on-device SQLite, PowerSync — powersync_schema.dart)

```text
apiaries          (id, organization_id, name, notes, place_label,
                   location_lon REAL, location_lat REAL, created_at, updated_at)
apiary_counters   (id, organization_id, apiary_id, counter_type, value, timestamps)
sync_rejected_ops (LOCAL-ONLY dead-letter: dedup_key, fix_apiary_id, op, payload,
                   error_code, error_detail, rejected_at)               -- D-12
activities        (id, organization_id, apiary_id, performed_by, journey_id, type,
                   occurred_at, attributes TEXT(JSON-encoded), created_at, updated_at)
                   -- #38: schema declared for future Sync Rules; no read/write path yet
```

Projection: server `location geography` → client `location_lon/lat` via `ST_X`/`ST_Y`
in PowerSync Sync Rules (`infra/helm/.../powersync/values.yaml`). Tombstones excluded
down-sync (no local `deleted_at`).

## Migration history

```text
identity:       00001 create_users · 00002 rename keycloak_sub→oidc_sub · 00003 audit_log
organizations:  00001 create_organizations · 00002 create_invitations · 00003 audit_log
apiaries:       00001 create_apiaries · 00002 audit_log · 00003 add_location(PostGIS)
                00004 add_notes · 00005 create_apiary_counters · 00006 add_place_label
activities:     00001 create_activities(+sync_conflict_log) · 00002 audit_log
shared/dbaccess:00001 create_example_items (template reference only)
```

## Conventions

- **sqlc**: `store/sqlc/queries/*.sql` → `store/sqlc/gen/*.sql.go`; `schema.sql` is a
  codegen-only virtual mirror of the cumulative migrations (kept in sync by hand).
- **History**: writes append an `audit_log` row (delta via `shared/history`); immutability
  enforced by a DB job (`infra/helm/.../postgres/templates/audit-immutability-job.yaml`).

See [backend.md](backend.md) for the query layer, [architecture.md](architecture.md) for sync.
