<!-- Generated: 2026-07-18 | Files scanned: 120 | Token estimate: ~1070 -->

# Frontend Codemap

Flutter Web PWA (`client/`). Local-first: reads/writes go to on-device SQLite
(PowerSync), never the REST API directly. State: Riverpod. Routing: go_router.
i18n EN/PT (`lib/l10n/`), accessibility + gloves-friendly targets. Entry: `lib/main.dart`
→ `ProviderScope` → `BeekeepingitApp` (`lib/app.dart`) → `MaterialApp.router`.

## Route tree (lib/routing/app_router.dart, go_router)

```text
redirect gate:  !auth → /login │ profile incomplete → /profile │ no org → /organization/new
/login                     LoginScreen            features/auth
/profile                   ProfileScreen          features/profile   (onboarding FR-ONB-1)
/organization/new          OrganizationScreen     features/organization (onboarding FR-ONB-2)
/organization/members      MembersScreen          features/members   (admin, #27)
/account                   AccountScreen          features/account   (FR-AU-1)
/sync-needs-fix            SyncNeedsFixScreen      features/sync      (D-12 dead-letter)
StatefulShellRoute (AppShell, 5-tab bottom nav — lib/shell/app_shell.dart)
  ├ /apiaries              ApiariesListScreen     features/apiaries   ◄ live (M2)
  │   ├ new                ApiaryFormScreen
  │   └ :id                ApiaryDetailScreen
  │       ├ edit                        ApiaryFormScreen
  │       ├ activities                  ApiaryActivitiesScreen features/apiaries (#42; full
  │       │                             per-apiary list — non-shrink-wrapped, virtualized)
  │       ├ activities/new              AddActivityScreen  features/activities (#39; add path;
  │       │                             #46 adds the journey-attachment picker — auto-select/
  │       │                             deselect/switch/inline-create, features/journeys/
  │       │                             journey_picker.dart + journey_quick_create_sheet.dart)
  │       ├ activities/:activityId      ActivityDetailScreen features/activities (#310; read-only
  │       │   └ edit                    view — type/date/attrs/performer; Edit+Delete)
  │       │                             AddActivityScreen (#40/#41; edit + delete, isEdit)
  │       └ (embedded)                  _ApiaryActivitiesSection on ApiaryDetailScreen (#42;
  │                                     per-apiary activity list, type/date-range filters,
  │                                     attribution — #44; capped preview → "view all" opens
  │                                     the activities route above; a row → activity detail)
  ├ /activities            ActivitiesListScreen  features/activities ◄ live (#43; org-wide
  │                        activity list, same filters + apiary label per row)
  ├ /journeys              JourneysListScreen     features/journeys   ◄ live (#45/#47; org-wide
  │   │                    list — date-range/activity-type filters (combinable), plan-vs-done
  │   │                    progress badge per row, tap row → edit; #49 adds full statistics,
  │   │                    #48 adds a dedicated detail screen)
  │   ├ new                JourneyFormScreen      features/journeys (#45; create)
  │   └ :id/edit            JourneyFormScreen     features/journeys (#45; edit/close/delete,
  │                        isEdit — no dedicated detail screen yet, that's #48; #49 adds
  │                        JourneyStatsSection, features/journeys/journey_stats_section.dart —
  │                        apiaries visited, hives harvested, honey collected, média
  │                        alças/colmeia, still not routed on its own, embeddable by #48)
  ├ /todos         ─┐
  └ /assistant     ─┘ ComingSoonScreen (placeholders, M5/M8)
```

## Layer flow

```text
Screen (ConsumerWidget)
  → watches Riverpod provider (StreamProvider / FutureProvider)
  → Repository (features/*/*_repository.dart)
  → LocalStoreEngine  (core/sync/local_store.dart, impl PowerSyncLocalStore)
  → on-device SQLite  (PowerSync)  ⇅  backend via connector (see Sync)
```

Business logic stays out of widgets (repos + pure helpers, e.g. `filterApiariesByQuery`,
`sortApiariesByDistance` in apiaries_repository.dart).

## State management (Riverpod providers)

| Provider                                   | Where                                | Yields                                                                                                                                                                                               |
| ------------------------------------------ | ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `authControllerProvider`                   | core/auth/auth_controller            | auth state, access token (OIDC)                                                                                                                                                                      |
| `isAuthenticatedProvider`                  | core/auth                            | bool (gates router)                                                                                                                                                                                  |
| `profileProvider` / `organizationProvider` | features/profile, /organization      | onboarding gates                                                                                                                                                                                     |
| `powerSyncProvider`                        | core/sync/powersync_service          | `PowerSyncSession` (db+connector+gate)                                                                                                                                                               |
| `localStoreProvider`                       | core/sync/powersync_service          | `LocalStoreEngine`                                                                                                                                                                                   |
| `apiariesRepositoryProvider`               | features/apiaries                    | `ApiariesRepository`                                                                                                                                                                                 |
| `apiariesStreamProvider`                   | features/apiaries                    | live `List<Apiary>` from SQLite                                                                                                                                                                      |
| `apiaryCountersProvider` (family)          | features/apiaries                    | live counters per apiary (#256)                                                                                                                                                                      |
| `activitiesRepositoryProvider`             | features/activities                  | `ActivitiesRepository`                                                                                                                                                                               |
| `activitiesByApiaryProvider` (family)      | features/activities                  | live activities for one apiary (#42)                                                                                                                                                                 |
| `activitiesStreamProvider`                 | features/activities                  | live org-wide activities (#43, org-scoped incl. defense-in-depth filter)                                                                                                                             |
| `activitiesViewModelProvider` (family)     | features/activities/activity_filters | filtered list + empty-vs-no-results state (#42/#43)                                                                                                                                                  |
| `journeysRepositoryProvider`               | features/journeys                    | `JourneysRepository` (#45)                                                                                                                                                                           |
| `journeysStreamProvider`                   | features/journeys                    | live org-wide journeys, unfiltered (#45)                                                                                                                                                             |
| `journeyMatchesProvider` (family)          | features/journeys/journey_picker     | live journeys matching one (apiary, activity type) pair (#46, D-21)                                                                                                                                  |
| `journeyStatsProvider` (family)            | features/journeys                    | live `JourneyStats` per journey id — apiaries visited/planned, hives harvested, honey collected, média alças/colmeia (#49, FR-JO-1, D-2, D-21, stored `journey_id` link only, never a live re-match) |
| `membershipLossPurgeProvider`              | core/sync/local_data_purge           | wipes local data on org loss (#125)                                                                                                                                                                  |

## Sync flow (client) — core/sync/

```text
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
`apiary_counters` (apiary_id, counter_type, value) ·
`journeys` (name, main_activity_type, status, org_id, timestamps) ·
`journey_plan_items` (journey_id, apiary_id, org_id, created_at) — #45, two tables/entity
types mirroring apiaries/apiary_counters' own parent+child split ·
`sync_rejected_ops` (**local-only** dead-letter).
`deleted_at` is not a local column (Sync Rules exclude tombstones). See [data.md](data.md).

## Theming / brand

`lib/theming/` — `app_theme.dart` (light/dark, system mode), `brand_tokens.dart`.
Bundled fonts (offline, no CDN): Archivo (body), Playfair Display (display). Melargil brand (D-18).

E2E: `client/e2e/` (Playwright). Widget/unit tests: `client/test/` mirrors `lib/`.
