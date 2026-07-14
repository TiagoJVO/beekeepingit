<!-- Generated: 2026-07-14 | Files scanned: 113 | Token estimate: ~1000 -->

# Frontend Codemap

Flutter Web PWA (`client/`). Local-first: reads/writes go to on-device SQLite
(PowerSync), never the REST API directly. State: Riverpod. Routing: go_router.
i18n EN/PT (`lib/l10n/`), accessibility + gloves-friendly targets. Entry: `lib/main.dart`
→ `ProviderScope` → `BeekeepingitApp` (`lib/app.dart`) → `MaterialApp.router`.

## Route tree (lib/routing/app_router.dart, go_router)

```
redirect gate:  !auth → /login │ profile incomplete → /profile │ no org → /organization/new
/login                     LoginScreen            features/auth
/profile                   ProfileScreen          features/profile   (onboarding FR-ONB-1)
/organization/new          OrganizationScreen     features/organization (onboarding FR-ONB-2)
/organization/members      MembersScreen          features/members   (admin, #27)
/account                   AccountScreen          features/account   (FR-AU-1)
/sync-needs-fix            SyncNeedsFixScreen      features/sync      (D-12 dead-letter)
StatefulShellRoute (AppShell, 5-tab bottom nav — lib/shell/app_shell.dart)
  ├ /apiaries              ApiariesListScreen     features/apiaries   ◄ only live tab (M2)
  │   ├ new                ApiaryFormScreen
  │   └ :id                ApiaryDetailScreen
  │       └ edit           ApiaryFormScreen
  ├ /activities  ─┐
  ├ /journeys     ├ ComingSoonScreen (placeholders, M3–M8)
  ├ /todos        │
  └ /assistant   ─┘
```

## Layer flow

```
Screen (ConsumerWidget)
  → watches Riverpod provider (StreamProvider / FutureProvider)
  → Repository (features/*/*_repository.dart)
  → LocalStoreEngine  (core/sync/local_store.dart, impl PowerSyncLocalStore)
  → on-device SQLite  (PowerSync)  ⇅  backend via connector (see Sync)
```

Business logic stays out of widgets (repos + pure helpers, e.g. `filterApiariesByQuery`,
`sortApiariesByDistance` in apiaries_repository.dart).

## State management (Riverpod providers)

| Provider                                   | Where                           | Yields                                 |
| ------------------------------------------ | ------------------------------- | -------------------------------------- |
| `authControllerProvider`                   | core/auth/auth_controller       | auth state, access token (OIDC)        |
| `isAuthenticatedProvider`                  | core/auth                       | bool (gates router)                    |
| `profileProvider` / `organizationProvider` | features/profile, /organization | onboarding gates                       |
| `powerSyncProvider`                        | core/sync/powersync_service     | `PowerSyncSession` (db+connector+gate) |
| `localStoreProvider`                       | core/sync/powersync_service     | `LocalStoreEngine`                     |
| `apiariesRepositoryProvider`               | features/apiaries               | `ApiariesRepository`                   |
| `apiariesStreamProvider`                   | features/apiaries               | live `List<Apiary>` from SQLite        |
| `apiaryCountersProvider` (family)          | features/apiaries               | live counters per apiary (#256)        |
| `membershipLossPurgeProvider`              | core/sync/local_data_purge      | wipes local data on org loss (#125)    |

## Sync flow (client) — core/sync/

```
powerSyncProvider: open PowerSyncDatabase(appSchema) → BeekeepingitConnector, gated by SyncGate
BeekeepingitConnector (powersync_connector.dart):
  fetchCredentials → GET /v1/sync/token   (OIDC access token → short-TTL PowerSync token)
  uploadData       → POST /v1/sync/batch  (drains CRUD queue as {ops:[...]})
     200 → complete + clear dead-letter + notify superseded (LWW loss)
     400/422 → retain in sync_rejected_ops dead-letter + surface (D-12) + complete
     else → throw → stays queued (idempotent forward-retry)
SyncGate (sync_gate.dart): HttpConnectivityProbe must pass before connect()/reconnect (FR-OF-3)
```

## Client-side schema (core/sync/powersync_schema.dart)

`apiaries` (name, notes, place_label, location_lon/lat REAL, org_id, timestamps) ·
`apiary_counters` (apiary_id, counter_type, value) · `sync_rejected_ops` (**local-only** dead-letter).
`deleted_at` is not a local column (Sync Rules exclude tombstones). See [data.md](data.md).

## Theming / brand

`lib/theming/` — `app_theme.dart` (light/dark, system mode), `brand_tokens.dart`.
Bundled fonts (offline, no CDN): Archivo (body), Playfair Display (display). Melargil brand (D-18).

E2E: `client/e2e/` (Playwright). Widget/unit tests: `client/test/` mirrors `lib/`.
