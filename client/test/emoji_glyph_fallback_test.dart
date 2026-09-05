import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/build_app_shell_cache.dart';
import 'support/ttf_cmap.dart';

/// #673 (D-37, NFR-CMP, FR-OF-1, FR-AP-8, NFR-I18N-1, C-2): an emoji a user
/// typed into an apiary name or a free-text note must render
/// from a face we serve ourselves — never from a third-party download, and
/// never as the missing-glyph box.
///
/// ## What the engine actually asks for
///
/// `#620` pinned `fontFallbackBaseUrl` to the same-origin prefix
/// `font-fallback/` and bundled nothing under it, so every uncovered code point
/// became a box plus a repeating same-origin 404 (`FontFallbackManager` drops a
/// failed download from `pendingFonts` without recording it as downloaded, so
/// it re-requests on every layout of that text).
///
/// The URL it requests is `configuration.fontFallbackBaseUrl + font.url`
/// (`flutter_web_sdk/lib/_engine/engine/font_fallbacks.dart`,
/// `_FallbackFontDownloadQueue.startDownloads`), where `font.url` comes from
/// the generated Noto manifest in `font_fallback_data.dart`. Every emoji entry
/// there is a Google-Fonts subset chunk:
///
///     notocoloremoji/v32/<opaque-hash>.<n>.woff2      n = 0 … 11
///
/// Twelve URLs, one per unicode-range chunk, whose hash and chunk count are
/// re-rolled with the engine. We therefore serve the whole PREFIX from one
/// monochrome face rather than pinning twelve hashed filenames that a Flutter
/// bump would silently invalidate — see `nginx.conf` and `web/service_worker.js`
/// for the two halves of that (online and offline), and `D-37` for why the
/// face is monochrome.
///
/// One consequence is what makes a single file enough: the engine only asks
/// for the chunk covering the FIRST uncovered code point it meets. Once that
/// download is registered, CanvasKit resolves subsequent emoji against the
/// typeface it actually loaded — which covers all of them — so no second chunk
/// is ever requested.
///
/// `client/e2e/tests/same-origin-boot.spec.ts` is the behavioural half: it
/// fetches one of those chunk URLs from a real browser against the deployed
/// bundle and still fails on any request that leaves our origins.
void main() {
  // The one face served under the fallback prefix, as a repo path.
  const facePath = 'web/font-fallback/NotoEmoji-Regular.ttf';

  // …and as the URL the container serves it at.
  const faceUrl = '/font-fallback/NotoEmoji-Regular.ttf';

  // The Google-Fonts family directories the engine builds emoji URLs from.
  // `notocoloremoji/` is what the pinned engine asks for today; `notoemoji/`
  // is the same family's monochrome sibling, mapped as well so a roll that
  // switches to it does not silently reopen the box.
  const emojiPrefixes = [
    '/font-fallback/notocoloremoji/',
    '/font-fallback/notoemoji/',
  ];

  final face = File(facePath);
  final licence = File('web/font-fallback/OFL.txt');
  final pubspec = File('pubspec.yaml');
  final nginxConf = File('nginx.conf');
  final worker = File('web/service_worker.js');

  group('the bundled monochrome face', () {
    test('is a TrueType file in the bundle', () {
      expect(face.existsSync(), isTrue, reason: '$facePath is not in the repo');

      final magic = face.readAsBytesSync().sublist(0, 4);
      expect(
        magic,
        <int>[0x00, 0x01, 0x00, 0x00],
        reason:
            'CanvasKit parses these bytes with FreeType '
            '(`Typeface.MakeFreeTypeFaceFromData`), which sniffs the CONTENT '
            'rather than the URL, so serving TrueType at a `.woff2` chunk URL '
            'is fine — but it does have to really be a font.',
      );
    });

    test('ships its OFL licence beside it, as the brand faces do', () {
      expect(licence.existsSync(), isTrue);
      expect(licence.readAsStringSync(), contains('SIL Open Font License'));
    });

    test('covers the emoji a beekeeper would actually type, which no other '
        'bundled face does', () {
      final emoji = codePointsCoveredBy(facePath);

      for (final MapEntry(key: name, value: codePoint) in <String, int>{
        'bee': 0x1F41D,
        'honey pot': 0x1F36F,
        'grinning face': 0x1F600,
        'red heart': 0x2764,
        'white heavy check mark': 0x2705,
        'regional indicator P (flags)': 0x1F1F5,
        'variation selector-16': 0xFE0F,
        'zero-width joiner': 0x200D,
        // Unicode 15 (2023). A face that predates the emoji a modern keyboard
        // offers would still leave boxes, which is the whole failure mode.
        'shaking face': 0x1FAE8,
      }.entries) {
        expect(
          emoji,
          contains(codePoint),
          reason:
              '$name (U+${codePoint.toRadixString(16).toUpperCase()}) would '
              'still render as the missing-glyph box',
        );
      }

      // The premise: these really are code points nothing else bundled covers,
      // so this face is what resolves them rather than a redundant copy of
      // coverage the app already had.
      for (final other in <String>[
        'fonts/Roboto/Roboto-Regular.ttf',
        'fonts/Archivo/Archivo-Regular.ttf',
        'fonts/PlayfairDisplay/PlayfairDisplay-SemiBold.ttf',
      ]) {
        expect(
          codePointsCoveredBy(other),
          isNot(contains(0x1F41D)),
          reason:
              '$other already covers the bee — this face is not the thing '
              'that makes it render',
        );
      }
    });

    test('covers emoji ONLY — CJK, Arabic and Hebrew stay boxes, and D-37 '
        'says so deliberately', () {
      final emoji = codePointsCoveredBy(facePath);

      for (final MapEntry(key: script, value: codePoint) in <String, int>{
        'CJK': 0x4E00,
        'Arabic': 0x0627,
        'Hebrew': 0x05D0,
        'Devanagari': 0x0905,
      }.entries) {
        expect(
          emoji,
          isNot(contains(codePoint)),
          reason:
              'If this face grew $script coverage, D-37 (which scopes the '
              'bundled fallback to emoji, on the grounds that emoji is the '
              'case users reach in a Portugal-first product) would be '
              'describing something else.',
        );
      }
    });

    test('is NOT declared as a `flutter: fonts:` family', () {
      // `SkiaFontCollection.loadAssetFonts` downloads EVERY family in
      // FontManifest.json during boot. Declaring this one would put ~865 KB on
      // the cold-load path for a fallback most users never trigger — the exact
      // boot cost #620 and #670 exist to avoid. It is served lazily from the
      // fallback prefix instead, which is why it lives under `web/` rather than
      // beside the brand faces in `fonts/`.
      //
      // Asserted against the `family:`/`asset:` LINES rather than the whole
      // file, so that documenting this decision in a pubspec comment cannot
      // fail a test whose message would then say the opposite of the truth.
      final declarations = const LineSplitter()
          .convert(pubspec.readAsStringSync())
          .where((line) => RegExp(r'^\s+- (family|asset):').hasMatch(line));

      for (final line in declarations) {
        expect(
          line,
          isNot(contains('Noto')),
          reason:
              'pubspec.yaml declares $line. A `fonts:` family is downloaded by '
              'every cold load, which is the cost this face is served lazily '
              'to avoid.',
        );
        expect(line, isNot(contains('font-fallback')));
      }
    });
  });

  group('served at the URL the engine builds', () {
    test('nginx maps every emoji fallback prefix onto that one face', () {
      final conf = nginxConf.readAsStringSync();

      for (final prefix in emojiPrefixes) {
        final block = RegExp(
          'location\\s+\\^~\\s+${RegExp.escape(prefix)}\\s*\\{([^}]*)\\}',
        ).firstMatch(conf);
        expect(
          block,
          isNotNull,
          reason:
              'No `location ^~ $prefix` block. Without it the request falls '
              'through to `location ^~ /font-fallback/`, which answers =404, '
              'and the emoji is a box again.',
        );
        // `block` cannot be null here: the expectation above fails the test
        // first.
        expect(
          block!.group(1),
          contains('try_files $faceUrl =404'),
          reason: '$prefix must resolve to $faceUrl',
        );
        expect(
          block.group(1),
          isNot(contains('add_header')),
          reason:
              'nginx.conf carries six server-level headers (COOP, COEP, '
              'nosniff, Referrer-Policy, the report-only CSP and '
              'Cache-Control). A single add_header in a location cancels '
              'inheritance of ALL of them for that URI (#89), and this one '
              'serves a font to a cross-origin-isolated page.',
        );
      }
    });

    test('everything else under the prefix still 404s honestly', () {
      // The CJK/Arabic/Hebrew families the engine may also ask for are NOT
      // served (see the coverage test above). A fast 404 is the right answer:
      // it is what stops the SPA fallback handing the engine an index.html to
      // parse as a font.
      //
      // Matched as a BLOCK with its body, not as a substring: the two emoji
      // locations above are supersets of the literal `location ^~
      // /font-fallback/`, so a `contains` would stay green with this generic
      // block deleted — which is the regression it exists to catch.
      final block = RegExp(
        r'location\s+\^~\s+/font-fallback/\s*\{([^}]*)\}',
      ).firstMatch(nginxConf.readAsStringSync());

      expect(block, isNotNull);
      expect(block?.group(1), contains(r'try_files $uri =404'));
    });

    test('the service worker answers the same prefixes from the same face, so '
        'a second offline load still has emoji', () {
      final source = worker.readAsStringSync();

      expect(
        source,
        contains(faceUrl),
        reason:
            'nginx only helps a client that can reach the network. The worker '
            'is what serves the chunk URL offline, and it can only do that by '
            'mapping the prefix onto the cached face — the chunk URL itself is '
            'never in the manifest, because no such FILE exists in the bundle.',
      );
      for (final prefix in emojiPrefixes) {
        expect(source, contains(prefix));
      }
    });

    test('the app-shell generator puts the face in the RUNTIME tier, not '
        'PRECACHE', () {
      // D-37's cost decision, as code. PRECACHE downloads on every install —
      // i.e. once per client per release — for a fallback most users never
      // trigger. RUNTIME stores it the first time an emoji is actually
      // rendered, after which it is offline-available like any other shell
      // asset, and costs nothing at boot.
      expect(isRuntimeCached('font-fallback/NotoEmoji-Regular.ttf'), isTrue);
      expect(isRuntimeCached('font-fallback/OFL.txt'), isTrue);
      // Guard the boundary: this must not have swept the real shell into the
      // lazy tier.
      expect(isRuntimeCached('main.dart.js'), isFalse);
      expect(
        isRuntimeCached('assets/fonts/Roboto/Roboto-Regular.ttf'),
        isFalse,
      );
    });
  });

  group('against the pinned engine', () {
    test('every emoji fallback URL the engine can build starts with a prefix '
        'we serve', () {
      final manifest = _engineFallbackManifest();
      if (manifest == null) {
        // This is the ONLY assertion that checks the repo against the engine
        // rather than against its own copies of the prefix, so it must not be
        // quietly absent from the gate D-37's "a Flutter bump cannot silently
        // reopen the box" rests on. `flutter_web_sdk` is unpacked by
        // `flutter precache --web` (and by a web build), which every CI site
        // that runs `flutter test` therefore does first — see
        // `.github/workflows/build-publish.yml` and `taskfiles/dart.yml`. In
        // CI, its absence is the failure; locally it is a skip, so a plain
        // `flutter test` on a fresh checkout still works.
        if (Platform.environment['CI'] == 'true') {
          fail(
            "the pinned SDK's flutter_web_sdk is not unpacked, so this guard "
            'did not run. Restore the `flutter precache --web` step that '
            'precedes `flutter test`.',
          );
        }
        markTestSkipped(
          "the pinned SDK's flutter_web_sdk is not unpacked in this checkout "
          '(`flutter precache --web` unpacks it), so the engine manifest could '
          'not be read',
        );
        return;
      }

      // `NotoFont('<name>', '<url>')` pairs, of which only the emoji families
      // matter here — the rest are the scripts D-37 deliberately leaves as
      // boxes.
      final entries = RegExp(
        r"""NotoFont\(\s*'([^']*)',\s*'([^']*)',?\s*\)""",
      ).allMatches(manifest);
      expect(
        entries,
        isNotEmpty,
        reason: 'the manifest shape changed — this assertion has gone stale',
      );

      final emojiUrls = [
        for (final entry in entries)
          if (entry.group(1)!.toLowerCase().contains('emoji')) entry.group(2)!,
      ];
      expect(
        emojiUrls,
        isNotEmpty,
        reason: 'no emoji family in the engine manifest at all',
      );

      for (final url in emojiUrls) {
        expect(
          emojiPrefixes.any(
            (prefix) => '/font-fallback/$url'.startsWith(prefix),
          ),
          isTrue,
          reason:
              'The engine would request font-fallback/$url, which no location '
              'in nginx.conf maps to the bundled face. A Flutter bump has '
              'moved the emoji family; add its directory to `emojiPrefixes`, '
              'nginx.conf and web/service_worker.js together.',
        );
      }
    });
  });
}

/// The pinned Flutter web engine's generated Noto fallback manifest, or `null`
/// when the web SDK has not been unpacked in this checkout.
///
/// Found relative to the Dart VM running the test, which under `flutter test`
/// is the SDK's own `bin/cache/dart-sdk/bin/dart` — so the Flutter root is
/// wherever `bin/cache/flutter_web_sdk` sits above it. Deliberately derived
/// rather than configured: the point of this test is to check the repo against
/// the engine the build will actually use.
String? _engineFallbackManifest() {
  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth++) {
    final candidate = File(
      '${directory.path}/bin/cache/flutter_web_sdk/lib/_engine/engine/'
      'font_fallback_data.dart',
    );
    if (candidate.existsSync()) return candidate.readAsStringSync();
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}
