import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/ttf_cmap.dart';

/// Regression guard for #620 (NFR-CMP, FR-OF-1, C-2): the app must not fetch a
/// font from Google on a cold load.
///
/// The web engine reaches `fonts.gstatic.com` on two paths of its own, neither
/// of which `--no-web-resources-cdn` suppresses (that flag only localises the
/// CanvasKit engine payload):
///
///  1. **Every cold load.** `SkiaFontCollection.loadAssetFonts` scans
///     `FontManifest.json` for a family literally named `Roboto` and, finding
///     none, downloads `${fontFallbackBaseUrl}roboto/v32/…woff2` so text layout
///     always has a default family
///     (`flutter_web_sdk/lib/_engine/engine/canvaskit/fonts.dart`,
///     `if (!loadedRoboto)`).
///  2. **Per uncovered code point.** `FontFallbackManager` downloads a Noto
///     font from that same `configuration.fontFallbackBaseUrl`, which defaults
///     to `https://fonts.gstatic.com/s/`.
///
/// Two settings close them, and the tests below pin one each: the bundled
/// `Roboto` family, and the base URL pinned to a same-origin relative path.
/// They are not interchangeable — pinning the base URL alone would turn (1)
/// into a 404 and leave CanvasKit with no default family at all.
///
/// Both live in files no widget test would otherwise touch, which is why they
/// are asserted here, off-browser and in the fast CI gate.
/// `client/e2e/tests/same-origin-boot.spec.ts` is the behavioural half: it
/// watches the real deployed bundle boot and fails on any request that leaves
/// the app's own origin. It proves the outcome, not these two settings
/// individually — (2) alone is enough to keep it green.
void main() {
  final pubspec = File('pubspec.yaml');
  final bootstrap = File('web/flutter_bootstrap.js');
  final nginxConf = File('nginx.conf');

  group('bundled default font family (boot path)', () {
    test('pubspec.yaml declares a family named exactly "Roboto" — without it '
        'the engine downloads one from fonts.gstatic.com on every cold '
        'load', () {
      final families = _declaredFontFamilies(pubspec.readAsStringSync());

      expect(
        families.keys,
        contains('Roboto'),
        reason:
            'The name is load-bearing: the engine matches `family.name == '
            "'Roboto'` literally. Renaming or dropping this family silently "
            'restores the CDN fetch.',
      );
      expect(families['Roboto'], isNotEmpty);
    });

    test('every declared font asset exists on disk', () {
      final families = _declaredFontFamilies(pubspec.readAsStringSync());

      for (final MapEntry(key: family, value: assets) in families.entries) {
        for (final asset in assets) {
          expect(
            File(asset).existsSync(),
            isTrue,
            reason: '$family declares $asset, which is not in the repo',
          );
        }
      }
    });

    test('the bundled Roboto covers code points the brand faces do not, so '
        'glyph fallback still resolves without the network', () {
      final families = _declaredFontFamilies(pubspec.readAsStringSync());
      final roboto = codePointsCoveredBy(_regularFaceOf(families, 'Roboto'));
      final archivo = codePointsCoveredBy(_regularFaceOf(families, 'Archivo'));
      final playfair = codePointsCoveredBy(
        _regularFaceOf(families, 'Playfair Display'),
      );

      // Portuguese (C-2) and English (D-34) must render from the brand faces
      // themselves — the fallback is not load-bearing for the product locales.
      // Both faces, not just the body one: Playfair Display carries every
      // display/headline/title string (AppTheme.displayFontFamily).
      for (final codePoint in 'çãõáéíóúàâêôÇÃÕ'.runes) {
        expect(archivo, contains(codePoint));
        expect(playfair, contains(codePoint));
      }

      // Beyond them, Roboto is what free text falls back to. Latin Extended,
      // Greek, Cyrillic and Vietnamese are the ranges it adds.
      for (final codePoint in <int>[
        0x0151, // ő  Latin Extended-A
        0x0391, // Α  Greek
        0x0410, // А  Cyrillic
        0x1EBF, // ế  Vietnamese
      ]) {
        expect(archivo, isNot(contains(codePoint)));
        expect(playfair, isNot(contains(codePoint)));
        expect(
          roboto,
          contains(codePoint),
          reason:
              'U+${codePoint.toRadixString(16).toUpperCase()} would render as '
              'a missing-glyph box, and no network fallback is allowed to '
              'rescue it',
        );
      }
    });
  });

  group('glyph-fallback base URL (per-code-point path)', () {
    test('flutter_bootstrap.js pins fontFallbackBaseUrl to a same-origin '
        'relative path', () {
      final baseUrl = _pinnedFallbackBaseUrl(bootstrap.readAsStringSync());

      expect(baseUrl, isNotEmpty);
      expect(
        Uri.parse(baseUrl).hasScheme || baseUrl.startsWith('//'),
        isFalse,
        reason: '"$baseUrl" is not origin-relative',
      );
      expect(
        baseUrl,
        endsWith('/'),
        reason: 'the engine concatenates, it does not join paths',
      );
    });

    test('flutter_bootstrap.js keeps the default loader contract around that '
        'one addition', () {
      // The file adds `config` and removes `serviceWorkerSettings`; everything
      // else must stay exactly what `generateDefaultFlutterBootstrapScript`
      // emits, so a Flutter bump that changes the loader contract is a merge
      // conflict rather than a silent divergence.
      //
      // The service-worker block used to be asserted here as part of that
      // default. It is now deliberately ABSENT (#619): at Flutter 3.44 the
      // generated worker only unregisters itself, and leaving the loader to
      // register it would take our own app-shell worker's `/` scope with it.
      // That absence is owned by app_shell_service_worker_test.dart — this test
      // is #620's, and asserting #619's property here would blur both.
      final source = bootstrap.readAsStringSync();
      expect(source, contains('{{flutter_js}}'));
      expect(source, contains('{{flutter_build_config}}'));
    });

    test('nginx serves the pinned prefix instead of letting it fall through '
        'to the SPA rule', () {
      // The pinned value is document-relative and this prefix is root-absolute:
      // they line up only because no build passes `--base-href`. If one ever
      // does, both this location and this assertion have to change together.
      final prefix = '/${_pinnedFallbackBaseUrl(bootstrap.readAsStringSync())}';
      final conf = nginxConf.readAsStringSync();

      // Matched as a BLOCK, not as a substring: since #673 two longer
      // locations (`$prefix` + `notocoloremoji/`, `notoemoji/`) also contain
      // the literal `location ^~ $prefix`, so a substring check would survive
      // this generic block being deleted — and deleting it is exactly what
      // sends a CJK fallback request to the SPA rule.
      final block = RegExp(
        'location\\s+\\^~\\s+${RegExp.escape(prefix)}\\s*\\{([^}]*)\\}',
      ).firstMatch(conf);
      expect(
        block,
        isNotNull,
        reason:
            'Without its own location, $prefix hits `try_files \$uri \$uri/ '
            '/index.html` and every fallback attempt downloads index.html and '
            'fails to parse it as a font.',
      );
      expect(
        block?.group(1),
        contains(r'try_files $uri =404'),
        reason:
            'The block has to answer a miss with a fast 404. Anything else and '
            'the engine parses a response body that is not a font.',
      );
      expect(conf, contains("font-src 'self'"));
    });
  });
}

