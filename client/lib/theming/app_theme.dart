import 'package:flutter/material.dart';

/// Light/dark Material 3 theme — AC: "a theming approach ... is established".
/// Visual density stays at the default (not compact): gloves-friendly,
/// large-tap-target field UX (FR-UX/FR-AX, WCAG 2.2 AA) over information
/// density.
///
/// This is the theming half of the app's accessibility/field-first baseline
/// (#79, #80); the other half is `core/widgets/` (shared tap-target-sized
/// buttons) and the checklist both follow:
/// `docs/design/accessibility-field-ux-checklist.md`. `ColorScheme.fromSeed`
/// generates Material 3 tonal palettes, which are contrast-checked against
/// WCAG 2.2 AA in `test/theming/app_theme_contrast_test.dart` — a regression
/// there fails CI rather than shipping a low-contrast color pair.
abstract final class AppTheme {
  static const _seedColor = Color(0xFFF9A825); // honey amber

  static ThemeData light() => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: _seedColor),
  );

  static ThemeData dark() => ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: Brightness.dark,
    ),
  );
}
