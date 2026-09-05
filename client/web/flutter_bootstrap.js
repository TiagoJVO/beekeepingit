// Flutter's web bootstrap. What `flutter build web` would generate on its own
// (flutter_tools' `generateDefaultFlutterBootstrapScript`), plus one addition —
// `config` — and minus one removal: `serviceWorkerSettings`.
//
// Why the removal (FR-OF-1, FR-PL-1, D-10, #619)
// ----------------------------------------------
// The default block asks `_flutter.loader` to register
// `flutter_service_worker.js`. Since flutter/flutter#156910 that generated file
// is an 815-byte DEPRECATION STUB — `install` → `skipWaiting()`, `activate` →
// `self.registration.unregister()` plus a reload of every client — whose only
// purpose is to remove a worker an older Flutter installed. Registering it
// leaves the app with zero service workers and zero caches after every load,
// which is exactly how the offline app shell #93 shipped went missing.
//
// It cannot merely be ignored, either: a registration is keyed by SCOPE, and
// the stub would take the same `/` scope our own worker needs — its
// `unregister()` would then be removing OUR registration. So the loader must
// not register it at all. `client/web/index.html` loads
// `client/web/sw_register.js`, which registers `client/web/service_worker.js`
// instead. Guarded by `client/test/app_shell_service_worker_test.dart` and, in
// a real browser against the deployed bundle, by
// `client/e2e/tests/offline-boot.spec.ts`.
//
// Why it exists (NFR-CMP, FR-OF-1, C-2, #620)
// -------------------------------------------
// `fontFallbackBaseUrl` defaults to `https://fonts.gstatic.com/s/`, and the
// engine builds two kinds of request on it: the Roboto it downloads on every
// cold load when no bundled family is named `Roboto` (that one is closed by
// bundling the family — see `pubspec.yaml`), and a Noto font it downloads
// mid-frame for any code point no registered font covers. Both carry the user's
// IP address to a third party, without consent, in an app that is
// Portugal-first (C-2) and whose whole premise is that it works with no signal
// (FR-OF-1) — where the fetch would simply fail anyway.
//
// Pinning the base URL to a RELATIVE path makes it same-origin by construction,
// in `flutter run` and in the served container alike: a deliberate trade of
// exotic-script coverage for "no third party on the boot path, ever".
//
// #673 (D-37) bought the reachable half of that coverage back without moving
// this line — emoji, which users do type into notes, now resolves from
// `web/font-fallback/NotoEmoji-Regular.ttf`. It needed no change HERE because
// the engine's emoji URLs are all under one family directory of this prefix;
// `nginx.conf` and `web/service_worker.js` are what map that directory onto the
// bundled face. Every other uncovered code point (CJK, Arabic, Hebrew) still
// renders as the missing-glyph box, deliberately.
//
// Being document-relative, the value resolves under the page's base href, which
// every build in this repo leaves at `/`. nginx's `location ^~ /font-fallback/`
// assumes exactly that; a `--base-href` would have to change both.
//
// The everyday case needs none of this: `pubspec.yaml` bundles Archivo,
// Playfair Display and Roboto, and Roboto (~896 code points: Latin Extended,
// Greek, Cyrillic, Vietnamese) is the engine's default fallback family.
{{flutter_js}}
{{flutter_build_config}}
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: "font-fallback/"
  }
});
