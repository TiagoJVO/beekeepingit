import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:beekeepingit_client/theming/brand_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Brand-wiring assertions for `AppTheme` (FR-UX-1, FR-AX-1, D-18, EPIC-11
/// #243): the theme is built from the Melargil tokens, honey is the single
/// primary, and the bundled fonts are wired the way the prototype asks
/// ("Archivo for all UI/body, Playfair Display for display/screen titles").
/// Contrast is covered separately in `app_theme_contrast_test.dart`.
void main() {
  group('brand color wiring', () {
    test('light primary is BrandTokens.honey (the one primary action)', () {
      final scheme = AppTheme.light().colorScheme;
      // "Honey is the only primary action" — PrimaryActionButton/FilledButton
      // and the shell FAB all draw scheme.primary, so this pins them to the
      // single honey hex rather than two uncoordinated ones (#243).
      expect(scheme.primary, BrandTokens.honey);
      // White-on-honey fails AA, so on-primary is the dark ink the FAB uses.
      expect(scheme.onPrimary, BrandTokens.onHoney);
    });

    test('dark primary is also honey (accent carries across modes)', () {
      expect(AppTheme.dark().colorScheme.primary, BrandTokens.honey);
    });

    test('light surface ground is cream and body text is ink', () {
      final scheme = AppTheme.light().colorScheme;
      expect(scheme.surface, BrandTokens.cream);
      expect(scheme.onSurface, BrandTokens.ink);
    });

    test('the two theme schemes differ by brightness', () {
      expect(AppTheme.light().colorScheme.brightness, Brightness.light);
      expect(AppTheme.dark().colorScheme.brightness, Brightness.dark);
      // Dark ground is plum, not cream.
      expect(AppTheme.dark().colorScheme.surface, BrandTokens.plum950);
    });
  });

  group('bundled typography wiring', () {
    for (final entry in {
      'light': AppTheme.light(),
      'dark': AppTheme.dark(),
    }.entries) {
      final name = entry.key;
      final theme = entry.value;

      test('$name: app-wide default font family is Archivo', () {
        // fontFamily on ThemeData is the app-wide default for any text style
        // that doesn't opt into another family — i.e. all UI/body text.
        expect(theme.textTheme.bodyMedium?.fontFamily, AppTheme.bodyFontFamily);
        expect(theme.textTheme.labelLarge?.fontFamily, AppTheme.bodyFontFamily);
        expect(AppTheme.bodyFontFamily, 'Archivo');
      });

      test('$name: display/headline/title styles use Playfair Display', () {
        expect(AppTheme.displayFontFamily, 'Playfair Display');
        for (final style in <TextStyle?>[
          theme.textTheme.displayLarge,
          theme.textTheme.headlineMedium,
          theme.textTheme.titleLarge,
          theme.textTheme.titleMedium,
        ]) {
          expect(style?.fontFamily, AppTheme.displayFontFamily);
        }
        // Body/label stay on Archivo (Playfair is titles-only).
        expect(theme.textTheme.bodyLarge?.fontFamily, AppTheme.bodyFontFamily);
        expect(
          theme.textTheme.labelMedium?.fontFamily,
          AppTheme.bodyFontFamily,
        );
      });

      test('$name: the app-bar title uses the Playfair title style', () {
        // The shell header (app_shell.dart) drops its inline fontFamily and
        // relies on this — so the screen title actually renders in Playfair.
        expect(
          theme.appBarTheme.titleTextStyle?.fontFamily,
          AppTheme.displayFontFamily,
        );
      });
    }
  });
}
