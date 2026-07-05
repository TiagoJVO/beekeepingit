import 'package:flutter/material.dart';

/// Light/dark Material 3 theme — AC: "a theming approach ... is established".
/// Visual density stays at the default (not compact): gloves-friendly,
/// large-tap-target field UX (FR-UX/FR-AX, WCAG 2.2 AA) over information
/// density.
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
