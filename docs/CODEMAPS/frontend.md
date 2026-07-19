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
StatefulShellRoute (AppShell, 5-tab bottom nav — lib/shell/app_shell.dart; per-tab FAB config
  in `_fabConfigByTab`, generalized #52 to a primary + optional secondary tonal FAB, an
  `onPressed(context)` action rather than only a route — Apiaries tab: primary "Add apiary"
  + secondary "New todo" opening todo_quick_create_sheet.dart, no pre-filled apiary)
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
  │       ├ (embedded)                  _ApiaryActivitiesSection on ApiaryDetailScreen (#42;
  │       │                             per-apiary activity list, type/date-range filters,
  │       │                             attribution — #44; capped preview → "view all" opens
  │       │                             the activities route above; a row → activity detail)
  │       └ (FAB, not a route)          add-todo FAB on ApiaryDetailScreen (#52, FR-UX-2) opens
  │                                     features/todos/todo_quick_create_sheet.dart pre-filled
  │                                     with this apiary (read-only chip, no apiary picker)
  ├ /activities            ActivitiesListScreen  features/activities ◄ live (#43; org-wide
  │                        activity list, same filters + apiary label per row)
  ├ /journeys              JourneysListScreen     features/journeys   ◄ live (#45/#47; org-wide
  │   │                    list — date-range/activity-type filters (combinable), plan-vs-done
  │   │                    progress badge per row, tap row → detail (#48))
  │   ├ new                JourneyFormScreen      features/journeys (#45; create)
  │   └ :id                JourneyDetailScreen    features/journeys (#48, FR-JO-3; apiaries
  │       │                visited vs. planned by stored journey_id (D-21), per-apiary
  │       │                activities via the shared ActivityListView, embeds
  │       │                JourneyStatsSection, features/journeys/journey_stats_section.dart —
  │       │                #49's apiaries visited/hives harvested/honey collected/média
  │       │                alças/colmeia; edit reachable via its own FAB)
  │       └ edit                        JourneyFormScreen features/journeys (#45; edit/close/
  │                                     delete, isEdit)
  ├ /todos                 TodosListScreen        features/todos      ◄ live (#53; org-wide
  │   │                    todo list — status/priority/due-date filters (combinable), sortable
  │   │                    by due date/priority/status, distinguishes open/overdue/done; own
  │   │                    FAB (#52) opens todo_quick_create_sheet.dart, no pre-filled apiary;
  │   │                    row tap → detail (#293))
  │   ├ new                TodoFormScreen         features/todos (#293; standalone create route —
  │   │                    direct nav/deep-link only, distinct from #52's quick-create sheet)
  │   └ :id                TodoDetailScreen       features/todos (#293, FR-TD-1; every field
  │       │                read-only incl. resolved assignee/apiary names — todo_display.dart's
  │       │                `todoAssigneeLabel`/`todoApiaryLabel`; complete/reopen toggle in place;
  │       │                edit reachable via its own FAB)
  │       └ edit                        TodoFormScreen features/todos (#293, FR-TD-1; full
  │                                     create/edit form — title/description/due date/priority/
  │                                     assignee (TodoAssigneePickerField)/apiary
  │                                     (TodoApiaryPickerField); complete/reopen + delete, isEdit)
  └ /assistant             ComingSoonScreen (placeholder, M8)
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
| `journeyByIdProvider` (family)             | features/journeys                    | live single `Journey` by id, no `apiaryIds` (#48; the detail screen's read path)                                                                                                                     |
| `activitiesByJourneyProvider` (family)     | features/activities                  | live activities for one journey, by stored `journey_id` (#48, D-21)                                                                                                                                  |
| `journeyStatsProvider` (family)            | features/journeys                    | live `JourneyStats` per journey id — apiaries visited/planned, hives harvested, honey collected, média alças/colmeia (#49, FR-JO-1, D-2, D-21, stored `journey_id` link only, never a live re-match) |
| `todosRepositoryProvider`                  | features/todos                       | `TodosRepository` (#50)                                                                                                                                                                              |
| `todoByIdProvider` (family)                | features/todos                       | live single todo by id (#50)                                                                                                                                                                         |
| `todosStreamProvider`                      | features/todos                       | live org-wide todos, unfiltered (#53, org-scoped incl. defense-in-depth filter)                                                                                                                      |
| `todosViewModelProvider`                   | features/todos/todo_filters          | filtered + sorted list, empty-vs-no-results state, `today` used for overdue (#53)                                                                                                                    |
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
`todos` (title, description, due_date, priority, status, completed_at, assignee_id, apiary_id,
org_id, timestamps — #50, plain scalar columns, no JSON-encoded column needed unlike
`activities`; apiary_id added by #51, optional apiary association FR-TD-1) ·
`sync_rejected_ops` (**local-only** dead-letter).
`deleted_at` is not a local column (Sync Rules exclude tombstones). See [data.md](data.md).

## Theming / brand

`lib/theming/` — `app_theme.dart` (light/dark, system mode), `brand_tokens.dart`.
Bundled fonts (offline, no CDN): Archivo (body), Playfair Display (display). Melargil brand (D-18).

E2E: `client/e2e/` (Playwright). Widget/unit tests: `client/test/` mirrors `lib/`.
