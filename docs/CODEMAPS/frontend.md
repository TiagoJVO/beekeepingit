<!-- Generated: 2026-07-18 | Files scanned: 120 | Token estimate: ~1070 -->

# Frontend Codemap

Flutter Web PWA (`client/`). Local-first: reads/writes go to on-device SQLite
(PowerSync), never the REST API directly. State: Riverpod. Routing: go_router.
i18n en-GB/pt-PT (`lib/l10n/`, D-34), accessibility + gloves-friendly targets. Entry: `lib/main.dart`
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
/organization/details      OrganizationDetailsScreen features/organization (FR-AP-9, #296 — org
                                                  details incl. the beekeeper registration
                                                  number, the org-wide default; reached from
                                                  Account, edited online over REST)
/stock-declarations        StockDeclarationsScreen features/stock_declarations (FR-AP-10, #298 —
                                                  the declaration log, keyed by registration
                                                  number; reached from Account; a record only,
                                                  no deadlines or thresholds derived — D-19)
StatefulShellRoute (AppShell, 5-tab bottom nav — lib/shell/app_shell.dart; per-tab FAB config
  in `_fabConfigByTab`, generalized #52 to a primary + optional secondary tonal FAB, an
  `onPressed(context)` action rather than only a route — Apiaries tab: primary "Add apiary"
  + secondary "New todo" routing to /todos/new (#389), no pre-filled apiary)
  NOTE (#658, D-35): `AppShell.tabs` is the SINGLE source for both the NavigationBar
  destinations and the `tabs[currentIndex]` active-tab lookup, so **tab position IS branch
  position** — the branch order below must match that list exactly. Tab order is
  apiaries · activities · home · journeys · todos, Home at the centre in the slot the
  retired Assistant placeholder held. Home and Activities have no `_fabConfigByTab` entry,
  so the shell renders no FAB on them.
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
  │       ├ history                     HistoryScreen      features/history (#60, FR-HIS-1; full
  │       │                             per-apiary change timeline — virtualized, uncapped)
  │       ├ activities/:activityId      ActivityDetailScreen features/activities (#310; read-only
  │       │   ├ edit                    view — type/date/attrs/performer; Edit+Delete)
  │       │   │                         AddActivityScreen (#40/#41; edit + delete, isEdit)
  │       │   └ history                 HistoryScreen      features/history (#60; same generic
  │       │                             screen, pointed at entity_type=activity)
  │       ├ (embedded)                  _ApiaryActivitiesSection on ApiaryDetailScreen (#42;
  │       │                             per-apiary activity list, type/date-range filters,
  │       │                             attribution — #44; capped preview → "view all" opens
  │       │                             the activities route above; a row → activity detail)
  │       ├ (embedded)                  HistorySection on both detail screens (#60, FR-HIS-1,
  │       │                             history.md §8; entity-agnostic per-entity timeline keyed
  │       │                             by (entity_type, entity_id) — local-first from the synced
  │       │                             audit_log/sync_conflict_log tables, REST fallback when the
  │       │                             device has no slice; capped preview → "view all" opens the
  │       │                             history route; superseded LWW losses shown inline)
  │       └ (FAB, not a route)          add-todo FAB on ApiaryDetailScreen (#52/#389, FR-UX-2)
  │                                     routes to /todos/new?apiaryId=..., pre-selecting this
  │                                     apiary in the full form's own picker
  ├ /activities            ActivitiesListScreen  features/activities ◄ live (#43; org-wide
  │                        activity list, same filters + apiary label per row)
  ├ /home                  HomeScreen             features/home       ◄ live (#658, D-35/D-29
  │                        amended; THE LANDING SCREEN — initialLocation + the post-login and
  │                        post-onboarding redirect target. Summary of what needs attention:
  │                        tasks overdue/due-soon, open journeys, apiaries not visited in
  │                        `apiaryVisitRecencyDays` (30). One of three exhaustive states —
  │                        firstRun (one EmptyState + one 56px action → /apiaries/new),
  │                        allClear, needsAttention. Rows tap to the record; "view all" taps
  │                        to the filtered list. Reads NO clock: every badge rides on the
  │                        summary's single `now`. No FAB, no own Scaffold)
  ├ /journeys              JourneysListScreen     features/journeys   ◄ live (#45/#47; org-wide
  │   │                    list — date-range/activity-type/status filters (combinable), plan-vs-
  │   │                    done progress badge per row, tap row → detail (#48); `?status=open`
  │   │                    seeds the status filter from the route (#658))
  │   ├ new                JourneyFormScreen      features/journeys (#45; create)
  │   └ :id                JourneyDetailScreen    features/journeys (#48, FR-JO-3; apiaries
  │       │                visited vs. planned by stored journey_id (D-21), per-apiary
  │       │                activities via the shared ActivityListView, embeds
  │       │                JourneyStatsSection, features/journeys/journey_stats_section.dart —
  │       │                #49's apiaries visited/hives harvested/honey collected/média
  │       │                alças/colmeia; edit reachable via its own FAB)
  │       └ edit                        JourneyFormScreen features/journeys (#45; edit/close/
  │                                     delete, isEdit)
  └ /todos                 TodosListScreen        features/todos      ◄ live (#53; org-wide
      │                    todo list — status/priority/due-date filters (combinable), sortable
      │                    by due date/priority/status, distinguishes open/overdue/done; own
      │                    FAB (#52/#389) routes to /todos/new, no pre-filled apiary;
      │                    row tap → detail (#293); `?status=`/`?due=` seed the filters from
      │                    the route (#658) — seeded INSIDE the mounted screen, never by
      │                    writing the autoDispose filter providers before context.go)
      ├ new                TodoFormScreen         features/todos (#293/#389; the ONLY create
      │                    entry point now — every FAB routes here, `?apiaryId=` optionally
      │                    pre-selects the apiary picker)
      └ :id                TodoDetailScreen       features/todos (#293, FR-TD-1; every field
          │                read-only incl. resolved assignee/apiary names — todo_display.dart's
          │                `todoAssigneeLabel`/`todoApiaryLabel`; complete/reopen toggle in place;
          │                edit reachable via its own FAB)
          └ edit                        TodoFormScreen features/todos (#293, FR-TD-1; full
                                        create/edit form — title/description/due date/priority/
                                        assignee (TodoAssigneePickerField)/apiary
                                        (TodoApiaryPickerField); complete/reopen + delete, isEdit)

(The Assistant tab was retired by #658/D-35 — the AI assistant itself stays an M8 roadmap
item, it just no longer holds a nav slot behind a "coming soon" placeholder.)
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

**Single-definition domain rules** — each of these is the ONE answer to its question, consumed by
every surface rather than re-derived per screen (#658 lifted the first out of a private
notification-engine helper for exactly this reason):

| Rule                        | Lives in                                                                                                      | Consumers                             |
| --------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| overdue                     | `features/todos/todo_filters.dart` `isOverdue`                                                                | todos list, notification engine, home |
| due soon (per-priority)     | `features/todos/todo_due.dart` `todoDueBucket` / `dueSoonWindowDays`                                          | notification engine, home             |
| apiary not visited recently | `features/apiaries/apiary_visit_recency.dart` `apiariesNotVisitedSince` (`apiaryVisitRecencyDays` = 30, D-35) | home                                  |

`HomeSummary` carries the decided bucket/day-count on each preview item, so a widget never
re-reads the clock — a second `DateTime.now()` can straddle midnight and badge a row differently
from the list it sits in.

## State management (Riverpod providers)

| Provider                                   | Where                                | Yields                                                                                                                                                                                                                                                                                                                                                                                         |
| ------------------------------------------ | ------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `authControllerProvider`                   | core/auth/auth_controller            | auth state, access token (OIDC)                                                                                                                                                                                                                                                                                                                                                                |
| `isAuthenticatedProvider`                  | core/auth                            | bool (gates router)                                                                                                                                                                                                                                                                                                                                                                            |
| `profileProvider` / `organizationProvider` | features/profile, /organization      | onboarding gates                                                                                                                                                                                                                                                                                                                                                                               |
| `powerSyncProvider`                        | core/sync/powersync_service          | `PowerSyncSession` (db+connector+gate)                                                                                                                                                                                                                                                                                                                                                         |
| `localStoreProvider`                       | core/sync/powersync_service          | `LocalStoreEngine`                                                                                                                                                                                                                                                                                                                                                                             |
| `apiariesRepositoryProvider`               | features/apiaries                    | `ApiariesRepository`                                                                                                                                                                                                                                                                                                                                                                           |
| `apiariesStreamProvider`                   | features/apiaries                    | live `List<Apiary>` from SQLite (org-scoped incl. defense-in-depth filter, #658)                                                                                                                                                                                                                                                                                                               |
| `apiaryCountersProvider` (family)          | features/apiaries                    | live counters per apiary (#256)                                                                                                                                                                                                                                                                                                                                                                |
| `activitiesRepositoryProvider`             | features/activities                  | `ActivitiesRepository`                                                                                                                                                                                                                                                                                                                                                                         |
| `activitiesByApiaryProvider` (family)      | features/activities                  | live activities for one apiary (#42)                                                                                                                                                                                                                                                                                                                                                           |
| `activitiesStreamProvider`                 | features/activities                  | live org-wide activities (#43, org-scoped incl. defense-in-depth filter)                                                                                                                                                                                                                                                                                                                       |
| `activitiesViewModelProvider` (family)     | features/activities/activity_filters | filtered list + empty-vs-no-results state (#42/#43)                                                                                                                                                                                                                                                                                                                                            |
| `journeysRepositoryProvider`               | features/journeys                    | `JourneysRepository` (#45)                                                                                                                                                                                                                                                                                                                                                                     |
| `journeysStreamProvider`                   | features/journeys                    | live org-wide journeys, unfiltered (#45)                                                                                                                                                                                                                                                                                                                                                       |
| `journeyMatchesProvider` (family)          | features/journeys/journey_picker     | live journeys matching one (apiary, activity type) pair (#46, D-21)                                                                                                                                                                                                                                                                                                                            |
| `journeyByIdProvider` (family)             | features/journeys                    | live single `Journey` by id, no `apiaryIds` (#48; the detail screen's read path)                                                                                                                                                                                                                                                                                                               |
| `activitiesByJourneyProvider` (family)     | features/activities                  | live activities for one journey, by stored `journey_id` (#48, D-21)                                                                                                                                                                                                                                                                                                                            |
| `journeyStatsProvider` (family)            | features/journeys                    | live `JourneyStats` per journey id — apiaries visited/planned, hives harvested, honey collected, média alças/colmeia (#49, FR-JO-1, D-2, D-21, stored `journey_id` link only, never a live re-match)                                                                                                                                                                                           |
| `todosRepositoryProvider`                  | features/todos                       | `TodosRepository` (#50)                                                                                                                                                                                                                                                                                                                                                                        |
| `todoByIdProvider` (family)                | features/todos                       | live single todo by id (#50)                                                                                                                                                                                                                                                                                                                                                                   |
| `todosStreamProvider`                      | features/todos                       | live org-wide todos, unfiltered (#53, org-scoped incl. defense-in-depth filter)                                                                                                                                                                                                                                                                                                                |
| `todosViewModelProvider`                   | features/todos/todo_filters          | filtered + sorted list, empty-vs-no-results state, `today` used for overdue (#53)                                                                                                                                                                                                                                                                                                              |
| `homeSummaryProvider`                      | features/home/home_providers         | live `HomeSummary` for the landing screen (#658, D-35) — composes todos/journeys/apiaries/activities streams, reading each as `.value ?? const []` **without awaiting** (the `journeysViewModelProvider` pattern) so Home paints immediately and a cold or errored stream degrades to an empty section; org scoping is inherited, it adds no query of its own; `now` computed once per rebuild |
| `journeyStatusFilterProvider`              | features/journeys/journey_filters    | open/closed/all status filter for the journeys list, seeded from `?status=` (#658)                                                                                                                                                                                                                                                                                                             |
| `membershipLossPurgeProvider`              | core/sync/local_data_purge           | wipes local data on org loss (#125)                                                                                                                                                                                                                                                                                                                                                            |

## Sync flow (client) — core/sync/

```text
powerSyncProvider: open PowerSyncDatabase(appSchema) → BeekeepingitConnector, gated by SyncGate
BeekeepingitConnector (powersync_connector.dart):
  fetchCredentials → GET /v1/sync/token   (OIDC access token → short-TTL PowerSync token)
     only once the caller has an active membership (#622) — hasOrganizationProvider; without
     one it returns null and sends nothing (the org-scoped token endpoint 403s by design)
  uploadData       → POST /v1/sync/batch  (drains CRUD queue as {ops:[...]})
     200 → complete + clear dead-letter + notify superseded (LWW loss)
     400/422 → retain in sync_rejected_ops dead-letter + surface (D-12) + complete
     else → throw → stays queued (idempotent forward-retry)
SyncGate (sync_gate.dart): HttpConnectivityProbe must pass before connect()/reconnect (FR-OF-3)
  powersync_service.dart's applySyncPreconditions arms it only when auto-sync is on AND a
  membership exists (#81, #622); the hasOrganizationProvider listener starts sync on the
  false→true edge (org created) with no reload; connectIfAllowed re-checks membership right
  before db.connect() (SyncGate.requestSync bypasses the loop's own generation check)
  manual "sync now" (shell/sync_status.dart's syncNowProvider) bypasses the QUALITY gate but
  declines with no membership, before disconnecting — unreachable from the UI (#622)
lww_delete.dart: every synced delete goes through deleteWithLwwStamp() — stamps the device
  delete time into the trackMetadata `_metadata` column so the op's LWW comparator survives
  retries AND app restarts; read back in _toOp via CrudEntry.metadata (#276, sync.md §4.5)
validation parity (sync.md §9, D-12) — ONE evaluator, core/validation/sync_op_validator.dart,
  over the shared description embedded in core/validation/gen/, run at TWO call sites:
    pre-push  (#584) uploadData, on the ops _toOp built → dead-letter + needs-fix
    save-time (#597) each form's _save, on <Repository>.draftForSave(...) → field error
  both build the wire op through core/sync/sync_op_draft.dart's SyncOpDraft, so the two
  verdicts see identical bytes; features/sync/save_time_validation.dart localizes a failure
  through #443's mapping. Advisory only — the server stays authoritative.
```

## Client-side schema (core/sync/powersync_schema.dart)

`apiaries` (name, notes, place_label, registration_number, location_lon/lat REAL,
org_id, timestamps — registration_number is the per-apiary OVERRIDE of the org
default, FR-AP-9/#296) ·
`apiary_counters` (apiary_id, counter_type, value) ·
`stock_declarations` (registration_number, declared_on, total_hive_count,
breakdown TEXT(JSON-encoded array), notes, timestamps — FR-AP-10/#298, the stock
declaration log; keyed by registration number, NOT the live hive counter) ·
`journeys` (name, main_activity_type, status, org_id, timestamps) ·
`journey_plan_items` (journey_id, apiary_id, org_id, created_at) — #45, two tables/entity
types mirroring apiaries/apiary_counters' own parent+child split ·
`todos` (title, description, due_date, priority, status, completed_at, assignee_id, apiary_id,
org_id, timestamps — #50, plain scalar columns, no JSON-encoded column needed unlike
`activities`; apiary_id added by #51, optional apiary association FR-TD-1) ·
`sync_rejected_ops` (**local-only** dead-letter) ·
`audit_log` / `sync_conflict_log` (#60, FR-HIS-1 — **read-only, never written locally**;
polymorphic on (entity_type, entity_id), so one table per log kind serves every entity's
timeline and BOTH `apiaries.*` and `activities.*` stream into them; JSONB/TEXT[] columns
arrive JSON-encoded as TEXT, same convention as `activities.attributes`).
`deleted_at` is not a local column (Sync Rules exclude tombstones). See [data.md](data.md).

## Theming / brand

`lib/theming/` — `app_theme.dart` (light/dark, system mode), `brand_tokens.dart`.
One brand mark (#686): `BrandMark` (`brand_widgets.dart`) draws the bundled
`assets/brand/app-icon-512.png`, a byte-identical copy of the PWA icon `web/icons/Icon-512.png`,
so the in-app mark and the installed app's icon cannot diverge (`test/brand_mark_asset_test.dart`).
Bundled fonts (offline, no CDN): Archivo (body), Playfair Display (display). Melargil brand (D-18).
Plus Roboto — not a brand face: it is the family CanvasKit downloads from `fonts.gstatic.com` on
every cold load unless one is bundled, and the app's glyph fallback (#620). `web/flutter_bootstrap.js`
pins `fontFallbackBaseUrl` to a same-origin path so the per-code-point Noto fallback can't leave
the origin either.

## PWA shell / offline boot

`web/service_worker.js` — this repo's own app-shell service worker (#619; Flutter's generated one
is a self-unregistering deprecation stub, so `web/flutter_bootstrap.js` no longer registers it).
Registered by `web/sw_register.js` from `web/index.html`. Precaches the boot path (~6.6 MB); the
CanvasKit variant the browser actually picked is stored lazily, warmed by `sw_register.js`
reporting the page's loaded resources to the controlling worker (a fetch handler alone misses it —
the engine loads before any worker controls the first visit). Leaves APIs, the PowerSync stream,
`/v1/*` + `/sync-stream` navigations and everything cross-origin untouched. Nothing Flutter emits
is content-hashed (#678), so `tool/build_app_shell_cache.dart` injects a per-file sha-256 — plus a
digest of `nginx.conf`, since cached responses keep their headers — and a `BUILD_REVISION` into
the worker after **every** `flutter build web`; that is the release-invalidation key
(`scripts/check-app-shell-precache-wired.sh` guards the wiring). The `/v1/*` + `/sync-stream`
exclusion is a hand-maintained mirror of the gateway chart's app-host routes, guarded by
`scripts/check-service-worker-routes.sh` (#683).

E2E: `client/e2e/` (Playwright; service workers blocked by default, `offline-boot.spec.ts` opts
in). Widget/unit tests: `client/test/` mirrors `lib/`, plus `test/tool/` for the build tooling.
