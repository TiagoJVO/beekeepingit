import 'dart:io';

import 'package:beekeepingit_client/features/apiaries/map_tile_sources.dart';
import 'package:flutter_test/flutter_test.dart';

/// `nginx.conf`'s CSP `connect-src` and the hosts the map actually calls must
/// agree — in BOTH directions (#671, NFR-SEC-1, NFR-CMP-1, FR-AP-3, D-16).
///
/// The defect this pins was not a wrong value; it was that no single artifact
/// knew both halves. The tile URLs were written out longhand in three widget
/// files, the policy was written out in a fourth, and nothing read them
/// together — so `connect-src` shipped naming neither tile host while the map
/// happily fetched from both. That was survivable only because the header is
/// still `Content-Security-Policy-Report-Only`: the moment #462 flips it to the
/// enforcing name, the apiary map, the embedded location picker and the
/// full-screen picker all go blank at once, with `nginx -t` green, the pod
/// Ready and nothing red in CI.
///
/// `client/e2e/tests/map-tiles-csp.spec.ts` proves the OUTCOME — the shipped
/// policy, enforced in a real browser against the real image, actually permits
/// a tile fetch. This file is the seconds-long half that needs no cluster, and
/// it covers what a live probe structurally cannot: that the policy is derived
/// from the same strings the widgets pass to `TileLayer`, so adding a third
/// provider or migrating to a same-origin tile proxy cannot leave the two out
/// of step.
///
/// Deliberately bidirectional. "Every tile host is allow-listed" alone would
/// stay green forever after a migration to a gateway tile proxy, quietly
/// leaving two third-party origins the app no longer uses in the policy of an
/// app whose whole argument for the change was not talking to them.
void main() {
  // Constructed here, read inside each test: a renamed or missing file should
  // fail one test with a reason, not the whole suite at load time with a bare
  // FileSystemException. Same shape as `app_shell_service_worker_test.dart`
  // and `fonts_local_fallback_test.dart`, which read the same file.
  final nginxConf = File('nginx.conf');
  final libDir = Directory('lib');

  group('the tile hosts and connect-src agree (#671)', () {
    test('the templates the widgets use are real https tile URLs', () {
      // Positive evidence first: every assertion below is about a set derived
      // from `mapTileUrlTemplates`, so an empty or malformed list would make
      // the rest pass vacuously.
      expect(mapTileUrlTemplates, isNotEmpty);
      for (final template in mapTileUrlTemplates) {
        expect(
          template,
          startsWith('https://'),
          reason: 'a plaintext tile source would also break the CSP and COEP',
        );
        expect(
          template,
          contains('{z}'),
          reason: '$template is not a slippy-map tile template',
        );
      }
      expect(
        mapTileCspOrigins,
        containsAll(<String>[
          'https://server.arcgisonline.com',
          'https://tile.openstreetmap.org',
        ]),
        reason:
            'D-16 (#257) fixes Esri World Imagery as the default satellite '
            'layer and OSM as the streets alternative; changing either is a '
            'decision change, not a refactor',
      );
    });

    test('connect-src names every host the map fetches tiles from', () {
      final connectSrc = _cspDirective(nginxConf.readAsStringSync());
      for (final origin in mapTileCspOrigins) {
        expect(
          connectSrc,
          contains(origin),
          reason:
              'flutter_map fetches tiles over package:http — XHR on web — so '
              '$origin is governed by connect-src, not img-src. Enforcing this '
              'policy without it blanks every map view (#671, #462).',
        );
      }
      // The first-party source the map fix must not have displaced.
      expect(connectSrc, contains("'self'"));
    });

    test('connect-src names no third-party host the app does not call', () {
      final sources = _cspDirective(
        nginxConf.readAsStringSync(),
      ).split(RegExp(r'\s+')).where((source) => source.isNotEmpty).toSet();
      final unexplained = sources.difference(<String>{
        "'self'",
        ...mapTileCspOrigins,
      });

      // What is left must be the auth host, and ONLY the auth host. Asserted by
      // shape rather than by value on purpose: the value is the one
      // environment-dependent entry in this policy and it is wrong for every
      // environment but dev today, which #462 fixes by templating the file —
      // pinning the dev string here would make that correct fix fail this test.
      expect(
        unexplained.length,
        1,
        reason:
            'every connect-src entry must be traceable to code that calls it: '
            "`'self'` for our own APIs and sync stream, the tile hosts for the "
            'map, and the OIDC auth host. Anything else is an exfiltration '
            'sink nobody asked for. If the map moved behind a same-origin tile '
            'proxy or a consent gate (#671), the tile hosts come OUT in the '
            "same change — `'self'` then covers them. Saw: $sources",
      );
      expect(unexplained.single, startsWith('https://'));
      expect(
        unexplained.single,
        contains('auth'),
        reason:
            'the one remaining source should be the OIDC provider '
            '(client/lib/core/auth/auth_controller.dart), not something new',
      );
    });

    test('the tile hosts are not also granted img-src', () {
      // Belt-and-braces against the wrong fix for this bug. The bytes become an
      // image, so img-src is the intuitive place to put these — but the browser
      // classifies by how the request was made, so listing them here grants a
      // third party a source it never uses while the map stays blank. Scoped to
      // flutter_map's current transport (package:http): if a future version
      // ever loads tiles through the browser's own image loader, adding img-src
      // becomes the right fix and this assertion is what to revisit.
      final imgSrc = _cspDirective(
        nginxConf.readAsStringSync(),
        directive: 'img-src',
      );
      for (final origin in mapTileCspOrigins) {
        expect(imgSrc, isNot(contains(origin)));
      }
    });
  });

  group('the tile URLs stay in one place', () {
    // The screens that render a map TODAY. The positive half: each must still
    // pull its template from map_tile_sources.dart.
    const mapScreens = <String>[
      'lib/features/apiaries/apiary_map_screen.dart',
      'lib/features/apiaries/apiary_location_picker_screen.dart',
      'lib/features/apiaries/apiary_form_screen.dart',
    ];

    for (final path in mapScreens) {
      test('$path takes its tile URL from map_tile_sources.dart', () {
        final source = File(path).readAsStringSync();

        expect(
          source,
          contains('urlTemplate:'),
          reason:
              '$path no longer renders a TileLayer — if the map moved, move '
              'this guard with it rather than deleting it',
        );
        expect(
          RegExp(r"import\s+'map_tile_sources\.dart'").hasMatch(source),
          isTrue,
          reason: '$path renders tiles but does not import their single source',
        );
      });
    }

    test('no .dart file under lib/ writes a tile URL as a literal', () {
      // The negative half, and it deliberately scans EVERYTHING rather than the
      // three paths above: #671's shape was a tile host in a file no test knew
      // to look at, and a fourth map screen in a new file would reproduce it
      // exactly. `fallbackUrl` is included because flutter_map's TileLayer will
      // fetch from it too, so it is a tile host by any other name.
      final offenders = <String>[];
      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync();
        if (_tileUrlLiteral.hasMatch(source)) {
          offenders.add(entity.path);
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'a tile URL written out at the call site is invisible to the '
            'connect-src check above — which is exactly how #671 shipped. '
            'Add it to map_tile_sources.dart and reference the constant.',
      );
    });
  });
}

/// Matches a `urlTemplate:`/`fallbackUrl:` whose value is a string literal
/// (raw or not, `const` or not) rather than a reference to a named constant.
/// `\s*` spans newlines in Dart, so the pre-#671 multi-line form — the actual
/// defect — is matched too.
final _tileUrlLiteral = RegExp(
  "(?:urlTemplate|fallbackUrl):\\s*(?:const\\s+)?r?['\"]",
);

/// The value of one directive of the `Content-Security-Policy…` header that
/// [conf] actually SENDS — not any of the prose around it.
///
/// Same shape as `app_shell_service_worker_test.dart`'s private helper. Two
/// copies of six lines is cheaper than a shared test-only library and keeps
/// each file readable on its own; a third copy is where that stops being true.
String _cspDirective(String conf, {String directive = 'connect-src'}) {
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
  return match!.group(1)!.trim();
}
