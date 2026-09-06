import 'package:flutter/material.dart';

import 'brand_dimens.dart';
import 'brand_theme.dart';
import 'brand_tokens.dart';

/// Light/dark Material 3 theme, built from the Melargil brand tokens
/// (FR-UX-1, FR-AX-1, D-18, EPIC-11 #243).
///
/// This is the theming half of the app's accessibility/field-first baseline
/// (#79, #80); the other half is `core/widgets/` (shared tap-target-sized
/// buttons) and the checklist both follow:
/// `docs/design/accessibility-field-ux-checklist.md`. Visual density stays at
/// the default (not compact): gloves-friendly, large-tap-target field UX over
/// information density.
///
/// The color scheme is hand-built from [BrandTokens] rather than
/// `ColorScheme.fromSeed`, so the prototype palette (`docs/design/prototype.md`
/// §Design tokens) is used verbatim instead of a generated tonal
/// approximation.
///
/// **Honey is a fill, not the `primary` role.** Material draws `primary` as a
/// *foreground* on the surface for outlined/text-button labels, accent icons
/// and selection tints, and honey-on-cream is 1.84:1 — the light-mode gap
/// #627 reported. So the light scheme's `primary` is plum 700 (8.68:1 on
/// cream) and the honey fill is pinned where the *one* primary action per
/// screen actually lives: `PrimaryActionButton` and the FAB theme, both with
/// the dark [BrandTokens.onHoney] label (white-on-honey fails AA). The dark
/// scheme keeps honey as `primary` — on plum 950 it measures 8.02:1, so there
/// it is legible as a foreground. Every `on*` role pair the scheme defines is
/// enforced in
/// `test/theming/app_theme_contrast_test.dart`, each against the bar its
/// actual usage needs: WCAG 2.2 AA text contrast (4.5:1) for the pairs used
/// as body/label text, except the light-mode `tertiary`/`onTertiary` pair
/// (gold-on-paper, ~3.3:1) — used only for a small map-pin badge, not body
/// text — which is held to WCAG 2.2 SC 1.4.11's non-text/graphical floor
/// (3:1) instead, the same documented gap [BrandTokens.gold] itself already
/// calls out for body-text usage.
///
/// Typography is bundled (offline-first, no runtime font fetching): **Archivo**
/// is the app-wide default (`fontFamily`) for all UI/body; **Playfair Display**
/// is applied to the display/headline tiers and `titleLarge` — screen titles +
/// brand — matching the prototype. `titleMedium` stays on Archivo because
/// Material resolves it for *form controls*, not titles (#628; see
/// [_themeFrom]). Both families are declared under `flutter: fonts:` in
/// `pubspec.yaml`.
abstract final class AppTheme {
  /// Family name for body/UI text — matches the `fonts:` family in pubspec.
  static const bodyFontFamily = 'Archivo';

  /// Family name for display/title/brand text — matches the `fonts:` family in
  /// pubspec. Replaces the old dangling `fontFamily: 'Playfair Display'` in the
  /// shell header that had no bundled font and silently fell back to Roboto.
  static const displayFontFamily = 'Playfair Display';

