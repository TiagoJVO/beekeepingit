# client

The Flutter field app (`D-5`) — **Web/PWA first, native later** (`D-10`). Scaffolded by `#21`
(shell, routing, theming, state, i18n); `#23` added the **walking-skeleton slice UI**: OIDC
login, the PowerSync web SDK (local-first SQLite), and the apiary list + create/edit form.
See [`docs/architecture/walking-skeleton.md`](../docs/architecture/walking-skeleton.md).

## Run it

```sh
flutter pub get
flutter run -d chrome --no-web-resources-cdn
```

`--no-web-resources-cdn` bundles CanvasKit/fonts locally instead of fetching them from
Google's CDN at runtime (`www.gstatic.com`) — without it the app renders a blank page
wherever that CDN is unreachable (corporate networks, offline). `task dart:build` /
`flutter build web` already always pass this flag; it matters for `flutter run` too, since
an offline-first field app must not depend on external network reachability just to paint
its first frame.

To point at a gateway host other than the local k3d dev mapping
(`https://app.beekeepingit.local:8443`, see `infra/README.md`), pass:

```sh
flutter run -d chrome --no-web-resources-cdn --dart-define=GATEWAY_BASE_URL=https://your-gateway-host
```

`flutter build web` produces the installable PWA bundle (`build/web/`): web app manifest
and the service worker Flutter generates at build time for app-shell caching.

### Configuration (`--dart-define`)

`lib/core/config/app_config.dart` reads these at build time. The app is **provider-agnostic**:
identity comes entirely from OIDC **discovery** off `OIDC_ISSUER` — no provider URL scheme is
hard-coded, so swapping the identity provider is just changing `OIDC_ISSUER`
(see [`docs/architecture/oidc-integration.md`](../docs/architecture/oidc-integration.md) §7).

| dart-define         | Default (local k3d dev)                                            | What it points at                                                       |
| ------------------- | ------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| `GATEWAY_BASE_URL`  | `https://app.beekeepingit.local:8443`                              | App host — Go APIs (`/v1/*`) + PowerSync (`/sync-stream`)               |
| `POWERSYNC_URL`     | `https://app.beekeepingit.local:8443/sync-stream/`                 | PowerSync sync-stream endpoint (trailing slash required)                |
| `OIDC_ISSUER`       | `https://auth.beekeepingit.local:8443/application/o/beekeepingit/` | OIDC issuer (auth host) — **all** endpoints read from its `.well-known` |
| `OIDC_CLIENT_ID`    | `beekeepingit-pwa`                                                 | Public client id registered with the provider                           |
| `OIDC_ACCOUNT_URL`  | `https://auth.beekeepingit.local:8443/if/user/#/settings`          | Provider self-service page (password change), opened in a new tab       |
| `OIDC_REDIRECT_URI` | _(empty → the app's own origin)_                                   | Post-login redirect URI                                                 |

## Structure

| Path                        | What's there                                                                                                                                                                                                                                                                                                                                                                                                                  |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lib/app.dart`, `main.dart` | App bootstrap: `ProviderScope`, `MaterialApp.router`                                                                                                                                                                                                                                                                                                                                                                          |
| `lib/routing/`              | [go_router](https://pub.dev/packages/go_router) config — `/login`, onboarding gates (`/profile`, `/organization/new`), an auth redirect, and the post-onboarding app shell (`StatefulShellRoute.indexedStack`, one nav stack per tab): apiaries (`/apiaries`, `/apiaries/new`, `/apiaries/:id`) plus the not-yet-built activities/journeys/todos/assistant tabs; `/organization/members` and `/account` sit outside the shell |
| `lib/shell/`                | The persistent app shell (`FR-UX-2`, `#197`) — 5-tab bottom nav, header (contextual back, brand + screen title, sync-status pill, account), contextual honey FAB, offline banner, and `ComingSoonScreen` placeholders for tabs without real screens yet                                                                                                                                                                       |
| `lib/theming/`              | Light/dark Material 3 `ThemeData`                                                                                                                                                                                                                                                                                                                                                                                             |
| `lib/l10n/`                 | i18n scaffold — `arb/app_{en,pt}.arb` source strings (`flutter gen-l10n`); generated `gen/` output is committed (matches `services/shared`'s committed `sqlc` output — no codegen step needed to build/test)                                                                                                                                                                                                                  |
| `lib/core/config/`          | Compile-time config (`--dart-define`) — gateway/OIDC/PowerSync URLs (see the table above)                                                                                                                                                                                                                                                                                                                                     |
| `lib/core/auth/`            | Provider-agnostic OIDC Authorization Code + PKCE flow via `openid_client` (discovery-driven; web redirect behind a conditional import so widget tests compile on the VM)                                                                                                                                                                                                                                                      |
| `lib/core/sync/`            | PowerSync schema + backend connector (`fetchCredentials`→`/v1/sync/token`, `uploadData`→`/v1/sync/batch`) + the DB provider; the connector also parses per-op `superseded` results into a notify-and-fix event stream (`sync.md` §4.2/§8, `#58`) consumed by `lib/shell/sync_status.dart`'s real `syncStatusProvider`/`syncNowProvider`                                                                                       |
| `lib/core/api/`             | Generic REST scaffold (`ApiClient`) — base URL + bearer injection (reuses `core/auth`'s access token), typed JSON, RFC 9457 `ApiException` mapping. Not profile-specific — other features reuse it (`#25`)                                                                                                                                                                                                                    |
| `lib/features/`             | One folder per screen/feature (`auth`, `apiaries`, `profile`, `organization`, `members`, `account`)                                                                                                                                                                                                                                                                                                                           |

## Decisions this scaffold makes (AC of `#21`)

- **State management: [Riverpod](https://riverpod.dev)** (`flutter_riverpod`, no code
  generation). Chosen over `Provider`/`Bloc` for compile-safe DI, first-class `Future`/
  `Stream` providers (a good fit for the offline/PowerSync state `#23` adds), and
  straightforward provider overrides in widget tests (see `test/widget_test.dart`).
- **Routing: [go_router](https://pub.dev/packages/go_router)**, the Flutter-team-maintained
  router — declarative routes, deep-linkable on web, named navigation.
- **Theming:** Material 3, a single seed color (`ColorScheme.fromSeed`), light + dark.
  Default `VisualDensity` (not compact) for gloves-friendly, large-tap-target field UX
  (`FR-UX`/`FR-AX`, WCAG 2.2 AA) — depth is EPIC-11's, this only establishes the approach.
- **i18n: Flutter `intl`** (`flutter gen-l10n`), EN default + a real (not lorem-ipsum) PT
  translation, per `NFR-I18N`.
- **Backend through the gateway (`#23`):** the `#21` provider-reachability placeholder is
  superseded — the app now logs in via OIDC (discovery-driven, provider-agnostic) and
  reads/writes apiaries local-first through PowerSync + the `sync` service (`/v1/sync/token`,
  `/v1/sync/batch`).

## Not in scope here (see `FOLLOWUPS.md`)

The PowerSync **web assets** (wasm SQLite + workers) and a few **deploy-time** wirings
(OIDC issuer/host resolution, the `/sync-stream` gateway route) are validated against the
live cluster — see `FOLLOWUPS.md`. The full-slice **Playwright e2e** lives in
[`e2e/`](e2e/). App icons (`web/icons/`, `web/favicon.png`) are Flutter's default placeholders.
