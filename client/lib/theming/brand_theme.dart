import 'package:flutter/material.dart';

import 'brand_tokens.dart';

/// Accent + tint pair for an activity type's leading icon tile (prototype
/// `TIPOS`): [color] draws the icon/label, [tint] fills the tile behind it.
@immutable
class ActivityTypeVisual {
  const ActivityTypeVisual({required this.color, required this.tint});

  final Color color;
  final Color tint;
}

/// Brand look-and-feel roles that Material's [ColorScheme] doesn't have a slot
/// for (FR-UX-1, D-18, EPIC-11) — the plum hero surface, the gold section
/// eyebrow, the sand notes callout, the muted disclosure chevron, and the
/// per-activity-type accents.
///
/// These live on a [ThemeExtension] (resolved via the [BuildContext.brand]
/// getter below, i.e. `Theme.of(context).extension`) rather than as inline
/// `BrandTokens.*` reads in each screen, so the values adapt to light/dark in
/// one place. The prototype is light-first; [BrandTheme.dark] derives the same
/// roles from the plum grounds.
@immutable
class BrandTheme extends ThemeExtension<BrandTheme> {
  const BrandTheme({
    required this.eyebrow,
    required this.heroSurface,
    required this.onHeroSurface,
    required this.onHeroSurfaceMuted,
    required this.cardColor,
    required this.cardBorder,
    required this.notesBg,
    required this.notesBorder,
    required this.notesText,
    required this.notesIcon,
    required this.trailingIcon,
    required this.cresta,
    required this.feeding,
    required this.treatment,
    required this.generic,
  });

  /// Section eyebrow / step-label colour (gold on light).
  final Color eyebrow;

  /// Plum hero-card ground and its foregrounds.
  final Color heroSurface;
  final Color onHeroSurface;
  final Color onHeroSurfaceMuted;

  /// The white-on-hairline content card (adapts to a raised plum in dark).
  final Color cardColor;
  final Color cardBorder;

  /// Sand "sticky note" callout roles.
  final Color notesBg;
  final Color notesBorder;
  final Color notesText;
  final Color notesIcon;

  /// The low-emphasis disclosure chevron / trailing affordance.
  final Color trailingIcon;

  /// Per-activity-type accent + tile tint.
  final ActivityTypeVisual cresta;
  final ActivityTypeVisual feeding;
  final ActivityTypeVisual treatment;
  final ActivityTypeVisual generic;

  /// Light-first brand roles (the prototype palette verbatim).
  static const BrandTheme light = BrandTheme(
    eyebrow: BrandTokens.gold,
    heroSurface: BrandTokens.plum700,
    onHeroSurface: BrandTokens.paper,
    onHeroSurfaceMuted: Color(0xFFCFC8DE),
    cardColor: BrandTokens.paper,
    cardBorder: BrandTokens.hairline,
    notesBg: BrandTokens.notesBg,
    notesBorder: BrandTokens.notesBorder,
    notesText: BrandTokens.notesText,
    notesIcon: BrandTokens.gold,
    trailingIcon: BrandTokens.trailingMuted,
    cresta: ActivityTypeVisual(
      color: BrandTokens.gold,
      tint: BrandTokens.crestaTint,
    ),
    feeding: ActivityTypeVisual(
      color: BrandTokens.feedingGreen,
      tint: BrandTokens.feedingTint,
    ),
    treatment: ActivityTypeVisual(
      color: BrandTokens.treatmentRed,
      tint: BrandTokens.treatmentTint,
    ),
    generic: ActivityTypeVisual(
      color: BrandTokens.muted,
      tint: BrandTokens.genericTint,
    ),
  );

