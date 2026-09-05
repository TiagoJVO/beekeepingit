// Generates the app-shell precache manifest inside a built bundle's
// `service_worker.js` (#619, FR-OF-1, FR-PL-1, NFR-PER-1, D-10).
//
//     dart run tool/build_app_shell_cache.dart build/web
//
// ## Why a build step exists at all
//
// `flutter build web` emits NOTHING content-hashed (#678): `main.dart.js`,
// `flutter_bootstrap.js`, `canvaskit/*`, `sqlite3.wasm`,
// `powersync_db.worker.js` and the per-build tree-shaken
// `MaterialIcons-Regular.otf` are all stable names whose bytes change every
// release. A service worker therefore cannot use a filename as a cache key, and
// there is no build-provided version to key on either (`version.json` carries
// pubspec's version, which does not move per commit).
//
// So this computes the missing key: a sha-256 per file, plus a `BUILD_REVISION`
// over all of them, injected INTO the worker script between its two markers.
// That injection is what makes the worker's own bytes change on every release,
// and the worker's bytes are exactly what the browser's service-worker update
// check compares — which is the whole cache-invalidation story (see the header
// comment of `web/service_worker.js`).
//
// ## Where it runs
//
// Immediately after every `flutter build web` — four sites today
// (`.github/workflows/build-publish.yml`, `helm-e2e.yml`, `release-deploy.yml`
// and `taskfiles/dart.yml`), kept honest by
// `scripts/check-app-shell-precache-wired.sh`, which fails the lint gate if a
// fifth site ever appears without it. Deliberately NOT a step inside
// `client/Dockerfile`: that image "only COPYs the prebuilt artifact" (its own
// header comment, mirrored by `admin/Dockerfile` and build-publish.yml), and
// putting the generator there would also make the offline shell impossible to
// exercise from a plain `flutter build web` / `flutter run` — the developer
// loop the manual offline pass in `docs/client/pwa-installability.md` depends
// on.
//
// Idempotent: it always rewrites the marked region from the directory's current
// contents, so re-running over an already-generated worker is safe and produces
// identical bytes for identical input.
//
// Dart rather than a shell script (this repo's other build glue is bash) for
// three reasons: `package:crypto` is already a direct dependency so sha-256
// costs nothing new; the Dart toolchain is present at all four call sites
// already; and, decisively, the logic is unit-testable —
// `test/tool/build_app_shell_cache_test.dart` is what makes the release-
// invalidation claim (#619's fourth acceptance criterion) a tested property
// rather than an assertion in a comment.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Marks the start of the machine-generated region in `service_worker.js`.
const String kManifestStartMarker = '__APP_SHELL_MANIFEST_START__';

/// Marks the end of the machine-generated region in `service_worker.js`.
const String kManifestEndMarker = '__APP_SHELL_MANIFEST_END__';

/// The worker script the manifest is injected into, relative to the bundle.
const String kWorkerFileName = 'service_worker.js';

/// The served-headers config, relative to the package root (`client/`).
///
/// Not a cache entry — nothing fetches it — but its bytes feed the build
/// revision, because the worker stores responses with the headers they arrived
/// with. See `_buildRevision`.
const String kServedHeaderConfig = 'nginx.conf';

/// How many hex characters of a sha-256 digest a revision keeps. 64 bits is far
/// more than enough to distinguish two builds of the same file, and keeping the
/// manifest short keeps the worker script (which every client re-downloads on
/// every update check) small.
const int kRevisionLength = 16;

/// Files that are never cached and never contribute to [BUILD_REVISION].
///
/// - [kWorkerFileName]: the browser stores the worker script itself; caching it
///   would pin the very file whose update check drives everything.
/// - `flutter_service_worker.js`: Flutter's self-unregistering deprecation stub
///   (#619). Nothing registers it any more, and caching it would only preserve
///   a landmine.
/// - `.last_build_id`: Flutter's build bookkeeping, never requested.
const Set<String> kExcludedPaths = {
  kWorkerFileName,
  'flutter_service_worker.js',
  '.last_build_id',
};

/// Suffixes that are never cached: symbolication tables for `flutter symbolize`
/// (~8.6 MB in a CanvasKit build) and source maps. No browser requests either.
const List<String> kExcludedSuffixes = ['.symbols', '.map'];

