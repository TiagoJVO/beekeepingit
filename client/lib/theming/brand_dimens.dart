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

  /// Bottom padding a scrollable screen leaves under its last card, so the
  /// bottom chrome never lands on content (the prototype's
  /// `padding-bottom:120px`).
  ///
  /// The chrome it has to clear is the floating action button *and* the
  /// confirmation toast (#631) — the toast is the app's only "your save
  /// worked" signal, so the card it is reporting on has to stay visible under
  /// it. A two-line toast at the 200% text scale the field UX supports
  /// (FR-AX-1) measures ~108 on a 375pt screen.
  ///
  /// This number is a **heuristic margin, not derived arithmetic**. Do not
  /// reconstruct it as `108 + gapToastNav`: [gapToastNav] sits *below* the
  /// body, not inside it — the body ends at the gutter's top edge, which is
  /// also where a fixed toast's bottom lands, so the band only ever has to
  /// cover the toast's own height. 120 already cleared ~108 by 12. The extra
  /// 16 buys headroom for the cases the measurement does not cover: a
  /// narrower screen, or a message long enough to wrap to three lines
  /// (`syncSupersededNotice` is far longer than "Apiary saved"), either of
  /// which overruns 136 as easily as 120. Re-measure before tuning it.
  static const double scrollBottomInset = 136;

  /// Gap between a confirmation toast and the bottom navigation under it
  /// (#631) — the prototype floats its toast at `bottom:110px` over a ~96px
  /// tab bar rather than resting it on the bar's top edge, which on this
  /// palette would abut a plum-950 toast against the plum-800 navigation and
  /// read as one block.
  ///
  /// This is *only* the gap. How far above the window bottom it lands the
  /// toast is the `Scaffold`'s own arithmetic — it anchors a fixed `SnackBar`
  /// at the top of its bottom chrome, whatever that chrome measures — so no
  /// navigation-bar height is encoded here or anywhere else.
  static const double gapToastNav = 14;

  /// [scrollBottomInset] as the screen at [context] actually has to reserve
  /// it — the constant plus whatever bottom inset the *window* adds to that
  /// screen's own bottom chrome (#773, FR-UX-2/FR-AX-1).
  ///
  /// The constant above sizes the chrome itself, and #631 has now re-derived
  /// it against the toast. This helper deliberately restates no number from
  /// it: it adds only what the constant cannot know, which is the window
  /// inset the screen at [context] actually carries.
  ///
  /// On a screen with a bottom navigation bar the constant is the whole
  /// story: `Scaffold` strips the window's
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
  /// Reading the inset off the ambient [MediaQuery] resolves to 0 inside the
  /// shell and to the real inset outside it, so this one expression is
  /// correct on both sides of the shell — which is why it is a derivation
  /// here rather than a second constant.
  ///
  /// Precisely what that correctness rests on, since it is easy to overstate:
  /// **no `Scaffold` with a `bottomNavigationBar` sits between the caller and
  /// the shell.** It does *not* rest on reading the context from inside a
  /// `body:` slot — every call site today reads its own `build` context,
  /// which is above its screen's local `Scaffold`, and is right anyway
  /// because none of those local `Scaffold`s sets a `bottomNavigationBar`;
  /// only the shell's outer one does, and that is an ancestor either way. A
  /// future screen nested in the shell that gives itself a local
  /// `bottomNavigationBar` would break that assumption — reserve from a
  /// context below that bar's `Scaffold`, or reserve the bare constant.
  ///
  /// Second precondition, and the one #789 will meet first: **no `SafeArea`
  /// (or `MediaQuery.removePadding`) between this read and the scroll view
  /// being padded.** Below a `SafeArea` the inset is already consumed and the
  /// helper correctly contributes 0; read above one and the padding
  /// double-counts it. `login_screen.dart` is exactly that shape.
  static double scrollBottomInsetOf(BuildContext context) =>
      scrollBottomInset + MediaQuery.paddingOf(context).bottom;

  // --- Content width caps (#650) ---

  /// The narrow single-column content cap — 480px.
  ///
  /// Names the convention ~18 call sites already hand-roll as a bare
  /// `maxWidth: 480` (forms, auth screens, hero cards): the width at which a
  /// single field/card column stays readable without turning into a
  /// full-bleed desktop slab. Use this constant for new call sites instead of
  /// repeating the literal; see `git grep -n "maxWidth: 480" -- client/lib`
  /// for the existing ones (some, like `login_screen.dart`'s 360 and
  /// `apiary_map_screen.dart`'s 124, are deliberately different concepts and
  /// stay as their own literals).
  static const double maxWidthContent = 480;

  /// The list-screen content cap — 720px, deliberately *not* [maxWidthContent].
  ///
  /// List rows need more breathing room than a single form column, but the
  /// number is bounded above by
  /// `activity_list_widgets.dart`'s `_kCompactRowBelowWidth` (600): that
  /// widget measures its compact-vs-wide layout switch against the row's own
  /// incoming constraints, not the window. A content column of 480 would
  /// leave an activity row only `480 - 2*gutter` = 448px wide — under 600 —
  /// and would silently flip every desktop activity row into the compact
  /// three-line phone layout that #632 shipped specifically to distinguish
  /// from wide. The worst-case bound is 720 minus the widest gutter any list
  /// screen applies ([gutter], 16px each side): 688px, ~15% of clearance
  /// above the 600px compact threshold. That is a conservative floor, not a
  /// measurement of either call site that actually embeds the activity row
  /// today — `activities_list_screen.dart` and `apiary_activities_screen
  /// .dart` apply no horizontal padding around `ActivityListView` at all, so
  /// the row's real incoming width there is the full 720, and the real
  /// margin over 600 is wider still. Do not narrow this constant without
  /// re-checking the 688px worst case against `_kCompactRowBelowWidth`.
  static const double maxWidthList = 720;

  // --- Layout breakpoints (#650) ---

  /// The window width, in logical pixels off `MediaQuery.sizeOf(context)
  /// .width`, at or above which the shell swaps its bottom [NavigationBar]
  /// for a side [NavigationRail] (`app_shell.dart`).
  ///
  /// 840, not Material 3's more commonly cited 600 tablet breakpoint, for two
  /// load-bearing reasons. First, Material 3's *expanded* window size class
  /// starts at 840 — 600-840 is tablet-portrait/split-screen, where D-35's
  /// thumb-reachable bottom bar is still the field-correct chrome; only a
  /// genuinely wide, desktop-shaped window earns the rail. Second, and just
  /// as binding in practice: Flutter's default widget-test surface is
  /// 800x600 logical. A 600 breakpoint would flip the *entire* existing shell
  /// test suite to the rail and break every `shell-tab-*` tap across it
  /// (~30 in `apiary_detail_screen_test.dart` alone). At 840 every existing
  /// test — which never sets an explicit viewport — keeps the
  /// `NavigationBar` untouched, and only tests that explicitly opt into a
  /// desktop-sized viewport (`app_shell_test.dart`'s desktop group) see the
  /// rail. Do not change this number without re-auditing both reasons.
  static const double breakpointExpanded = 840;
}
