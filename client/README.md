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

`--no-web-resources-cdn` bundles the **CanvasKit engine payload** locally instead of fetching it
from Google's CDN at runtime (`www.gstatic.com`) — without it the app renders a blank page
wherever that CDN is unreachable (corporate networks, offline). `task dart:build` /
`flutter build web` already always pass this flag; it matters for `flutter run` too, since
an offline-first field app must not depend on external network reachability just to paint
its first frame. It does **not** cover the engine's own font fetches from `fonts.gstatic.com` —
those are closed separately, see the typography bullets under
[Decisions this scaffold makes](#decisions-this-scaffold-makes-ac-of-21) below (`#620`).

To point at a gateway host other than the local k3d dev mapping
(`https://app.beekeepingit.local:8443`, see `infra/README.md`), pass:

```sh
flutter run -d chrome --no-web-resources-cdn --dart-define=GATEWAY_BASE_URL=https://your-gateway-host
```

`flutter build web` produces the installable PWA bundle (`build/web/`): the web app manifest,
the icons, and this repo's own app-shell service worker (`web/service_worker.js`).

**The build is two steps, not one.** Flutter no longer generates a caching service worker —
since [flutter/flutter#156910](https://github.com/flutter/flutter/issues/156910) the generated
`flutter_service_worker.js` is a self-unregistering deprecation stub, which is why the app
silently lost its offline shell (#619). This repo ships its own worker instead, and because
nothing `flutter build web` emits is content-hashed (#678) that worker gets its cache key from a
manifest generated **after** the build:

```sh
flutter build web --release --no-web-resources-cdn
dart run tool/build_app_shell_cache.dart build/web
```

Skip the second step and the worker ships inert — it installs, caches nothing, and the app
cannot start without a connection. Every build site in CI runs both, and
`scripts/check-app-shell-precache-wired.sh` (in `task lint`) fails if one ever stops.

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

| Path                        | What's there                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `lib/app.dart`, `main.dart` | App bootstrap: `ProviderScope`, `MaterialApp.router`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `lib/routing/`              | [go_router](https://pub.dev/packages/go_router) config — `/login`, onboarding gates (`/profile`, `/organization/new`), an auth redirect, and the post-onboarding app shell (`StatefulShellRoute.indexedStack`, one nav stack per tab): apiaries, activities, home, journeys, todos; `/organization/members`, `/account`, `/organization/details`, `/stock-declarations` and `/sync-needs-fix` sit outside the shell. **`/home` is the landing screen** and the post-login / post-onboarding redirect target (`#658`, `D-35`, `D-29` as amended). Branch order must match `AppShell.tabs` — tab position is branch position |
| `lib/shell/`                | The persistent app shell (`FR-UX-2`, `#197`) — 5-tab bottom nav (apiaries · activities · **home** · journeys · todos, `#658`/`D-35`), header (contextual back, brand + screen title, sync-status pill, account), contextual honey FAB, offline banner. Every tab has a real screen; Home and Activities carry no FAB, having no single right create action                                                                                                                                                                                                                                                                 |
| `lib/theming/`              | Light/dark Material 3 `ThemeData` (`app_theme.dart`) hand-built from the Melargil brand tokens (`brand_tokens.dart`) — the single source of truth for every brand hex; plus the bundled brand fonts under `../fonts/` (see Theming below)                                                                                                                                                                                                                                                                                                                                                                                  |
| `lib/l10n/`                 | i18n scaffold — `arb/app_{en,pt}.arb` source strings plus the `app_{en_GB,pt_PT}.arb` region markers (`D-34`) (`flutter gen-l10n`); generated `gen/` output is committed (matches `services/shared`'s committed `sqlc` output — no codegen step needed to build/test)                                                                                                                                                                                                                                                                                                                                                      |
| `lib/core/config/`          | Compile-time config (`--dart-define`) — gateway/OIDC/PowerSync URLs (see the table above)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  |
| `lib/core/auth/`            | Provider-agnostic OIDC Authorization Code + PKCE flow via `openid_client` (discovery-driven; web redirect behind a conditional import so widget tests compile on the VM)                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| `lib/core/sync/`            | PowerSync schema + backend connector (`fetchCredentials`→`/v1/sync/token`, `uploadData`→`/v1/sync/batch`) + the DB provider; the connector also parses per-op `superseded` results into a notify-and-fix event stream (`sync.md` §4.2/§8, `#58`) consumed by `lib/shell/sync_status.dart`'s real `syncStatusProvider`/`syncNowProvider`                                                                                                                                                                                                                                                                                    |
| `lib/core/api/`             | Generic REST scaffold (`ApiClient`) — base URL + bearer injection (reuses `core/auth`'s access token), typed JSON, RFC 9457 `ApiException` mapping. Not profile-specific — other features reuse it (`#25`)                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `lib/core/l10n/`            | `supported_locales.dart` (the shipped locale set `en-GB`/`pt-PT` and the normalization every stored locale code goes through, `D-34`/`#656`), `LocaleFormatting` (display) and `LocalizedNumberInput` (typed input) — locale-aware date/number handling on `intl` (`NFR-I18N-1`, `#77`, `#623`); see [Translations (i18n)](#translations-i18n) below                                                                                                                                                                                                                                                                       |
| `lib/features/`             | One folder per screen/feature (`auth`, `apiaries`, `activities`, `home`, `journeys`, `todos`, `history`, `notifications`, `stock_declarations`, `sync`, `profile`, `organization`, `members`, `account`, `settings`)                                                                                                                                                                                                                                                                                                                                                                                                       |
| `web/`                      | The bundle's non-Dart sources, copied verbatim into `build/web/`: `index.html`, `manifest.json`, `icons/`, the repo-controlled `flutter_bootstrap.js` override (`#620`), and the app-shell service worker `service_worker.js` with its registration script `sw_register.js` (`#619`)                                                                                                                                                                                                                                                                                                                                       |
| `tool/`                     | Build-time tooling run **against the built bundle** — today `build_app_shell_cache.dart`, which injects the service worker's per-release precache manifest (`#619`). Runs after every `flutter build web`; unit-tested in `test/tool/`                                                                                                                                                                                                                                                                                                                                                                                     |

## Translations (i18n)

**British English (`en-GB`) + European Portuguese (`pt-PT`)** today — the two
locales the app supports (`D-34`, `#656`), structured to add more languages
later without touching feature screens (`NFR-I18N-1`, `#77`/`#78`).

> **Why the region codes matter.** Generic `pt`/`en` are not neutral: CLDR
> resolves them to **Brazilian** and **American** conventions (`1.234,5`,
> `Sep 3, 2026`). `pt-PT` groups thousands with a non-breaking space and
> `en-GB` puts the day first. Three consequences to know about:
>
> - **The offered set is `kSupportedLocales`** (`lib/core/l10n/supported_locales.dart`),
>   which is what `app.dart` hands `MaterialApp` — **not**
>   `AppLocalizations.supportedLocales`, which also lists the generic `en`/`pt`
>   base ARBs `gen-l10n` requires behind each region variant. Widget tests
>   should pass `kSupportedLocales` too, or they exercise a locale set the app
>   never uses.
> - **Dates are the one place the app overrides CLDR.** `LocaleFormatting`
>   pins `d MMM y` for both locales — `3 set. 2026` / `3 Sept 2026` — rather
>   than taking each locale's medium default, which for `pt-PT` is the numeric
>   `d/MM/y`. A named month cannot be misread in the field; `3/09` vs `09/03`
>   can. Numbers follow CLDR unchanged.
> - **Anything reading a locale must keep the country** — `toLanguageTag()`,
>   never `languageCode`.

**Typing numbers** goes through `LocalizedNumberInput` (`NFR-I18N-1`,
`FR-AC-1`, `#623`, `#657`), which every numeric form field shares. A grouping
separator is always followed by exactly three digits and a decimal separator
by any number, so:

- the active locale's decimal separator always wins (`40,5` → 40.5 in
  `pt-PT`);
- a separator that **cannot** mean thousands is read as the decimal point,
  whichever character it is — `40.5` in `pt-PT` and `40,5` in `en-GB` are both
  40.5;
- where the input genuinely could mean thousands, the **locale** decides:
  `1,234` is 1234 in `en-GB` (its own grouping separator), while `1.234` in
  `pt-PT` is **rejected** — the dot is neither that locale's decimal nor its
  grouping character, so there is no rule to break the tie and guessing would
  be a 1000x error;
- anything with no coherent reading is still rejected visibly and blocks the
  save. A number is never silently rewritten into a different one.

Source strings are
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
   (`app_en.arb` and `app_pt.arb` hold every string; `app_en_GB.arb` and
   `app_pt_PT.arb` carry only `@@locale` and inherit them — see the header of
   `l10n.yaml` for why those two files exist.)
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
  exists in every other base-language ARB file, and vice versa — a key added to one
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

## Tests

`flutter test` from this directory runs the whole suite (unit + widget).

`test/flutter_test_config.dart` is loaded automatically for every test file
and stubs out the one thing no widget test can do for real: **opening the
on-device PowerSync database**. `PowerSyncDatabase` registers its path in a
process-wide instance registry from its constructor and only deregisters on
`close()` — which under `testWidgets` never happens, because
`initialize()` stays pending there (real disk/isolate I/O doesn't progress
under the widget binding's fake-async clock), so `powerSyncProvider` never
reaches its teardown. Every widget test therefore leaked one entry and the
run filled up with
`[PowerSync] WARNING: Multiple instances for the same database ...` (`#286`).
The stub (`debugOpenPowerSyncDatabase` in `lib/core/sync/powersync_service.dart`)
keeps `powerSyncProvider` pending, exactly as it already behaved in widget
tests, without opening anything. A test that needs a **resolved** sync
session overrides the providers it actually depends on (`syncStatusProvider`,
a repository's stream provider, …) — see `test/account_screen_test.dart` and
`test/app_shell_test.dart`; `await`ing `powerSyncProvider` itself without an
override hangs until the test times out. A test that deliberately wants the
**real** database (a plain `test()`, not a widget test — the open does
complete there) opts back in by setting `debugOpenPowerSyncDatabase = null`
and restoring it in an `addTearDown`.

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
  - **Roboto is bundled too — as the glyph fallback, not as a brand face** (`#620`, `NFR-CMP`,
    `FR-OF-1`, `C-2`). CanvasKit needs a default family and hardcodes the name `Roboto`: with no
    such family in `FontManifest.json` it downloads one from `fonts.gstatic.com` on **every cold
    load**, which `--no-web-resources-cdn` does not suppress (that flag only localises the
    CanvasKit engine payload). Bundling the family stops the request, and widens fallback coverage
    from Archivo/Playfair's ~230 code points each to ~896 (Latin Extended, Greek, Cyrillic,
    Vietnamese). The file is the exact Roboto the Flutter SDK ships, so
    [`fonts/Roboto/LICENSE.txt`](fonts/Roboto/LICENSE.txt) is Apache-2.0 rather than the OFL the
    two brand families carry.
  - **The per-code-point fallback is pinned to our own origin.** For a code point _no_ registered
    font covers, the engine downloads a Noto font from `fontFallbackBaseUrl`, which defaults to
    `https://fonts.gstatic.com/s/`. [`web/flutter_bootstrap.js`](web/flutter_bootstrap.js) — the
    only reason this repo overrides Flutter's generated bootstrap at all — pins it to the relative
    path `font-fallback/`. Nothing is bundled there, so such a code point renders as the
    missing-glyph box: a deliberate trade against disclosing every user's IP address to Google, on
    a boot path that must work with no signal at all anyway. The reachable case is **emoji** in
    user-entered text, and whether that trade holds for it is `#673`; `nginx.conf` already routes
    the prefix with `try_files $uri =404`, so bundling a face under `web/font-fallback/` needs no
    code change. Both settings are pinned by
    [`test/fonts_local_fallback_test.dart`](test/fonts_local_fallback_test.dart) and the outcome by
    [`e2e/tests/same-origin-boot.spec.ts`](e2e/tests/same-origin-boot.spec.ts).
- **i18n: Flutter `intl`** (`flutter gen-l10n`), EN default + a real (not lorem-ipsum) PT
  translation, per `NFR-I18N`.
- **Backend through the gateway (`#23`):** the `#21` provider-reachability placeholder is
  superseded — the app now logs in via OIDC (discovery-driven, provider-agnostic) and
  reads/writes apiaries local-first through PowerSync + the `sync` service (`/v1/sync/token`,
  `/v1/sync/batch`).

## PWA installability

Manifest, icons and hosting are covered by `#93`; the app-shell service worker is this repo's
own (`web/service_worker.js`, #619 — see the build note above). An automated Lighthouse CI
installability audit runs in `build-publish.yml` on every client change, and
`e2e/tests/offline-boot.spec.ts` takes a real browser offline against the deployed bundle and
asserts the shell renders. A manual pass remains for what neither can check (the real install
prompt on a device) — see
[`docs/client/pwa-installability.md`](../docs/client/pwa-installability.md).

## Not in scope here

The PowerSync **web assets** (wasm SQLite + workers) and a few **deploy-time** wirings
(OIDC issuer/host resolution, the `/sync-stream` gateway route) were validated against the
live cluster in `#23` (#160). The full-slice **Playwright e2e** lives in
[`e2e/`](e2e/). App icons (`web/icons/`, `web/favicon.png`) are Flutter's default placeholders —
real branded artwork is still needed (`#93`'s "real project app icons" AC, tracked in #233).
