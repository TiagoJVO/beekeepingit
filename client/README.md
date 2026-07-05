# client

The Flutter field app (`D-5`) — **Web/PWA first, native later** (`D-10`). This is the
skeleton scaffolded by `#21`: shell, routing, theming, state management and an i18n
scaffold. The walking-skeleton slice UI (login, apiary list/create/edit) lands with `#23`;
see [`docs/architecture/walking-skeleton.md`](../docs/architecture/walking-skeleton.md).

## Run it

```sh
flutter pub get
flutter run -d chrome
```

To point at a gateway host other than the local k3d dev mapping
(`https://keycloak.beekeepingit.local:8443`, see `infra/README.md`), pass:

```sh
flutter run -d chrome --dart-define=GATEWAY_BASE_URL=https://your-gateway-host
```

`flutter build web` produces the installable PWA bundle (`build/web/`) — web app manifest

- the service worker Flutter generates at build time for app-shell caching.

## Structure

| Path                        | What's there                                                                                                                                                                                                 |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `lib/app.dart`, `main.dart` | App bootstrap: `ProviderScope`, `MaterialApp.router`                                                                                                                                                         |
| `lib/routing/`              | [go_router](https://pub.dev/packages/go_router) config — home (`/`) + a placeholder apiary-detail route (`/apiaries/:id`)                                                                                    |
| `lib/theming/`              | Light/dark Material 3 `ThemeData`                                                                                                                                                                            |
| `lib/l10n/`                 | i18n scaffold — `arb/app_{en,pt}.arb` source strings (`flutter gen-l10n`); generated `gen/` output is committed (matches `services/shared`'s committed `sqlc` output — no codegen step needed to build/test) |
| `lib/core/config/`          | Compile-time config (`--dart-define`) — the gateway base URL                                                                                                                                                 |
| `lib/core/network/`         | `gatewayReachabilityProvider` — see below                                                                                                                                                                    |
| `lib/features/`             | One folder per screen/feature (`home`, `apiary_detail` today)                                                                                                                                                |

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
- **"Calls a backend endpoint through the gateway" (AC5):** no domain Go service exists yet
  (`#20`/`#23` are still open) — the one real backend routed through the platform gateway
  today is Keycloak (`infra/helm/beekeepingit/charts/gateway`, landed by `#84`). The home
  screen's gateway-status indicator calls Keycloak's OIDC discovery document
  (`GET {gatewayBaseUrl}/realms/beekeepingit/.well-known/openid-configuration`) through the
  gateway — a genuine reachability check against the real platform, not a stub. It gets
  superseded by real API calls once `#23` lands the `apiaries`/`sync` services.

## Not in scope here (see `FOLLOWUPS.md`)

Manual browser/device QA (PWA install, offline app-shell caching, both locales rendering)
wasn't done in this session — no GUI browser was available. Run `flutter run -d chrome`
once to confirm before/soon after this merges. App icons (`web/icons/`, `web/favicon.png`)
are Flutter's default placeholders, not real artwork.
