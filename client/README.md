# client

The Flutter field app (`D-5`) — **Web/PWA first, native later** (`D-10`). Scaffolded by `#21`
(shell, routing, theming, state, i18n); `#23` added the **walking-skeleton slice UI**: OIDC
login, the PowerSync web SDK (local-first SQLite), and the apiary list + create/edit form.
`#32`/`#196` (`FR-AP-7`/`FR-AP-8`) added a read-focused apiary detail screen and free-text
notes. See [`docs/architecture/walking-skeleton.md`](../docs/architecture/walking-skeleton.md).

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

| Path                        | What's there                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lib/app.dart`, `main.dart` | App bootstrap: `ProviderScope`, `MaterialApp.router`                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `lib/routing/`              | [go_router](https://pub.dev/packages/go_router) config — `/login`, onboarding gates (`/profile`, `/organization/new`), an auth redirect, and the post-onboarding app shell (`StatefulShellRoute.indexedStack`, one nav stack per tab): apiaries (`/apiaries`, `/apiaries/new`, `/apiaries/:id` read-only detail, `/apiaries/:id/edit` the form, `FR-AP-7`/`#32`) plus the not-yet-built activities/journeys/todos/assistant tabs; `/organization/members` and `/account` sit outside the shell |
| `lib/shell/`                | The persistent app shell (`FR-UX-2`, `#197`) — 5-tab bottom nav, header (contextual back, brand + screen title, sync-status pill, account), contextual honey FAB, offline banner, and `ComingSoonScreen` placeholders for tabs without real screens yet                                                                                                                                                                                                                                        |
| `lib/theming/`              | Light/dark Material 3 `ThemeData` (`app_theme.dart`) hand-built from the Melargil brand tokens (`brand_tokens.dart`) — the single source of truth for every brand hex; plus the bundled brand fonts under `../fonts/` (see Theming below)                                                                                                                                                                                                                                                      |
| `lib/l10n/`                 | i18n scaffold — `arb/app_{en,pt}.arb` source strings (`flutter gen-l10n`); generated `gen/` output is committed (matches `services/shared`'s committed `sqlc` output — no codegen step needed to build/test)                                                                                                                                                                                                                                                                                   |
| `lib/core/config/`          | Compile-time config (`--dart-define`) — gateway/OIDC/PowerSync URLs (see the table above)                                                                                                                                                                                                                                                                                                                                                                                                      |
| `lib/core/auth/`            | Provider-agnostic OIDC Authorization Code + PKCE flow via `openid_client` (discovery-driven; web redirect behind a conditional import so widget tests compile on the VM)                                                                                                                                                                                                                                                                                                                       |
| `lib/core/sync/`            | PowerSync schema + backend connector (`fetchCredentials`→`/v1/sync/token`, `uploadData`→`/v1/sync/batch`) + the DB provider; the connector also parses per-op `superseded` results into a notify-and-fix event stream (`sync.md` §4.2/§8, `#58`) consumed by `lib/shell/sync_status.dart`'s real `syncStatusProvider`/`syncNowProvider`                                                                                                                                                        |
| `lib/core/api/`             | Generic REST scaffold (`ApiClient`) — base URL + bearer injection (reuses `core/auth`'s access token), typed JSON, RFC 9457 `ApiException` mapping. Not profile-specific — other features reuse it (`#25`)                                                                                                                                                                                                                                                                                     |
| `lib/core/l10n/`            | `LocaleFormatting` — locale-aware date/number formatting helper (`intl` `DateFormat`/`NumberFormat`), ready for the first screen that displays a date or a decimal (`NFR-I18N-1`, `#77`); see [Translations (i18n)](#translations-i18n) below                                                                                                                                                                                                                                                  |
| `lib/features/`             | One folder per screen/feature (`auth`, `apiaries`, `profile`, `organization`, `members`, `account`)                                                                                                                                                                                                                                                                                                                                                                                            |

## Translations (i18n)

EN + PT today, structured to add more languages later without touching feature
screens (`NFR-I18N-1`, `#77`/`#78`). Source strings are
[ARB](https://github.com/google/app-resource-bundle) files under
`lib/l10n/arb/`; `flutter gen-l10n` (configured by `l10n.yaml`) generates the
typed `AppLocalizations` API into `lib/l10n/gen/`, which is **committed**
(same convention as `services/shared`'s committed `sqlc` output — no codegen
step needed to build/test).

**Add a string:**

1. Add the key to `lib/l10n/arb/app_en.arb` (the template file), with an
   `@key` metadata block describing where it's used (see existing entries).
   Use [ICU plural syntax](https://docs.flutter.dev/ui/accessibility-and-localization/internationalization#pluralization)
   for anything that varies by count, e.g. `hiveCountValue`.
2. Add the same key to `lib/l10n/arb/app_pt.arb` too — CI only checks that
   the key exists in both files (see "What CI enforces" below), not that the
   Portuguese value is a real translation yet, but don't merge with an
   English placeholder left in the PT file; translate it in the same PR or
   flag it for a translator before merging.
3. Run `flutter gen-l10n` in `client/` and commit the regenerated
   `lib/l10n/gen/` alongside the ARB change.
4. Use it from a widget via `AppLocalizations.of(context).yourKey`.

**Translate a string:** edit the value in `lib/l10n/arb/app_pt.arb` (or the
new language's ARB file) — no Dart code changes needed. Re-run
`flutter gen-l10n` and commit `lib/l10n/gen/`.

**What CI enforces** (`task dart:l10n-check`, run as part of the client build
job in `.github/workflows/build-publish.yml`, `#78`):

- Every ARB file is valid JSON and every key in `app_en.arb` (the template)
  exists in every other ARB file, and vice versa — a key added to one
  language but not the other fails the build.
- `flutter gen-l10n` runs clean (fails on malformed ARB or an ICU syntax
  error).
- The committed `lib/l10n/gen/` matches what `flutter gen-l10n` regenerates —
  an ARB edit that wasn't followed by regenerating and committing the output
  fails the build.

**Locale-aware dates/numbers:** no screen renders a date or a decimal number
yet (the current slice only shows plain strings, ICU-pluralized counts, and
raw lat/lon text). `lib/core/l10n/locale_formatting.dart`'s
`LocaleFormatting` helper wraps `intl`'s `DateFormat`/`NumberFormat` keyed to
the active locale, ready for the first field that needs it — see its tests
(`test/core/l10n/locale_formatting_test.dart`) for EN vs. PT output.

## Decisions this scaffold makes (AC of `#21`)

- **State management: [Riverpod](https://riverpod.dev)** (`flutter_riverpod`, no code
  generation). Chosen over `Provider`/`Bloc` for compile-safe DI, first-class `Future`/
  `Stream` providers (a good fit for the offline/PowerSync state `#23` adds), and
  straightforward provider overrides in widget tests (see `test/widget_test.dart`).
- **Routing: [go_router](https://pub.dev/packages/go_router)**, the Flutter-team-maintained
  router — declarative routes, deep-linkable on web, named navigation.
- **Theming:** Material 3, light + dark, **hand-built from the Melargil brand tokens** — the
  depth EPIC-11 (`#243`, `FR-UX-1`/`FR-AX-1`/`D-18`) adds on top of `#21`'s original single-seed
  approach. `lib/theming/brand_tokens.dart` names the prototype palette
  (`docs/design/prototype.md` §Design tokens — plum/honey/gold/cream/ink/…) and is the **only**
  place brand hexes live; `lib/theming/app_theme.dart` maps those tokens onto the `ColorScheme`
  (honey `#F0A81F` is the single primary — the "one honey primary action" shared by
  `PrimaryActionButton`/`FilledButton` and the shell FAB — with a dark on-primary because
  white-on-honey fails AA). Every `on*` role is chosen for WCAG 2.2 AA and enforced in
  `test/theming/app_theme_contrast_test.dart`. Default `VisualDensity` (not compact) for
  gloves-friendly, large-tap-target field UX.
  - **Typography is bundled as assets** (offline-first — no `google_fonts`, no runtime/CDN
    fetching): static per-weight **Archivo** (400/500/600/700, the app-wide default for UI/body)
    and **Playfair Display** (600/700, for display/screen titles + brand) TTFs live under
    [`fonts/`](fonts/) with each family's `OFL.txt`, declared under `flutter: fonts:` in
    `pubspec.yaml`. This also fixes the shell header's old dangling `fontFamily: 'Playfair
Display'` that had no bundled font and fell back to Roboto.
- **i18n: Flutter `intl`** (`flutter gen-l10n`), EN default + a real (not lorem-ipsum) PT
  translation, per `NFR-I18N`.
- **Backend through the gateway (`#23`):** the `#21` provider-reachability placeholder is
  superseded — the app now logs in via OIDC (discovery-driven, provider-agnostic) and
  reads/writes apiaries local-first through PowerSync + the `sync` service (`/v1/sync/token`,
  `/v1/sync/batch`).

## PWA installability

Manifest, service worker (Flutter-generated at build time), icons, and hosting are covered by
`#93`. An automated Lighthouse CI installability audit runs in `build-publish.yml` on every
client change, plus a manual verification procedure (with a first pass already filled in) for
what a static-build audit can't check (real install prompt, offline shell serving) — see
[`docs/client/pwa-installability.md`](../docs/client/pwa-installability.md).

## Not in scope here (see `FOLLOWUPS.md`)

The PowerSync **web assets** (wasm SQLite + workers) and a few **deploy-time** wirings
(OIDC issuer/host resolution, the `/sync-stream` gateway route) are validated against the
live cluster — see `FOLLOWUPS.md`. The full-slice **Playwright e2e** lives in
[`e2e/`](e2e/). App icons (`web/icons/`, `web/favicon.png`) are Flutter's default placeholders —
real branded artwork is still needed (`#93`'s "real project app icons" AC).
