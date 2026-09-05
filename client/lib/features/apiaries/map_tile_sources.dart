/// The third-party tile endpoints the map renders from — in ONE place, because
/// a second place is what #671 was (FR-AP-3, D-16, NFR-SEC-1, NFR-CMP-1).
///
/// **Why this file exists at all.** These URLs are not just app config: they
/// are load-bearing input to `client/nginx.conf`'s Content-Security-Policy.
/// `flutter_map`'s `NetworkTileProvider` fetches every tile through
/// `package:http`, whose web implementation is `BrowserClient` — an
/// `XMLHttpRequest`. On the web a tile is therefore governed by the CSP's
/// **`connect-src`**, NOT by `img-src`, even though the bytes end up in an
/// `ImageProvider`. `connect-src` shipped without these hosts until #671, so
/// the moment #462 flips the header from `Content-Security-Policy-Report-Only`
/// to the enforcing `Content-Security-Policy`, every map view would have gone
/// blank: three screens, no error the user could act on, and nothing red in CI.
///
/// The templates were previously written out longhand in each of the three
/// screens that render a map, so "the set of hosts the map calls" was not a
/// thing any test could read. Now it is: [mapTileCspOrigins] derives the CSP
/// source expressions from the very strings the widgets pass to `TileLayer`,
/// and `client/test/map_tile_csp_test.dart` asserts nginx.conf's `connect-src`
/// names exactly them, in both directions. That test also scans every `.dart`
/// file under `client/lib/` for a `urlTemplate:`/`fallbackUrl:` written as a
/// string literal, so a tile source added anywhere — including in a map screen
/// that does not exist yet — fails the gate rather than quietly bypassing this
/// file the way the three screens used to.
///
/// **What this file does NOT settle.** A tile URL's `{z}/{x}/{y}` *is* the
/// coordinate being looked at, so every tile request tells Esri (US) and the
/// OSM Foundation where an apiary is, alongside the user's IP, with no consent
/// step (NFR-CMP-1 / GDPR, C-2). That is the second half of #671 and is a
/// product decision, not an engineering one — it stays open there and under
/// `Q-MAP`, which today holds the tile-provider question open on licensing and
/// production-scale load only. Nothing here forecloses any outcome: proxying
/// tiles through our own gateway, or self-hosting them, means changing these
/// templates to same-origin paths and dropping the hosts from `connect-src`
/// again; a consent gate means not mounting the `TileLayer` until consent is
/// given, and leaves these constants untouched.
library;

/// Esri World Imagery — the default satellite layer (D-16's #257 refinement).
///
/// No API key is required for this REST tile endpoint. Note the `{z}/{y}/{x}`
/// segment order: Esri's ArcGIS REST tile scheme puts the row (y) before the
/// column (x), unlike the `{z}/{x}/{y}` order [streetsTileUrlTemplate] uses.
const String satelliteTileUrlTemplate =
    'https://server.arcgisonline.com/ArcGIS/rest/services/'
    'World_Imagery/MapServer/tile/{z}/{y}/{x}';

/// The OpenStreetMap streets layer — the toggled-to alternative on the apiary
/// map (D-16, #257), for when road/place names are more useful than terrain.
const String streetsTileUrlTemplate =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

/// The `userAgentPackageName` every tile request identifies this app by.
///
/// Carried here so the two providers stay consistent. Note what it does NOT
/// do on this platform: `User-Agent` is a forbidden header name for XHR, so a
/// web build cannot set it and the OSM tile usage policy's identifiable-UA ask
/// is not actually satisfied by the PWA. That is a tile-provider concern, not a
/// CSP one — it belongs with `Q-MAP`, and the value is kept because the native
/// phase (D-10) will honour it.
const String mapTileUserAgentPackageName = 'com.beekeepingit.client';

/// Every tile template the app can fetch from, in one list so the CSP check is
/// exhaustive by construction rather than by somebody remembering.
const List<String> mapTileUrlTemplates = <String>[
  satelliteTileUrlTemplate,
  streetsTileUrlTemplate,
];

/// The CSP source expressions (scheme + host + port) those templates resolve
/// to, e.g. `https://tile.openstreetmap.org`.
///
/// Derived, never restated: [Uri.parse] tolerates the `{z}`/`{x}`/`{y}`
/// placeholders (they only ever appear in the path), and `Uri.origin` is
/// exactly the shape a CSP `connect-src` entry takes. A `Set`, because the two
/// providers could one day share an origin and the policy would list it once;
/// unmodifiable and lazily computed once (a top-level `final` in Dart is
/// initialized on first read), so a caller cannot mutate the policy's input.
///
/// A template with no authority — which is exactly what a same-origin tile
/// proxy or a self-hosted layer would be, e.g. `/tiles/{z}/{x}/{y}.png` — is
/// deliberately SKIPPED rather than parsed: `Uri.origin` throws on one, and a
/// same-origin path needs no `connect-src` entry because `'self'` already
/// covers it. So the set shrinks to `{}` on that migration instead of
/// crashing, and `client/test/map_tile_csp_test.dart`'s bidirectional check
/// then requires the hosts to come OUT of the policy in the same change.
final Set<String> mapTileCspOrigins = Set<String>.unmodifiable(<String>{
  for (final template in mapTileUrlTemplates)
    if (Uri.parse(template).hasAuthority) Uri.parse(template).origin,
});
