<!-- Generated: 2026-07-14 | Files scanned: 461 | Token estimate: ~900 -->

# Architecture Codemap

Offline-first beekeeping field app. Monorepo: Flutter Web PWA client + Go
microservices, synced via PowerSync. Multi-tenant (`organization_id`), OIDC auth,
append-only history. Source of intent: `requirements/`; as-built: `docs/`.

## System diagram

```text
                    Traefik gateway  (app.beekeepingit.local:8443)
  ┌───────────────────────┼───────────────────────┬──────────────────┐
  │ /                     │ /v1/*                  │ /sync-stream/**  │
  ▼                       ▼                        ▼                  │
Flutter PWA          Go services (chi)         PowerSync svc          │
(local SQLite) ◄─────┤ identity                (streams down)         │
  │  ▲                │ organizations                ▲                │
  │  │ down-sync      │ apiaries ─┐                  │ logical repl    │
  │  └────────────────┼───────────┼──────────────────┘                │
  │ writes            │ sync ─────┘ (write-back coordinator)          │
  └───────────────────┴──────────────────► Postgres + PostGIS (CNPG) ◄┘
                                        schemas: identity / organizations / apiaries

  OIDC: Authentik (auth.beekeepingit.local:8443)   Object store: MinIO
  Observability: OTel collector → Grafana          GitOps: Flux
```

## Service boundaries (each owns its Postgres schema)

| Service         | Owns                                    | Calls (internal)                  |
| --------------- | --------------------------------------- | --------------------------------- |
| `identity`      | users, profiles                         | —                                 |
| `organizations` | orgs, memberships, invitations          | identity                          |
| `apiaries`      | apiaries, counters, conflict/audit logs | identity, organizations           |
| `sync`          | nothing (stateless write-back + tokens) | identity, organizations, apiaries |

## Data flow — local-first write (walking-skeleton §4.4)

```text
UI mutation → ApiariesRepository → local SQLite (PowerSync CRUD queue)
   → connector.uploadData → POST /v1/sync/batch (sync svc)
   → Coordinator: validate-ALL then apply  (forwards caller bearer, zero-trust)
   → apiaries POST /internal/sync/{validate,apply} → Postgres
   ← 200 applied | 422 rejected→dead-letter | 5xx/502 retry (stays queued)
```

Down-sync: Postgres → PowerSync Sync Rules → device SQLite → Riverpod streams → UI.
The client **never** calls REST write handlers directly — every write rides sync.

## Key cross-cutting concerns

- **Auth**: OIDC JWT → org-resolver (sub→user, active membership→org+role) → RequireRole. Per request, org-scoped.
- **Conflict**: last-write-wins by device `updated_at`; losses logged (`sync_conflict_log`), superseded/rejected surfaced to user (D-12).
- **History**: append-only `audit_log` per owning schema (`FR-HIS`).
- **Tenancy**: every owned row carries `organization_id`; server derives it from the token.

## Where to look

- Backend routes/wiring → [backend.md](backend.md) · Client tree/state → [frontend.md](frontend.md)
- Tables/migrations → [data.md](data.md) · External deps → [dependencies.md](dependencies.md)
- Deep design: `docs/architecture/*.md` (esp. `walking-skeleton.md`, `sync.md`), ADRs in `docs/adr/`