/// Files stored on FIRST USE instead of during `install`.
///
/// - `canvaskit/`: the engine ships six mutually exclusive variants (~38 MB) of
///   which a browser downloads exactly one pair (~5.9 MB on Chromium). The
///   worker's `install` has no browser to ask, so precaching them all would turn
///   every release into a ~46 MB download for a beekeeper on mobile data
///   (NFR-PER-1). Storing whichever one the engine actually picked, on the first
///   online load, caches exactly the one an offline boot then needs.
/// - `assets/NOTICES` (1.4 MB): only fetched when the licences page is opened.
/// - `assets/AssetManifest.bin.json`: the JSON companion of the `.bin` the
///   engine actually reads; tooling-only.
/// - `font-fallback/` (#673, D-37): the monochrome emoji face the web engine's
///   glyph fallback is served from (865 KB on disk, 589 KB gzipped on the
///   wire) plus its licence.
///   This is the one entry here whose tier is a JUDGEMENT rather than
///   an obvious saving, so it is worth stating: precaching it would put those
///   bytes on every install — that is once per client per RELEASE, since a new
///   [BUILD_REVISION] re-primes every installed shell — to cover a fallback for
///   text most users never type. Storing it on first use costs nothing at boot,
///   and from that first emoji onward it is offline-available exactly like a
///   precached asset. The cost of choosing the lazy tier is bounded and
///   narrow: a client that has never yet rendered an emoji, and is offline the
///   first time it meets one, still sees the missing-glyph box — which is
///   precisely the behaviour of every build before #673, so nothing regresses.
///   `web/service_worker.js` is what maps the engine's chunk URLs onto this
///   entry; there is no FILE with a chunk URL for the manifest to list.
///
/// They stay in the manifest, so their bytes still feed [BUILD_REVISION] and a
/// new engine still invalidates the whole cache.
bool isRuntimeCached(String path) =>
    path.startsWith('canvaskit/') ||
    path.startsWith('font-fallback/') ||
    path == 'assets/NOTICES' ||
    path == 'assets/AssetManifest.bin.json';

/// Bundle-relative paths may only contain these characters.
///
/// Anything else would need escaping inside the JS string literal this emits.
/// Flutter has never produced such a name; if it ever does, failing the build is
/// far better than shipping a worker script that does not parse.
final RegExp _safePath = RegExp(r'^[A-Za-z0-9._/-]+$');

/// A single manifest entry: a bundle-relative [path] and its content [revision].
class ShellEntry {
  const ShellEntry(this.path, this.revision);

  final String path;
  final String revision;

  /// The absolute URL the browser will request it as. Every build in this repo
  /// serves at base href `/` (see `web/flutter_bootstrap.js` and `nginx.conf`).
  String get url => '/$path';
}

/// What [generateAppShellCache] produced.
class AppShellCache {
  const AppShellCache({
    required this.buildRevision,
    required this.precache,
    required this.runtime,
  });

  /// Derived from every entry of both lists, so any changed byte anywhere in
  /// the bundle yields a different cache name in the worker.
  final String buildRevision;

  /// Downloaded during the worker's `install`.
  final List<ShellEntry> precache;

  /// Stored on first use — see [isRuntimeCached].
  final List<ShellEntry> runtime;

  String get summary =>
      'app-shell cache: build $buildRevision — ${precache.length} precached, '
      '${runtime.length} cached on first use';
}

/// Raised for every condition that must fail the build rather than ship a
/// silently broken worker.
class AppShellCacheException implements Exception {
  const AppShellCacheException(this.message);

  final String message;

  @override
  String toString() => 'AppShellCacheException: $message';
}

void main(List<String> arguments) {
  if (arguments.length != 1) {
    stderr.writeln(
      'usage: dart run tool/build_app_shell_cache.dart <built-bundle-dir>',
    );
    exitCode = 2;
    return;
  }
  try {
    // Run from `client/`, as all four build sites do.
    final headers = File(kServedHeaderConfig);
    if (!headers.existsSync()) {
      throw const AppShellCacheException(
        'no $kServedHeaderConfig in the working directory — run this from '
        'client/, so the served response headers are part of the revision',
      );
    }
    final cache = generateAppShellCache(
      Directory(arguments.single),
      servedHeaderConfig: [headers],
    );
    stdout.writeln(cache.summary);
  } on AppShellCacheException catch (error) {
    stderr.writeln('build_app_shell_cache: ${error.message}');
    exitCode = 1;
  }
}

