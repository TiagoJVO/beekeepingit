import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the `web/` wiring that makes the offline app shell exist at all
/// (#619, FR-OF-1, FR-PL-1, NFR-PER-1, D-10).
///
/// The bug this replaces was invisible to every existing gate: Flutter's
/// generated `flutter_service_worker.js` became an 815-byte deprecation stub
/// (flutter/flutter#156910) that calls `self.registration.unregister()` on
/// activate, so the app ended every load with zero service workers and zero
/// caches and could not start without a network connection. Nothing failed —
/// the e2e always ran online, and the Lighthouse installability audit checks
/// that a worker is registered, not that it caches anything.
///
/// So the settings that fix it are pinned here, off-browser, in the fast gate:
/// the stub is no longer registered, our own worker is, and the worker source
/// is committed in the state the build expects to find it.
/// `client/test/tool/build_app_shell_cache_test.dart` covers the generator that
/// fills it, and `client/e2e/tests/offline-boot.spec.ts` proves the outcome in
/// a real browser against the deployed bundle. None of the three substitutes
/// for the others.
void main() {
  final indexHtml = File('web/index.html');
  final bootstrap = File('web/flutter_bootstrap.js');
  final worker = File('web/service_worker.js');
  final register = File('web/sw_register.js');
  final nginxConf = File('nginx.conf');

  group('registration', () {
    test('index.html loads the registration script', () {
      expect(
        indexHtml.readAsStringSync(),
        contains('src="sw_register.js"'),
        reason:
            'Nothing else registers the worker. Without this tag the app has '
            'no service worker at all and cannot start offline.',
      );
    });

    test('the registration script is a FILE, not an inline snippet — '
        "nginx.conf's script-src has no 'unsafe-inline'", () {
      expect(register.existsSync(), isTrue);

      // Read the DIRECTIVE out of the real header, not the file. nginx.conf
      // explains its own CSP at length, so a whole-file `contains` would be
      // satisfied by the commentary even if the header itself were deleted —
      // and a bare "does not contain 'unsafe-inline'" would miss the realistic
      // regression, someone appending it to the existing directive.
      final scriptSrc = _cspDirective(
        nginxConf.readAsStringSync(),
        'script-src',
      );

      expect(scriptSrc, contains("'self'"));
      expect(
        scriptSrc,
        isNot(contains('unsafe-inline')),
        reason:
            'The registration lives in its own file precisely because inline '
            'script is not allowed. Allowing it here would quietly remove the '
            'reason that file exists.',
      );
    });

    test('it registers our worker by a document-relative path, so the scope is '
        'the app root under any base href', () {
      final source = register.readAsStringSync();

      expect(
        source,
        contains('navigator.serviceWorker.register("service_worker.js"'),
      );
      expect(
        source,
        isNot(contains('register("/')),
        reason:
            'A root-absolute path would stop matching the day a build passes '
            '--base-href, exactly like the font-fallback prefix in '
            'flutter_bootstrap.js / nginx.conf.',
      );
    });

    test("flutter_bootstrap.js does NOT ask Flutter's loader to register "
        'flutter_service_worker.js', () {
      // Comments stripped: the file explains the removal at length, and prose
      // about `serviceWorkerSettings` must not read as the setting itself.
      final code = _withoutComments(bootstrap.readAsStringSync());

      // A registration is keyed by SCOPE. The stub would take the same `/`
      // scope our worker needs, and its `unregister()` on activate would then
      // be removing OUR registration. Confirmed against the pinned Flutter:
      // with no `serviceWorkerSettings`, flutter.js's `loadServiceWorker`
      // returns immediately without registering anything.
      expect(code, isNot(contains('serviceWorkerSettings')));
      expect(code, isNot(contains('flutter_service_worker')));
      // The rest of the loader contract must still be the generated default —
      // see fonts_local_fallback_test.dart for the other half of that claim.
      expect(code, contains('_flutter.loader.load({'));
    });
  });

  group('the committed worker source', () {
    test('carries the marker region the build generator replaces', () {
      final source = worker.readAsStringSync();

      expect(source, contains('__APP_SHELL_MANIFEST_START__'));
      expect(source, contains('__APP_SHELL_MANIFEST_END__'));
    });

    test('is committed UNGENERATED, so a stale manifest can never be shipped '
        'from the repo instead of from the build', () {
      final source = worker.readAsStringSync();

      expect(source, contains('const PRECACHE = [];'));
      expect(source, contains('const RUNTIME = [];'));
      expect(source, contains('const BUILD_REVISION = "unbuilt";'));
    });

    test('stays inert when the manifest was never generated, rather than '
        'half-caching a build nobody hashed', () {
      final source = worker.readAsStringSync();

      expect(source, contains('const isBuilt = PRECACHE.length > 0;'));
      expect(source, contains('if (!isBuilt) return;'));
    });

    test('an ungenerated worker deletes nothing — an unguarded activate would '
        'sweep every real build\'s shell and reproduce #619 exactly', () {
      // `activate` is where the damage would be: an unbuilt worker's CACHE_NAME
      // is `bkit-app-shell-unbuilt`, so every OTHER `bkit-app-shell-*` cache
      // matches the sweep. It must return before reaching it.
      final activate = _functionBody(worker.readAsStringSync(), 'activate');

      expect(activate, contains('if (!isBuilt) return;'));
      expect(
        activate.indexOf('if (!isBuilt) return;'),
        lessThan(activate.indexOf('caches.delete')),
      );
    });

    test('never answers a navigation to a server-routed path from cache — the '
        'gateway peels those off before nginx ever sees them', () {
      // The worker's scope is the whole ORIGIN, not just what the PWA container
      // serves: infra/helm/beekeepingit/charts/gateway routes /v1/* and
      // /sync-stream to backend services. "Answer any navigation with
      // index.html, as the SPA fallback would" is true for nginx's paths and
      // false for these.
      final source = worker.readAsStringSync();

      // Deliberately NOT pinned to the exact literal. Which prefixes belong in
      // that array is decided by the gateway chart, and
      // scripts/check-service-worker-routes.sh (#683) is what holds the two in
      // agreement — reading the array out of this file and the app-host routes
      // out of infra/helm/beekeepingit/charts/gateway/values.yaml. Asserting the
      // literal here would make this a THIRD hand-maintained copy: adding a
      // gateway route would then correctly update the chart and the worker and
      // still turn this test red, for no defect. What this test owns is the part
      // the shell gate structurally cannot see — that the list exists, is
      // non-empty, and is actually CONSULTED by the navigation branch.
      expect(
        source,
        matches(RegExp(r'const SERVER_ROUTED_PREFIXES = \["/[^\]]*\];')),
      );
      expect(
        source,
        contains(
          'if (SERVER_ROUTED_PREFIXES.some((prefix) => '
          'url.pathname.startsWith(prefix))) return;',
        ),
      );
    });

    test('refuses to cache the SPA fallback document under an asset path — '
        'nginx answers ANY miss with 200 + index.html', () {
      // `response.ok` is not an integrity check on this server: `try_files $uri
      // $uri/ /index.html` means a moved asset returns the HTML document with a
      // 200. Without this guard, `install` would SUCCEED and cache index.html
      // under every asset path — a shell that installs cleanly and then boots
      // offline into nothing.
      final source = worker.readAsStringSync();

      expect(source, contains('function assertRealAsset('));
      expect(source, contains('SPA fallback document'));
      expect(source, contains('response.redirected'));
    });

    test('reaches no third party — a worker sits in front of every request the '
        'app makes (#620, NFR-CMP, C-2)', () {
      final code = _withoutComments(worker.readAsStringSync());

      expect(
        code,
        isNot(contains('://')),
        reason:
            'No absolute URL of any kind: importScripts from a CDN, or a '
            'cached third-party asset, would break same-origin-boot.spec.ts '
            "and nginx.conf's worker-src 'self'.",
      );
      expect(code, isNot(contains('importScripts')));
    });
  });

  group('serving', () {
    test('nginx gives the worker no location block of its own — one would '
        'cancel inheritance of every server-level header, COOP/COEP included', () {
      final conf = nginxConf.readAsStringSync();

      // The trap (#89, guarded live by cache-headers.spec.ts): in nginx an
      // `add_header` inside a `location {}` cancels inheritance of ALL
      // server-level `add_header` directives. Losing COOP/COEP loses
      // cross-origin isolation, SharedArrayBuffer, and with it PowerSync's
      // wasm/OPFS sync worker — silently. The worker script needs nothing
      // special anyway: `Cache-Control: no-cache` is already the server-wide
      // default, which is exactly right for the file whose update check drives
      // every release.
      expect(conf, isNot(contains('location = /service_worker.js')));
      expect(conf, isNot(contains('location /service_worker.js')));
      expect(conf, contains('add_header Cache-Control "no-cache" always;'));
    });
  });
}

