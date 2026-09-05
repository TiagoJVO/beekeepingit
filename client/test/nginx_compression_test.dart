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
///    live through `assets/shaders/ink_sparkle.frag`, which inherited that role
///    from the `.ttf` probe when #688 gave fonts a real type.
///  - **The directives must stay at server level.** Everything in this file's
///    `server {}` inherits six `add_header` directives, and the whole block
///    lives above the first `location {}` on purpose (#89).
///  - **The `types` block must stay at HTTP level (#688).** A `types {}` inside
///    `server {}` REPLACES the inherited map instead of extending it, so the
///    whole bundle would be served as `application/octet-stream` with `nginx -t`
///    green. The e2e would catch that (every probe pins a Content-Type), but
///    only after a full cluster bring-up; this is the seconds-long version.
///  - **No `location {}` may carry an `add_header` (#89).** One there cancels
///    inheritance of all six server-level headers, COOP/COEP included — the app
///    then loses cross-origin isolation and PowerSync's wasm/OPFS worker never
///    starts, with nothing red. #688 adds a third `location`, so this is worth a
///    gate rather than a comment.
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

    test('the font faces and NOTICES are covered (#688)', () {
      // Half of #688: the other half is the MIME mapping that makes these
      // match anything at all (see the two tests below). Either half alone
      // leaves ~1.4 MB going over the wire whole.
      expect(types, contains('font/ttf'));
      expect(types, contains('font/otf'));
      // `assets/NOTICES` is typed `text/plain` by its exact-match location.
      expect(types, contains('text/plain'));
    });

    test('the types block extends the stock map instead of replacing it', () {
      // In nginx a `types {}` inherits nothing: a context that declares one
      // uses only what it declares. At HTTP level — the context the stock
      // `include /etc/nginx/mime.types;` also populates — a second block
      // APPENDS. Inside `server {}` it would instead throw the entire stock map
      // away and serve `text/html`, `.js`, `.css`, `.wasm` and the `.png` icons
      // all as `application/octet-stream`, with `nginx -t` green.
      // Indentation is tolerated on purpose: a block that moved INTO `server {}`
      // must fail the level assertion below with that diagnosis, not be missed
      // entirely and reported as "there is no types block".
      final typesBlock = RegExp(r'^[ \t]*types\s*\{', multiLine: true);
      final match = typesBlock.firstMatch(conf);
      expect(
        match,
        isNotNull,
        reason:
            'nginx.conf declares no types block — the bundled .ttf/.otf faces '
            'are back to the application/octet-stream default_type, which '
            'gzip_types deliberately does not list (#688).',
      );
      expect(
        match!.start,
        lessThan(conf.indexOf('server {')),
        reason:
            'the types block moved inside server {} — it now REPLACES the base '
            "image's mime.types rather than extending it, so every response "
            'this server sends is application/octet-stream (#688).',
      );
      // Whitespace-tolerant on purpose: nginx's own mime.types column-aligns
      // its type map, so someone aligning this block to match would be making a
      // purely cosmetic edit — it must not turn this gate red.
      expect(conf, matches(RegExp(r'font/ttf\s+ttf;')));
      expect(conf, matches(RegExp(r'font/otf\s+otf;')));
    });

    test('assets/NOTICES is typed by an exact-match location (#688)', () {
      // It has no extension, so no `types` entry can reach it. `=` keeps the
      // blast radius at one URI: a server-level `default_type text/plain;`
      // would re-type every unrecognised file at once, which is the same
      // mistake as listing application/octet-stream in gzip_types.
      expect(
        conf,
        contains('location = /assets/NOTICES {'),
        reason:
            'the licences file is the largest compressible asset the bundle '
            'serves (1.45 MB, 89.2%) and nothing else can give it a type.',
      );
      final block = conf.indexOf('location = /assets/NOTICES {');
      expect(
        conf.indexOf('default_type'),
        greaterThan(block),
        reason:
            'a default_type outside that location — at server or http level — '
            'would re-type EVERY file nginx does not recognise, not just '
            'NOTICES.',
      );
      expect(
        'default_type'.allMatches(conf).length,
        1,
        reason: 'exactly one URI may be typed this way (#688).',
      );
    });

    test('no location block carries an add_header (#89)', () {
      // An `add_header` inside a `location {}` cancels inheritance of all six
      // server-level headers at once — COOP and COEP included, which costs the
      // origin its cross-origin isolation and stops PowerSync's wasm/OPFS
      // worker from starting. `nginx -t` stays green and the pod stays Ready.
      final firstLocation = conf.indexOf('location ');
      expect(firstLocation, greaterThan(-1));
      expect(
        conf.indexOf('add_header', firstLocation),
        -1,
        reason:
            'an add_header below the first location block cancels COOP/COEP '
            'inheritance for that location (#89).',
      );
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
