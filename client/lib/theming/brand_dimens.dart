// `widgets` rather than `painting` only for [BrandDimens.scrollBottomInsetOf],
// the one measurement here that a screen cannot know without asking its own
// `MediaQuery`. Everything else in this file is still a plain number.
import 'package:flutter/widgets.dart'
    show BorderRadius, BuildContext, MediaQuery, Radius;

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

  /// The brand mark's default edge length — 96px (#686).
  static const double sizeBrandMark = 96;

  /// The brand mark's squircle — 28px at [sizeBrandMark] (#686).
  ///
  /// Deliberately outside the prototype's 12–20px content range: this is the
  /// app-icon tile, and it is rounded to read like the icon the operating
  /// system draws for the installed app, not like a card.
  ///
  /// It is a *proportion*, not a fixed inset: `BrandMark` scales it with the
  /// requested size, because a radius held at 28 would clamp to half the box
  /// (`RRect`'s own rule) and turn any mark at or below 56px into a plain
  /// circle — the one shape the app icon is not.
  static const double radiusBrandMark = 28;

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

  /// [scrollBottomInset] as the screen at [context] actually has to reserve
  /// it — the constant plus whatever bottom inset the *window* adds to that
  /// screen's own bottom chrome (#773, FR-UX-2/FR-AX-1).
  ///
  /// The constant sizes the chrome itself. On a screen with a bottom
  /// navigation bar that is the whole story: `Scaffold` strips the window's
  /// bottom padding from the body **and** from the toast it places over it —
  /// literally the same `removeBottomPadding: bottomNavigationBar != null ||
  /// persistentFooterButtons != null` flag feeds both slots — so the toast's
  /// opaque bar ends exactly where the body does.
  ///
  /// On a screen with neither (every route declared outside the shell in
  /// `app_router.dart` — the members list, the stock-declaration log, the
  /// needs-fix list) nothing is stripped from either, so a fixed `SnackBar`
  /// carries the home-indicator inset *inside* its own bar and covers that
  /// much more body: measured 142 rather than 108 at the 200% text scale
  /// FR-AX-1 supports, on a 375x812 phone with a 34pt inset. Reserving the
  /// bare constant there under-reserves by exactly the inset.
  ///
  /// Reading the inset off the [MediaQuery] the `Scaffold` handed the body
  /// resolves to 0 inside the shell and to the real inset outside it, so this
  /// one expression is correct on both sides of the shell — which is why it
  /// is a derivation here rather than a second constant.
  static double scrollBottomInsetOf(BuildContext context) =>
      scrollBottomInset + MediaQuery.paddingOf(context).bottom;
}