  /// Light color scheme, taken directly from the (light-first) prototype
  /// palette. Cream is the surface ground, Paper the raised card surface, Ink
  /// the body text; plum is the accent that reads on those grounds, and the
  /// honey fill is reserved for the one primary action (see the class doc).
  /// `primary` and `secondary` are deliberately the same plum here: the
  /// prototype has one accent hue for light grounds, and the roles are kept
  /// distinct only where the ramp needs them (`secondaryContainer` = plum 600).
  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: BrandTokens.plum700,
    onPrimary: BrandTokens.paper,
    primaryContainer: BrandTokens.sand,
    onPrimaryContainer: BrandTokens.ink,
    secondary: BrandTokens.plum700,
    onSecondary: BrandTokens.paper,
    secondaryContainer: BrandTokens.plum600,
    onSecondaryContainer: BrandTokens.cream,
    tertiary: BrandTokens.gold,
    onTertiary: BrandTokens.paper,
    error: BrandTokens.danger,
    onError: BrandTokens.paper,
    errorContainer: BrandTokens.dangerContainer,
    onErrorContainer: BrandTokens.onDangerContainer,
    surface: BrandTokens.cream,
    onSurface: BrandTokens.ink,
    surfaceContainerHighest: BrandTokens.sand,
    onSurfaceVariant: BrandTokens.muted,
    surfaceContainerLowest: BrandTokens.paper,
    surfaceContainerLow: BrandTokens.paper,
    surfaceContainer: BrandTokens.sand,
    surfaceContainerHigh: BrandTokens.sand,
    outline: BrandTokens.stone,
    outlineVariant: BrandTokens.hairline,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: BrandTokens.plum950,
    onInverseSurface: BrandTokens.cream,
    inversePrimary: BrandTokens.honeyHover,
  );

  /// Dark color scheme, derived from the plum tokens (the prototype is
  /// light-first). Honey stays the primary; plum 950/800 are the grounds and
  /// cream is the body text, kept AA-honest.
  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: BrandTokens.honey,
    onPrimary: BrandTokens.onHoney,
    primaryContainer: BrandTokens.plum700,
    onPrimaryContainer: BrandTokens.cream,
    secondary: BrandTokens.plum600,
    onSecondary: BrandTokens.cream,
    secondaryContainer: BrandTokens.plum700,
    onSecondaryContainer: BrandTokens.cream,
    tertiary: BrandTokens.honeyHover,
    onTertiary: BrandTokens.onHoney,
    error: BrandTokens.dangerDark,
    onError: BrandTokens.plum950,
    errorContainer: BrandTokens.dangerContainerDark,
    onErrorContainer: BrandTokens.onDangerContainerDark,
    surface: BrandTokens.plum950,
    onSurface: BrandTokens.cream,
    surfaceContainerHighest: BrandTokens.plum800,
    onSurfaceVariant: BrandTokens.darkOnSurfaceVariant,
    surfaceContainerLowest: BrandTokens.plum950,
    surfaceContainerLow: BrandTokens.plum800,
    surfaceContainer: BrandTokens.plum800,
    surfaceContainerHigh: BrandTokens.plum700,
    outline: BrandTokens.plum500,
    outlineVariant: BrandTokens.plum700,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: BrandTokens.cream,
    onInverseSurface: BrandTokens.ink,
    inversePrimary: BrandTokens.gold,
  );

  static ThemeData light() => _themeFrom(lightScheme);
  static ThemeData dark() => _themeFrom(darkScheme);

  /// Builds a [ThemeData] from a brand [ColorScheme]: Archivo as the app-wide
  /// default text family, Playfair Display on the display/headline/title text
  /// styles (screen titles + brand, per the prototype).
  static ThemeData _themeFrom(ColorScheme scheme) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: bodyFontFamily,
    );

    // Apply the display serif to the display/headline tiers and `titleLarge`
    // — the screen-title/brand tiers — leaving every other style on Archivo
    // (inherited from `fontFamily` above). textTheme is resolved against the
    // scheme's brightness first so colors stay correct.
    //
    // `titleMedium` is deliberately *not* in this list (#628). Despite the
    // name it is Material's form-control tier, not a title tier: it is what
    // `DropdownButton` resolves for its selected value and menu items (there
    // is no theme override for that widget — `DropdownMenuThemeData` targets
    // the unrelated M3 `DropdownMenu`), and also what `PopupMenuButton`
    // items, `AlertDialog` content and `SnackBar` content default to. Serif
    // there put a Playfair word inside every sans-serif form, against the
    // prototype's "Archivo — all UI, labels, inputs, buttons, body"
    // (docs/design/prototype.md §Typography).
    //
    // Section headers keep the serif without this tier: [SectionHeader]
    // (theming/brand_widgets.dart) pins [displayFontFamily] itself, and it is
    // the app's one section-header mechanism.
    final display = base.textTheme.apply(fontFamily: displayFontFamily);
    final textTheme = base.textTheme.copyWith(
      displayLarge: display.displayLarge,
      displayMedium: display.displayMedium,
      displaySmall: display.displaySmall,
      headlineLarge: display.headlineLarge,
      headlineMedium: display.headlineMedium,
      headlineSmall: display.headlineSmall,
      titleLarge: display.titleLarge,
    );

    // Prototype header is a plum bar (docs/design/prototype.md: "Plum 700 —
    // headers"): plum ground with white title/icons. Centralizing it here
    // (rather than as inline hexes in the shell's AppBar) means the sync pill's
    // white label/dot and the Playfair title read on a known plum background
    // (white-on-plum700 ~9.6:1; verified computationally in the #243 PR — the
    // automated contrast test covers the ColorScheme role pairs).
    final headerBackground = scheme.brightness == Brightness.light
        ? BrandTokens.plum700
        : BrandTokens.plum800;
    const headerForeground = BrandTokens.paper;

    final isLight = scheme.brightness == Brightness.light;
    final brand = isLight ? BrandTheme.light : BrandTheme.dark;

    // The secondary action's own colors ("Secondary = outlined plum"). Light:
    // plum label on a plum border over cream (8.68:1 / 8.68:1). Dark: plum is
    // the ground, so the label is the body cream (14.71:1) and the border the
    // scheme's plum-500 outline (3.51:1, SC 1.4.11). Either way honey stays
    // reserved for the single primary action (#627).
    final secondaryActionForeground = isLight
        ? scheme.primary
        : scheme.onSurface;
    final secondaryActionBorder = isLight ? scheme.primary : scheme.outline;

    // The field focus ring — plum on light (8.68:1 on cream), the lifted body
    // tint on dark (11.13:1 on plum 950). Both are stronger than the resting
    // `outline` border they replace, which the contrast test asserts.
    final focusRing = isLight ? scheme.secondary : scheme.onSurfaceVariant;

    return base.copyWith(
      textTheme: textTheme,
      extensions: [brand],
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: headerBackground,
        foregroundColor: headerForeground,
        // The header title uses Playfair (titleLarge) on the plum header, so
        // the shell no longer needs an inline fontFamily/color override.
        titleTextStyle: textTheme.titleLarge?.copyWith(color: headerForeground),
        iconTheme: const IconThemeData(color: headerForeground),
      ),
      // Prototype cards: white on a 1px hairline, flat (no Material shadow),
      // the 16px content radius (BrandDimens). In dark mode brand.cardColor is
      // a raised plum so cards still lift off the plum-950 ground.
      cardTheme: base.cardTheme.copyWith(
        color: brand.cardColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BrandDimens.borderCard,
          side: BorderSide(color: brand.cardBorder),
        ),
      ),
      // Field controls: filled paper, a 1.5px border at the 14px field radius,
      // a focus ring that is always *stronger* than the resting border (the
      // prototype focuses to plum, not honey; on the dark ground plum is the
      // ground, so the ring is the lifted body tint instead — plum 600 there
      // would be dimmer than the resting plum-500 outline, reading as losing
      // focus rather than gaining it, #627). Sized to the gloves-friendly
      // 58px control height.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: brand.cardColor,
        constraints: const BoxConstraints(minHeight: BrandDimens.heightField),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
        border: _fieldBorder(scheme.outline),
        enabledBorder: _fieldBorder(scheme.outline),
        focusedBorder: _fieldBorder(focusRing, width: 1.5),
        errorBorder: _fieldBorder(scheme.error),
        focusedErrorBorder: _fieldBorder(scheme.error, width: 1.5),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      // The primary action's shape — 60px tall at the 16px button radius,
      // Archivo 700/18. Only shape/size/typography: the honey fill is pinned
      // by `PrimaryActionButton` itself, not here, because this theme is also
      // what `FilledButton.tonal` (a deliberately *lower*-emphasis control)
      // resolves against — forcing honey here would repaint those too.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(BrandDimens.heightPrimaryButton),
          shape: const RoundedRectangleBorder(
            borderRadius: BrandDimens.borderCard,
          ),
          textStyle: textTheme.titleMedium?.copyWith(
            fontFamily: bodyFontFamily,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ),
      // Secondary / destructive — outlined, 56px, 1.5px border at the button
      // radius. In light mode the label and the border are both plum
      // ("Secondary = outlined plum", docs/design/prototype.md): Material's
      // default would draw them in `primary`/`outline`, which used to mean a
      // honey label at 1.84:1 on cream (#627). In dark mode plum *is* the
      // ground, so the label takes the body-text cream and the border keeps
      // the scheme's (plum-500) outline.
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(BrandDimens.heightSecondaryButton),
          foregroundColor: secondaryActionForeground,
          side: BorderSide(color: secondaryActionBorder, width: 1.5),
          shape: const RoundedRectangleBorder(
            borderRadius: BrandDimens.borderCard,
          ),
          textStyle: textTheme.titleMedium?.copyWith(
            fontFamily: bodyFontFamily,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
      ),
      // Type / period / sort chips render as 44px pills.
      chipTheme: base.chipTheme.copyWith(
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outline, width: 1.5),
        labelStyle: textTheme.labelLarge?.copyWith(
          fontFamily: bodyFontFamily,
          fontWeight: FontWeight.w600,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      // Bottom nav on the plum ground with a honey selection (prototype
      // bottom-nav = plum 800, honey selected pill/icon).
      navigationBarTheme: base.navigationBarTheme.copyWith(
        backgroundColor: BrandTokens.plum800,
        indicatorColor: BrandTokens.honey.withValues(alpha: 0.22),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? const IconThemeData(color: BrandTokens.honey)
              : const IconThemeData(color: BrandTokens.darkOnSurfaceVariant),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => textTheme.labelMedium!.copyWith(
            fontFamily: bodyFontFamily,
            fontWeight: FontWeight.w600,
            color: states.contains(WidgetState.selected)
                ? BrandTokens.honey
                : BrandTokens.darkOnSurfaceVariant,
          ),
        ),
      ),
      // Contextual honey FAB pill, shared with PrimaryActionButton's honey.
      // Pinned to the token rather than to `scheme.primary`: the FAB is one of
      // the two places the single primary action lives, and `primary` is the
      // accent role that has to stay legible *on* a light surface, which honey
      // isn't (#627).
      floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
        backgroundColor: BrandTokens.honey,
        foregroundColor: BrandTokens.onHoney,
        extendedTextStyle: textTheme.titleMedium?.copyWith(
          fontFamily: bodyFontFamily,
          fontWeight: FontWeight.w700,
          fontSize: 16,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: brand.cardBorder,
        thickness: 1,
        space: 1,
      ),
    );
  }

  /// A rounded 1.5px input border at the field radius, in [color].
  static OutlineInputBorder _fieldBorder(Color color, {double width = 1.5}) {
    return OutlineInputBorder(
      borderRadius: BrandDimens.borderField,
      borderSide: BorderSide(color: color, width: width),
    );
  }
}