/// Maps each `flutter: fonts:` family in [pubspecSource] to the asset paths it
/// declares. A line scanner rather than a YAML parse: the client has no
/// `package:yaml` dependency, and this only has to read one fixed block.
///
/// It reads the shape `flutter build` writes and this repo uses — the `fonts:`
/// key indented two spaces, entries four. Re-indenting the block or quoting a
/// family name would confuse it, so it fails loudly rather than returning a
/// plausible-looking empty map.
Map<String, List<String>> _declaredFontFamilies(String pubspecSource) {
  final families = <String, List<String>>{};
  String? current;
  var inFontsBlock = false;

  for (final line in const LineSplitter().convert(pubspecSource)) {
    if (RegExp(r'^\s{2}fonts:\s*$').hasMatch(line)) {
      inFontsBlock = true;
      continue;
    }
    if (!inFontsBlock) continue;
    // Any non-blank, non-comment line at or above the block's own indentation
    // ends it.
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    if (!line.startsWith('    ')) break;

    final family = RegExp(
      r'''^\s*-\s*family:\s*["']?(.+?)["']?\s*$''',
    ).firstMatch(line);
    if (family != null) {
      // The regexes above cannot match without capturing group 1.
      current = family.group(1)!;
      families[current] = <String>[];
      continue;
    }
    final asset = RegExp(
      r'''^\s*-\s*asset:\s*["']?(.+?)["']?\s*$''',
    ).firstMatch(line);
    if (asset != null && current != null) {
      families[current]!.add(asset.group(1)!);
    }
  }

  if (families.isEmpty) {
    fail(
      'No `flutter: fonts:` families were parsed out of pubspec.yaml. The block '
      'is almost certainly still there and this scanner has gone stale — check '
      'its indentation before believing any failure above.',
    );
  }
  return families;
}

/// The first declared face of [family] — the one whose glyph coverage stands in
/// for the family's.
String _regularFaceOf(Map<String, List<String>> families, String family) {
  final assets = families[family];
  if (assets == null || assets.isEmpty) {
    fail('pubspec.yaml declares no font asset for the "$family" family');
  }
  return assets.first;
}

/// The `fontFallbackBaseUrl` [bootstrapSource] pins the web engine to.
String _pinnedFallbackBaseUrl(String bootstrapSource) {
  final match = RegExp(
    r'''fontFallbackBaseUrl\s*:\s*["']([^"']*)["']''',
  ).firstMatch(bootstrapSource);
  if (match == null) {
    fail(
      'web/flutter_bootstrap.js does not set fontFallbackBaseUrl. Unset, the '
      'engine uses its default https://fonts.gstatic.com/s/ and downloads a '
      'Noto font from Google for any code point the bundled faces miss.',
    );
  }
  // The regex cannot match without capturing group 1.
  return match.group(1)!;
}