/// Hashes every file of [bundle] and rewrites the marked region of its
/// `service_worker.js` with the resulting manifest.
///
/// [servedHeaderConfig] holds files that decide what HEADERS the shell is
/// served with. They are not cache entries, but their bytes feed
/// [AppShellCache.buildRevision] — see [kServedHeaderConfig].
AppShellCache generateAppShellCache(
  Directory bundle, {
  List<File> servedHeaderConfig = const [],
}) {
  if (!bundle.existsSync()) {
    throw AppShellCacheException('not a directory: ${bundle.path}');
  }
  final worker = File('${bundle.path}/$kWorkerFileName');
  if (!worker.existsSync()) {
    throw AppShellCacheException(
      'no $kWorkerFileName in ${bundle.path} — was web/$kWorkerFileName dropped '
      'from the bundle?',
    );
  }

  final precache = <ShellEntry>[];
  final runtime = <ShellEntry>[];

  // Sorted by path so an unchanged bundle always produces an identical worker,
  // and therefore no update check fires for a rebuild that changed nothing.
  final files =
      bundle
          .listSync(recursive: true)
          .whereType<File>()
          .map((file) => _relativePath(bundle, file))
          .toList()
        ..sort();

  for (final path in files) {
    // Exclusions FIRST: a file that never reaches the manifest cannot break it,
    // so a stray tool artifact with an odd name must not fail the whole build.
    if (kExcludedPaths.contains(path)) continue;
    if (kExcludedSuffixes.any(path.endsWith)) continue;

    if (!_safePath.hasMatch(path)) {
      throw AppShellCacheException(
        'unsupported character in bundle path: $path',
      );
    }
    // `_` is a legal path character, so a file could otherwise carry a marker
    // into the generated region — after which the SECOND run would splice the
    // worker at the injected line and emit a syntax error. The worker would
    // then simply fail to register, and `sw_register.js` swallows that: no
    // offline shell, nothing red.
    if (path.contains(kManifestStartMarker) ||
        path.contains(kManifestEndMarker)) {
      throw AppShellCacheException(
        'bundle path collides with a manifest marker: $path',
      );
    }

    final entry = ShellEntry(
      path,
      sha256
          .convert(File('${bundle.path}/$path').readAsBytesSync())
          .toString()
          .substring(0, kRevisionLength),
    );
    (isRuntimeCached(path) ? runtime : precache).add(entry);
  }

  if (precache.isEmpty) {
    throw AppShellCacheException(
      'no precacheable files under ${bundle.path} — refusing to ship an empty '
      'app shell',
    );
  }

  final cache = AppShellCache(
    buildRevision: _buildRevision(precache, runtime, servedHeaderConfig),
    precache: precache,
    runtime: runtime,
  );
  worker.writeAsStringSync(injectManifest(worker.readAsStringSync(), cache));
  return cache;
}

/// Replaces the region between the two markers in [source] with [cache]'s
/// manifest. Pure, so the unit test can assert on the result without a
/// filesystem.
String injectManifest(String source, AppShellCache cache) {
  final lines = const LineSplitter().convert(source);
  final start = lines.indexWhere((line) => line.contains(kManifestStartMarker));
  final end = lines.indexWhere((line) => line.contains(kManifestEndMarker));
  if (start < 0 || end < 0 || end < start) {
    throw const AppShellCacheException(
      'the worker script is missing its $kManifestStartMarker / '
      '$kManifestEndMarker markers, or they are in the wrong order',
    );
  }

  final manifest = <String>[
    'const BUILD_REVISION = "${cache.buildRevision}";',
    ..._emitList('PRECACHE', cache.precache),
    ..._emitList('RUNTIME', cache.runtime),
  ];

  final rewritten = [
    ...lines.take(start + 1),
    ...manifest,
    ...lines.skip(end),
  ].join('\n').trimRight();
  // Always LF, always exactly one trailing newline, whatever the checkout's
  // line endings were — the output has to be byte-identical for identical
  // input, on Windows as on Linux, or a rebuild would look like a new release.
  return '$rewritten\n';
}

List<String> _emitList(String name, List<ShellEntry> entries) => [
  'const $name = [',
  for (final entry in entries)
    '  { url: "${entry.url}", revision: "${entry.revision}" },',
  '];',
];

String _relativePath(Directory bundle, File file) {
  // `bundle.path` may carry a trailing separator (`build/web/`), and `listSync`
  // returns platform separators. Normalise both, then strip the prefix — never
  // by a computed length, which silently ate a character when the two
  // disagreed.
  final root = _withoutTrailingSeparator(bundle.path);
  var relative = file.path.substring(root.length);
  while (relative.startsWith('/') || relative.startsWith(r'\')) {
    relative = relative.substring(1);
  }
  // Only Windows separators become `/`. On a platform where `\` is a legal
  // filename character, translating it would launder a name past `_safePath`
  // instead of failing the build, which is the contract this file keeps.
  return Platform.isWindows ? relative.replaceAll(r'\', '/') : relative;
}

String _withoutTrailingSeparator(String path) {
  var trimmed = path;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') || trimmed.endsWith(r'\'))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
}

/// One revision over every entry of both classes, plus [servedHeaderConfig].
String _buildRevision(
  List<ShellEntry> precache,
  List<ShellEntry> runtime,
  List<File> servedHeaderConfig,
) {
  final buffer = StringBuffer();
  for (final entry in precache) {
    buffer.writeln('precache ${entry.revision} ${entry.path}');
  }
  for (final entry in runtime) {
    buffer.writeln('runtime ${entry.revision} ${entry.path}');
  }
  // The worker stores responses AS RECEIVED, so an installed client keeps
  // serving the document with the headers captured when its build installed.
  // Without this, a release that changes ONLY nginx.conf leaves the worker's
  // bytes identical, fires no update check, and never reaches installed clients
  // — indefinitely. #89 (flipping the CSP from Report-Only to enforcing) is
  // exactly such a release: it would apply to new visitors and silently not
  // apply to everyone who already has the app, with every gate green.
  for (final file in servedHeaderConfig) {
    buffer.writeln(
      'headers ${sha256.convert(file.readAsBytesSync())} ${file.path}',
    );
  }
  return sha256
      .convert(utf8.encode(buffer.toString()))
      .toString()
      .substring(0, kRevisionLength);
}
