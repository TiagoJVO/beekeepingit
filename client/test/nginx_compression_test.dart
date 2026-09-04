import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the compression settings in `nginx.conf` (#670, NFR-PER-1, FR-OF-1,
/// C-2, D-10).
///
/// `client/e2e/tests/compression.spec.ts` proves the OUTCOME in a real browser
/// against the deployed image — that `main.dart.js` and the CanvasKit `.wasm`
/// really do arrive gzip-encoded and really are smaller on the wire. This file
/// exists for the properties a live probe structurally cannot see, following
/// the same split `app_shell_service_worker_test.dart` states for #619:
///
///  - **`text/html` must stay ABSENT from `gzip_types`.** nginx always
///    compresses `text/html`, and listing it explicitly logs a duplicate-MIME
///    warning. Both spellings put `Content-Encoding: gzip` on the document, so
///    the e2e's `/index.html` probe stays green either way.
///  - **`application/octet-stream` must stay ABSENT.** It is nginx's
///    `default_type`, so listing it would compress every file the mime.types
///    map does not recognise — the `.png` icons included. The e2e covers this
///    only INDIRECTLY, through a `.ttf` probe that stops covering it the day
///    #688 gives `.ttf` a real type.
///  - **The directives must stay at server level.** Everything in this file's
///    `server {}` inherits six `add_header` directives, and the whole block
///    lives above the first `location {}` on purpose (#89).
///
/// Neither substitutes for the other, and neither substitutes for reading the
/// numbers the e2e prints.
void main() {
  final conf = _directivesOf(File('nginx.conf').readAsStringSync());
  final types = _gzipTypes(conf);

  group('compression is on, and configured the way #670 measured', () {
    test('gzip is enabled with the settings the comment argues for', () {
      expect(conf, contains('gzip on;'));
      // A shared cache must key a compressed answer separately from an
      // uncompressed one.
      expect(conf, contains('gzip_vary on;'));
      // Traefik sets no `Via` today, so this is inert — but the default (`off`)
      // would silently disable compression the day a hop does set one.
      expect(conf, contains('gzip_proxied any;'));
      // Level 2 is a deliberate concession to the pwa pod's 100m CPU limit
      // (#693), not a default. If this moves, the measured table in the file's
      // comment and in docs/client/pwa-installability.md moves with it.
      expect(conf, contains('gzip_comp_level 2;'));
      // 256, not the kilobyte a stock config uses: `manifest.json` is 856 B and
      // compresses 56.9%. Raising this back past ~900 would silently stop
      // compressing it, and the e2e's `/manifest.json` probe is what would go
      // red.
      expect(conf, contains('gzip_min_length 256;'));
    });

    test('every type #670 requires is covered', () {
      // The `.js` spelling nginx's mime.types maps to has changed across
      // releases; neither is worth depending on, so both are listed.
      expect(types, contains('application/javascript'));
      expect(types, contains('text/javascript'));
      expect(types, contains('application/json'));
      // The largest single file the app downloads.
      expect(types, contains('application/wasm'));
      expect(types, contains('image/svg+xml'));
      expect(types, contains('text/css'));
    });

    test('text/html is NOT listed — nginx always compresses it', () {
      expect(
        types,
        isNot(contains('text/html')),
        reason:
            'nginx pre-seeds text/html into gzip_types, so listing it logs a '
            'duplicate-MIME warning. No live probe can catch this: the document '
            'is compressed either way.',
      );
    });

    test('application/octet-stream is NOT listed — it is the default_type', () {
      expect(
        types,
        isNot(contains('application/octet-stream')),
        reason:
            'That is what nginx serves every file its mime.types does not '
            'recognise, so listing it would compress the .png icons and every '
            'other binary the bundle ships — the exact opposite of #670\'s '
            '"already-compressed types are excluded".',
      );
    });

    test('already-compressed formats are not named', () {
      // The allow-list IS the exclusion mechanism; there is no negative
      // directive to assert against.
      expect(types, isNot(contains('image/png')));
      expect(types, isNot(contains('font/woff2')));
    });

    test('the directives sit at server level, above every location block', () {
      // In nginx an `add_header` inside a `location {}` cancels inheritance of
      // every server-level `add_header` — COOP/COEP included, which costs
      // cross-origin isolation and with it PowerSync's wasm/OPFS worker (#89).
      // `gzip*` is not `add_header` and cannot trip that, but keeping the whole
      // block above the first `location` is what keeps the file readable as
      // "server-level policy first, routing second".
      final firstLocation = conf.indexOf('location ');
      expect(
        firstLocation,
        greaterThan(-1),
        reason: 'nginx.conf no longer has any location block',
      );
      for (final directive in const [
        'gzip on;',
        'gzip_proxied',
        'gzip_vary',
        'gzip_comp_level',
        'gzip_min_length',
        'gzip_types',
      ]) {
        expect(
          conf.indexOf(directive),
          lessThan(firstLocation),
          reason: '$directive moved into or below a location block',
        );
      }
    });
  });
}

/// [conf] with every comment line removed.
///
/// Load-bearing: this file's comments discuss `text/html` and
/// `application/octet-stream` at length precisely because they must NOT be
/// configured, so asserting against the raw text would invert every result.
String _directivesOf(String conf) => conf
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('#'))
    .join('\n');

/// The value of the `gzip_types` directive — from the keyword to its `;`.
///
/// Throws rather than `expect`s: this runs at load time, outside any test, so
/// a matcher here would abort the whole file with `OutsideTestException` and
/// hide the real diagnosis.
String _gzipTypes(String conf) {
  final start = conf.indexOf('gzip_types');
  if (start < 0) {
    throw StateError('nginx.conf sets no gzip_types — compression is off');
  }
  final end = conf.indexOf(';', start);
  if (end < start) {
    throw StateError('nginx.conf\'s gzip_types directive is not terminated');
  }
  return conf.substring(start, end);
}
