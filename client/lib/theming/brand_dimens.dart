import 'package:flutter/painting.dart' show BorderRadius, Radius;

/// Melargil layout scale — radii, control heights and spacing (FR-UX-1,
/// FR-AX-1, D-18, EPIC-11).
///
/// The single source of truth for the *shape* half of the brand, the way
/// [BrandTokens] is the single source of truth for its *colour* half. These
/// name the prototype's measurements (`docs/design/prototype.md` §Components &
/// rules: "Controls are 52–60px tall … Radii 12–20px; chips = 40–44px pills")
/// so `AppTheme`'s component themes and the shared branded widgets draw their
/// radii/heights from here, not from inline magic numbers scattered per screen.
///
/// The prototype is a directional guideline, not a pixel spec: where a field
/// control's height would drop below the app's gloves-friendly 44×44 tap-target
/// floor (`tap_target.dart`), the larger value wins — every height named here
/// is already at or above that floor.
abstract final class BrandDimens {
  // --- Corner radii (prototype: 12–20px) ---

  /// Inputs / selects / small controls — the 14px field radius.
  static const double radiusField = 14;

  /// Primary/secondary buttons and the standard list/content card — 16px.
  static const double radiusCard = 16;

  /// Larger cards (account sections, journeys, menu lists) — 18px.
  static const double radiusCardLarge = 18;

  /// Hero cards (the plum detail headers) — the roomiest 20px radius.
  static const double radiusHero = 20;

  /// Leading icon tiles inside rows and small chrome (icon buttons) — 12px.
  static const double radiusTile = 12;

  /// Small status pills / badges (priority, role, journey state) — 8px.
  static const double radiusBadge = 8;

  /// Pill radius for chips and the sync/nav pills — large enough that a
  /// [heightChip]-tall chip renders as a full pill.
  static const double radiusPill = 999;

  /// [BorderRadius] conveniences for the common radii above.
  static const BorderRadius borderField = BorderRadius.all(
    Radius.circular(radiusField),
  );
  static const BorderRadius borderCard = BorderRadius.all(
    Radius.circular(radiusCard),
  );
  static const BorderRadius borderCardLarge = BorderRadius.all(
    Radius.circular(radiusCardLarge),
  );
  static const BorderRadius borderHero = BorderRadius.all(
    Radius.circular(radiusHero),
  );
  static const BorderRadius borderTile = BorderRadius.all(
    Radius.circular(radiusTile),
  );

  // --- Control heights (prototype: 52–60px; never below the 44px floor) ---

  /// The primary honey action (save, sign in) — 60px, the tallest control.
  static const double heightPrimaryButton = 60;

  /// Secondary/destructive outlined actions (logout, delete) — 56px.
  static const double heightSecondaryButton = 56;

  /// Text inputs / selects — 58px.
  static const double heightField = 58;

  /// Inline search bar and the small period select — 52px.
  static const double heightSearch = 52;

  /// Type / period / sort chips — 44px pills.
  static const double heightChip = 44;

  /// Smaller inline chips (sort order, journey ordering) — 40px, still a pill.
  static const double heightChipSmall = 40;

  /// Leading icon tile inside apiary list rows — 48px.
  static const double sizeLeadingTile = 48;

  /// Leading icon tile inside activity rows — 42px.
  static const double sizeLeadingTileSmall = 42;

  // --- Spacing scale ---

  /// The screen edge gutter used by list/content screens (16px).
  static const double gutter = 16;

  /// The wider gutter used by form screens (20px).
  static const double gutterForm = 20;

  /// Standard gap between stacked cards in a list.
  static const double gapCard = 10;

  /// Standard gap between stacked fields in a form.
  static const double gapField = 16;

  /// Card interior padding (list/content cards).
  static const double padCard = 16;

  /// Hero-card interior padding.
  static const double padHero = 20;

  /// Bottom padding that clears the floating action button on scrollable
  /// screens (the prototype's `padding-bottom:120px`).
  static const double scrollBottomInset = 120;
}