/// The value of one directive of the `Content-Security-Policy…` header that
/// [conf] actually SENDS — not any of the prose around it.
String _cspDirective(String conf, String directive) {
  final header = conf
      .split('\n')
      .map((line) => line.trim())
      .firstWhere(
        (line) => line.startsWith('add_header Content-Security-Policy'),
        orElse: () => '',
      );
  expect(
    header,
    isNotEmpty,
    reason: 'nginx.conf sends no Content-Security-Policy header',
  );

  final match = RegExp('(?:^|;)\\s*$directive\\s([^;"]*)').firstMatch(header);
  expect(match, isNotNull, reason: 'the CSP has no $directive directive');
  return match!.group(1)!;
}

/// The body of the top-level `async function [name](...)` in [source].
///
/// Crude but sufficient: these are hand-written files with one definition per
/// name and a closing brace in column 0. It exists so an assertion can be about
/// ORDER inside one function (a guard before the destructive call), which a
/// whole-file `contains` cannot express.
String _functionBody(String source, String name) {
  final start = source.indexOf('async function $name(');
  expect(
    start,
    greaterThanOrEqualTo(0),
    reason: 'no `async function $name` in the worker',
  );
  final end = source.indexOf('\n}\n', start);
  expect(
    end,
    greaterThan(start),
    reason: '`$name` has no closing brace in column 0',
  );
  return source.substring(start, end);
}

/// Strips whole-line `//`, `/*` and ` * ` comments from JavaScript [source].
///
/// Every assertion here is about what a file DOES, and both files document at
/// length the very setting they are asserted not to contain — so matching raw
/// text would fail on the explanation rather than on the behaviour. Line-based
/// on purpose: neither file carries trailing comments, and a real tokenizer
/// would be far more machinery than the claim needs.
String _withoutComments(String source) => source
    .split('\n')
    .where((line) {
      final trimmed = line.trimLeft();
      return !trimmed.startsWith('//') &&
          !trimmed.startsWith('*') &&
          !trimmed.startsWith('/*');
    })
    .join('\n');
