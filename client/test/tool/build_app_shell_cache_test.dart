import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/build_app_shell_cache.dart';

/// Unit tests for the app-shell precache generator (#619, FR-OF-1, FR-PL-1,
/// NFR-PER-1, D-10).
///
/// This is where #619's fourth acceptance criterion — "a new release
/// invalidates the cached shell so users are not pinned to an old build" —
/// becomes a *tested* property rather than a claim in a comment.
///
/// The mechanism it has to pin: `flutter build web` emits nothing
/// content-hashed (#678), so the service worker cannot key its cache on a
/// filename. It keys on a `BUILD_REVISION` this generator derives from the
/// bytes of every file in the bundle and injects into the worker script.
/// Because the browser's service-worker update check compares the WORKER
/// SCRIPT'S OWN BYTES, "one byte of the bundle changed" must imply "the worker
/// script changed", which must imply "a new cache name". The tests below assert
/// exactly that chain, plus the two ways it could go silently wrong: an
/// unchanged bundle producing a spuriously different worker (which would evict
/// every user's shell on a no-op rebuild), and a re-run producing a different
/// file (which would make the build non-reproducible).
///
/// `client/e2e/tests/offline-boot.spec.ts` is the behavioural other half: it
/// proves a real browser really boots from that cache with the network off.
void main() {
  late Directory bundle;

  setUp(() {
    bundle = Directory.systemTemp.createTempSync('app-shell-cache-test');
  });

  tearDown(() => bundle.deleteSync(recursive: true));

  /// Writes [contents] to [path] inside the fixture bundle.
  void write(String path, String contents) {
    final file = File('${bundle.path}/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  /// A bundle shaped like a real `flutter build web` output: the worker with
  /// its untouched marker region, plus one file of every class the generator
  /// has to sort — precached, runtime-cached and excluded.
  void writeBundle({String mainJs = 'console.log("v1");'}) {
    write('service_worker.js', _workerTemplate);
    write('index.html', '<!DOCTYPE html><title>BeekeepingIT</title>');
    write('main.dart.js', mainJs);
    write(
      'sw_register.js',
      'navigator.serviceWorker.register("service_worker.js");',
    );
    write('assets/fonts/Roboto/Roboto-Regular.ttf', 'font-bytes');
    write('canvaskit/canvaskit.wasm', 'engine-bytes');
    write('canvaskit/chromium/canvaskit.js', 'engine-loader');
    write('assets/NOTICES', 'licences');
    write('assets/AssetManifest.bin.json', '{}');
    write('font-fallback/NotoEmoji-Regular.ttf', 'emoji-face-bytes');
    write('font-fallback/OFL.txt', 'licence');
    write('flutter_service_worker.js', 'self.registration.unregister();');
    write('canvaskit/canvaskit.js.symbols', 'symbolication-table');
    write('.last_build_id', 'abc');
  }

  String worker() =>
      File('${bundle.path}/service_worker.js').readAsStringSync();

  group('classification', () {
    test('precaches every file on the boot path', () {
      writeBundle();

      final cache = generateAppShellCache(bundle);

      expect(
        cache.precache.map((entry) => entry.url),
        unorderedEquals(<String>[
          '/index.html',
          '/main.dart.js',
          '/sw_register.js',
          '/assets/fonts/Roboto/Roboto-Regular.ttf',
        ]),
        reason:
            'Exact, not `containsAll`: the install tier is what every user '
            'downloads on every release, so something silently joining it is '
            'as much a regression as something silently leaving it.',
      );
    });

    test('defers the CanvasKit variants and the licence blob to first use — '
        'precaching all six engine variants would make every release a ~46MB '
        'all-or-nothing download (NFR-PER-1)', () {
      writeBundle();

      final cache = generateAppShellCache(bundle);

      expect(
        cache.runtime.map((entry) => entry.url),
        unorderedEquals(<String>[
          '/canvaskit/canvaskit.wasm',
          '/canvaskit/chromium/canvaskit.js',
          '/assets/NOTICES',
          '/assets/AssetManifest.bin.json',
          '/font-fallback/NotoEmoji-Regular.ttf',
          '/font-fallback/OFL.txt',
        ]),
      );
      expect(
        cache.precache.map((entry) => entry.url),
        isNot(contains(startsWith('/canvaskit/'))),
      );
    });

    test('defers the emoji glyph-fallback face too — it is a fallback for text '
        'most users never type, and precaching it would cost every install '
        '(#673, D-37)', () {
      writeBundle();

      final cache = generateAppShellCache(bundle);

      expect(
        cache.precache.map((entry) => entry.url),
        isNot(contains(startsWith('/font-fallback/'))),
        reason:
            'A new BUILD_REVISION re-primes every installed shell, so the '
            'install tier is paid once per client per RELEASE — not once ever.',
      );
      // It is still IN the manifest: that is what `web/service_worker.js`
      // checks before it claims the engine's chunk URLs, and what makes its
      // bytes part of BUILD_REVISION.
      expect(
        cache.runtime.map((entry) => entry.url),
        contains('/font-fallback/NotoEmoji-Regular.ttf'),
      );
    });

    test('never caches the worker itself, Flutter\'s deprecation stub, '
        'symbolication tables or build bookkeeping', () {
      writeBundle();

      final cache = generateAppShellCache(bundle);
      final cached = [
        ...cache.precache,
        ...cache.runtime,
      ].map((entry) => entry.url);

      // The worker is stored by the browser, not the Cache API. The stub is
      // the self-unregistering file this whole issue is about. The other two
      // are ~8.6MB no browser ever requests.
      expect(cached, isNot(contains('/service_worker.js')));
      expect(cached, isNot(contains('/flutter_service_worker.js')));
      expect(cached, isNot(contains('/canvaskit/canvaskit.js.symbols')));
      expect(cached, isNot(contains('/.last_build_id')));
    });

    test('refuses a bundle path it cannot express as a JS string literal '
        'rather than emitting a worker that will not parse', () {
      writeBundle();
      // A space is legal in a filename on every platform this builds on, and
      // is exactly the kind of name that would otherwise reach the manifest
      // unescaped.
      write('assets/a name.txt', 'x');

      expect(
        () => generateAppShellCache(bundle),
        throwsA(
          isA<AppShellCacheException>().having(
            (error) => error.message,
            'message',
            contains('unsupported character'),
          ),
        ),
      );
    });
  });

  group('release invalidation (#619 AC 4)', () {
    test('a single changed byte anywhere in the bundle changes '
        'BUILD_REVISION, and therefore the cache name', () {
      writeBundle();
      final before = generateAppShellCache(bundle).buildRevision;

      writeBundle(mainJs: 'console.log("v2");');
      final after = generateAppShellCache(bundle).buildRevision;

      expect(
        after,
        isNot(before),
        reason:
            'the worker would open the same bkit-app-shell-<revision> cache '
            'for two different builds, pinning users to the old shell with no '
            'reload escape',
      );
    });

    test('a changed RUNTIME-tier file also changes BUILD_REVISION — the '
        'lazily cached engine must not be exempt from invalidation', () {
      writeBundle();
      final before = generateAppShellCache(bundle).buildRevision;

      write('canvaskit/canvaskit.wasm', 'engine-bytes-v2');
      final after = generateAppShellCache(bundle).buildRevision;

      expect(after, isNot(before));
    });

    test('a changed served-headers config changes BUILD_REVISION, even with an '
        'identical bundle', () {
      // The worker stores responses AS RECEIVED, so an installed client keeps
      // serving the document with the headers captured when its build
      // installed. A release that touches only nginx.conf would otherwise leave
      // the worker byte-identical, fire no update check, and never reach an
      // installed client — #89 (flipping the CSP from Report-Only to enforcing)
      // is exactly such a release.
      writeBundle();
      // Deliberately OUTSIDE the bundle: a file inside it would already be a
      // manifest entry, and the test would pass without the header input
      // existing at all.
      final headers = File(
        '${bundle.parent.path}/headers-${bundle.path.hashCode}.conf',
      );
      addTearDown(() => headers.deleteSync());
      headers.writeAsStringSync(
        'add_header Content-Security-Policy-Report-Only "…";',
      );
      final before = generateAppShellCache(
        bundle,
        servedHeaderConfig: [headers],
      ).buildRevision;

      headers.writeAsStringSync('add_header Content-Security-Policy "…";');
      final after = generateAppShellCache(
        bundle,
        servedHeaderConfig: [headers],
      ).buildRevision;

      expect(after, isNot(before));
    });

    test('an unchanged bundle produces an identical worker — a no-op rebuild '
        'must not evict every user\'s shell', () {
      writeBundle();
      generateAppShellCache(bundle);
      final first = worker();

      // A fresh generation over the same bytes, as a rebuild of the same
      // commit would do.
      writeBundle();
      generateAppShellCache(bundle);

      expect(worker(), first);
    });

    test('re-running over an already-generated worker is idempotent', () {
      writeBundle();
      generateAppShellCache(bundle);
      final first = worker();

      generateAppShellCache(bundle);

      expect(worker(), first);
    });
  });

  group('injection', () {
    test('replaces the marker region, keeps the code around it, and leaves the '
        'markers in place for the next run', () {
      writeBundle();

      final cache = generateAppShellCache(bundle);
      final source = worker();

      expect(
        source,
        contains('const BUILD_REVISION = "${cache.buildRevision}";'),
      );
      expect(source, contains('const PRECACHE = ['));
      expect(source, contains('const RUNTIME = ['));
      expect(source, contains(kManifestStartMarker));
      expect(source, contains(kManifestEndMarker));
      // The placeholder must be gone, and the surrounding worker untouched.
      expect(source, isNot(contains('"unbuilt"')));
      expect(source, contains('const CACHE_PREFIX = "bkit-app-shell-";'));
      expect(source, contains('self.addEventListener("fetch"'));
    });

    test('every entry carries a content revision, so the worker\'s own bytes '
        'are a function of the shell\'s bytes', () {
      writeBundle();

      final cache = generateAppShellCache(bundle);

      for (final entry in [...cache.precache, ...cache.runtime]) {
        expect(
          entry.revision,
          matches(RegExp('^[0-9a-f]{$kRevisionLength}\$')),
        );
        expect(
          worker(),
          contains('{ url: "${entry.url}", revision: "${entry.revision}" },'),
        );
      }
    });

    test(
      'refuses a bundle path that would carry a marker into the generated '
      'region — the SECOND run would splice the worker at the wrong line',
      () {
        writeBundle();
        write('assets/__APP_SHELL_MANIFEST_END__', 'x');

        expect(
          () => generateAppShellCache(bundle),
          throwsA(
            isA<AppShellCacheException>().having(
              (error) => error.message,
              'message',
              contains('collides with a manifest marker'),
            ),
          ),
        );
      },
    );

    test('fails loudly when the worker has lost its markers instead of '
        'silently shipping an empty manifest', () {
      writeBundle();
      write('service_worker.js', 'const PRECACHE = [];');

      expect(
        () => generateAppShellCache(bundle),
        throwsA(isA<AppShellCacheException>()),
      );
    });

    test('fails loudly on a bundle with no worker at all', () {
      write('index.html', '<!DOCTYPE html>');

      expect(
        () => generateAppShellCache(bundle),
        throwsA(
          isA<AppShellCacheException>().having(
            (error) => error.message,
            'message',
            contains('no service_worker.js'),
          ),
        ),
      );
    });
  });
}

/// The marker region as `client/web/service_worker.js` commits it, with just
/// enough of the surrounding worker to prove the injection does not disturb it.
const String _workerTemplate = '''
// __APP_SHELL_MANIFEST_START__
const BUILD_REVISION = "unbuilt";
const PRECACHE = [];
const RUNTIME = [];
// __APP_SHELL_MANIFEST_END__

const CACHE_PREFIX = "bkit-app-shell-";
const CACHE_NAME = CACHE_PREFIX + BUILD_REVISION;

self.addEventListener("fetch", (event) => {});
''';