  /// Dark roles, derived from the plum grounds. Hero stays plum (a step up
  /// from the plum-950 ground); cards become raised plum on a subtle border;
  /// the activity tints become translucent accent washes so a coloured icon
  /// still reads on a dark tile.
  static const BrandTheme dark = BrandTheme(
    eyebrow: BrandTokens.honeyHover,
    heroSurface: BrandTokens.plum700,
    onHeroSurface: BrandTokens.paper,
    onHeroSurfaceMuted: Color(0xFFCFC8DE),
    cardColor: BrandTokens.plum800,
    cardBorder: BrandTokens.plum600,
    notesBg: Color(0xFF3A331C),
    notesBorder: Color(0xFF5A4E24),
    notesText: Color(0xFFE9DEBC),
    notesIcon: BrandTokens.honeyHover,
    trailingIcon: BrandTokens.plum600,
    cresta: ActivityTypeVisual(
      color: Color(0xFFE0B44E),
      tint: Color(0x33B0862B),
    ),
    feeding: ActivityTypeVisual(
      color: Color(0xFF7BC98A),
      tint: Color(0x333E7D53),
    ),
    treatment: ActivityTypeVisual(
      color: BrandTokens.dangerDark,
      tint: Color(0x33B3564D),
    ),
    generic: ActivityTypeVisual(
      color: BrandTokens.darkOnSurfaceVariant,
      tint: Color(0x33574B73),
    ),
  );

  @override
  BrandTheme copyWith({
    Color? eyebrow,
    Color? heroSurface,
    Color? onHeroSurface,
    Color? onHeroSurfaceMuted,
    Color? cardColor,
    Color? cardBorder,
    Color? notesBg,
    Color? notesBorder,
    Color? notesText,
    Color? notesIcon,
    Color? trailingIcon,
    ActivityTypeVisual? cresta,
    ActivityTypeVisual? feeding,
    ActivityTypeVisual? treatment,
    ActivityTypeVisual? generic,
  }) {
    return BrandTheme(
      eyebrow: eyebrow ?? this.eyebrow,
      heroSurface: heroSurface ?? this.heroSurface,
      onHeroSurface: onHeroSurface ?? this.onHeroSurface,
      onHeroSurfaceMuted: onHeroSurfaceMuted ?? this.onHeroSurfaceMuted,
      cardColor: cardColor ?? this.cardColor,
      cardBorder: cardBorder ?? this.cardBorder,
      notesBg: notesBg ?? this.notesBg,
      notesBorder: notesBorder ?? this.notesBorder,
      notesText: notesText ?? this.notesText,
      notesIcon: notesIcon ?? this.notesIcon,
      trailingIcon: trailingIcon ?? this.trailingIcon,
      cresta: cresta ?? this.cresta,
      feeding: feeding ?? this.feeding,
      treatment: treatment ?? this.treatment,
      generic: generic ?? this.generic,
    );
  }

  @override
  BrandTheme lerp(covariant BrandTheme? other, double t) {
    if (other == null) return this;
    ActivityTypeVisual lerpVisual(ActivityTypeVisual a, ActivityTypeVisual b) =>
        ActivityTypeVisual(
          color: Color.lerp(a.color, b.color, t)!,
          tint: Color.lerp(a.tint, b.tint, t)!,
        );
    return BrandTheme(
      eyebrow: Color.lerp(eyebrow, other.eyebrow, t)!,
      heroSurface: Color.lerp(heroSurface, other.heroSurface, t)!,
      onHeroSurface: Color.lerp(onHeroSurface, other.onHeroSurface, t)!,
      onHeroSurfaceMuted: Color.lerp(
        onHeroSurfaceMuted,
        other.onHeroSurfaceMuted,
        t,
      )!,
      cardColor: Color.lerp(cardColor, other.cardColor, t)!,
      cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      notesBg: Color.lerp(notesBg, other.notesBg, t)!,
      notesBorder: Color.lerp(notesBorder, other.notesBorder, t)!,
      notesText: Color.lerp(notesText, other.notesText, t)!,
      notesIcon: Color.lerp(notesIcon, other.notesIcon, t)!,
      trailingIcon: Color.lerp(trailingIcon, other.trailingIcon, t)!,
      cresta: lerpVisual(cresta, other.cresta),
      feeding: lerpVisual(feeding, other.feeding),
      treatment: lerpVisual(treatment, other.treatment),
      generic: lerpVisual(generic, other.generic),
    );
  }
}

/// `context.brand` — the [BrandTheme] extension, falling back to [BrandTheme
/// .light] if (unexpectedly) unregistered so a screen never crashes on a null
/// extension.
extension BrandThemeContext on BuildContext {
  BrandTheme get brand =>
      Theme.of(this).extension<BrandTheme>() ?? BrandTheme.light;
}
