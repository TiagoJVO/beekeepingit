import 'dart:io';

import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression guard for #686 (FR-UX-1, FR-PL-1): the app must present **one**
/// brand mark.
///
/// Before this, the two came from two unrelated sources — the installed app's
/// icon (`web/icons/*`, #233/#681) was the Melargil bee, while the login
/// screen drew a Material honeycomb glyph in code — so a user saw both within
/// a second of launching the app and nothing in the repo tied them together.
///
/// The fix is deliberately the *same file*, not a lookalike: the in-app mark
/// is a byte-identical copy of the shipped 512px PWA icon. That makes
/// "the login screen and the app icon agree" a checkable property rather than
/// an eyeball judgement, and this test is the check — regenerating the icon
/// set (#682) without refreshing the bundled copy fails here instead of
/// quietly splitting the brand in two again.
///
/// It lives off-widget, next to `fonts_local_fallback_test.dart`, because it
/// asserts about repo *files*: `flutter test` runs with `client/` as its
/// working directory, so these relative paths resolve.
void main() {
  final appIcon = File('web/icons/Icon-512.png');
  final bundledMark = File(kBrandMarkAsset);
  final pubspec = File('pubspec.yaml');

  test('the in-app brand mark is byte-identical to the shipped app icon', () {
    expect(
      appIcon.existsSync(),
      isTrue,
      reason: 'web/icons/Icon-512.png is the shipped PWA icon (#233/#681)',
    );
    expect(
      bundledMark.existsSync(),
      isTrue,
      reason: '$kBrandMarkAsset is the in-app copy of that icon',
    );
    expect(
      bundledMark.readAsBytesSync(),
      orderedEquals(appIcon.readAsBytesSync()),
      reason:
          'The in-app mark and the app icon must be the same artwork (#686). '
          'If the icon set was regenerated, re-copy it: '
          'cp client/web/icons/Icon-512.png client/$kBrandMarkAsset',
    );
  });

  test('pubspec.yaml bundles the brand mark, so it is available offline', () {
    // Declared as an asset (not fetched, not read out of web/) — the login
    // screen is the first thing an offline cold boot paints (FR-OF-1, D-10),
    // and `tool/build_app_shell_cache.dart` sweeps whatever the built bundle
    // contains into the service worker's precache.
    //
    // Matched as a live list entry, anchored to the start of the line: a
    // commented-out `#   - assets/...` would satisfy a plain substring search
    // while shipping no asset at all.
    expect(
      pubspec.readAsStringSync(),
      matches(
        RegExp(
          '^\\s*- ${RegExp.escape(kBrandMarkAsset)}\\s*\$',
          multiLine: true,
        ),
      ),
    );
  });
}
