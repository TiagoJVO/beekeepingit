// Flutter's web bootstrap. Byte-for-byte the file `flutter build web` would
// generate on its own (flutter_tools' `generateDefaultFlutterBootstrapScript`,
// service-worker settings included), plus exactly ONE addition: `config`.
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
// in `flutter run` and in the served container alike. Nothing under it is
// bundled today, so an uncovered code point renders as the missing-glyph box
// instead of reaching Google: a deliberate trade of exotic-script coverage for
// "no third party on the boot path, ever". Whether that is the right trade for
// emoji specifically — which users do type into notes — is #673; `nginx.conf`
// already serves this prefix with `try_files $uri =404`, so bundling a face
// under `web/font-fallback/` needs no code change here.
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
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  config: {
    fontFallbackBaseUrl: "font-fallback/"
  }
});
