import 'package:flutter/painting.dart' show Color;

/// Melargil brand color tokens (FR-UX-1, FR-AX-1, D-18, EPIC-11 #243).
///
/// The single source of truth for every brand hex in the client. These name
/// the prototype's palette (`docs/design/prototype.md` §Design tokens —
/// "Melargil · Mel de Montargil, Portugal") so that `AppTheme` and any screen
/// draw brand color from here, not from inline `Color(0x...)` literals. If a
/// brand hex appears anywhere else under `lib/`, that's the bug this file
/// exists to prevent.
///
/// The prototype is a directional guideline, not a pixel spec: where a raw
/// token can't meet WCAG 2.2 AA in a given role (e.g. honey text on a light
/// ground, or gold/stone as body text), `AppTheme` picks a different token for
/// that role rather than shipping a low-contrast pair — the palette entries
/// below stay faithful to the prototype; their *roles* are chosen for AA in
/// `app_theme.dart`. Contrast for every role the theme uses is enforced by
/// `test/theming/app_theme_contrast_test.dart`.
abstract final class BrandTokens {
  // --- Plum (frame / surfaces / bottom-nav) ---

  /// Plum 950 `#221D31` — app frame / darkest ground (dark-mode surface).
  static const plum950 = Color(0xFF221D31);

  /// Plum 800 `#3D3454` — bottom-nav; offline-banner ground.
  static const plum800 = Color(0xFF3D3454);

  /// Plum 700 `#4A3F63` — headers, hero cards, primary plum surfaces.
  static const plum700 = Color(0xFF4A3F63);

  /// Plum 600 `#574B73` — hover / raised plum surface.
  static const plum600 = Color(0xFF574B73);

  // --- Honey / gold (the one accent) ---

  /// Honey `#F0A81F` — **the** primary action + highlights (one accent).
  /// "Honey is the only primary action" (`docs/design/prototype.md`).
  static const honey = Color(0xFFF0A81F);

  /// Honey hover `#F7B637` — hover/pressed state of [honey].
  static const honeyHover = Color(0xFFF7B637);

  /// Gold `#B0862B` — section eyebrows, hive/amber labels. Decorative only:
  /// it does not meet AA as body text on a light ground, so it is never used
  /// as an `on*` text role.
  static const gold = Color(0xFFB0862B);

  /// The dark brown that sits legibly on [honey] (6.5:1) — brand `on-primary`.
  /// Not a prototype swatch name, but the exact ink the prototype's honey FAB
  /// uses for its label/icon; kept here so on-honey text has one definition.
  static const onHoney = Color(0xFF3A2E14);

  // --- Neutrals / grounds ---

  /// Cream `#F6F3EC` — app background / light-mode surface ground.
  static const cream = Color(0xFFF6F3EC);

  /// Sand `#F4EDDB` — tinted tiles / light container surface.
  static const sand = Color(0xFFF4EDDB);

  /// Paper `#FFFFFF` — cards, inputs.
  static const paper = Color(0xFFFFFFFF);

  /// Ink `#2B2438` — primary body text.
  static const ink = Color(0xFF2B2438);

  /// Muted `#6E6680` — secondary text (meets AA on cream/sand/paper).
  static const muted = Color(0xFF6E6680);

  /// Stone `#8B8270` — tertiary text/hint. Decorative on light grounds (below
  /// AA as body text), so not used as an `on*` text role.
  static const stone = Color(0xFF8B8270);

  // --- Borders ---

  /// Hairline `#E7E1D3` — card borders (the 1px card hairline).
  static const hairline = Color(0xFFE7E1D3);

  /// Line `#D8D1C0` — input borders (slightly stronger than [hairline]).
  static const line = Color(0xFFD8D1C0);

  // --- Status ---

  /// Info `#2A6FDB` — "you are here" map dot / informational accent.
  static const info = Color(0xFF2A6FDB);

  /// Danger `#B3423A` — logout, revoke, destructive actions.
  static const danger = Color(0xFFB3423A);

  // --- Derived scheme-support shades ---
  // Not prototype swatches, but kept here so `app_theme.dart` holds NO brand
  // hex of its own: these fill the Material `ColorScheme` container/dark-mode
  // roles the prototype's light-first swatch list doesn't name, tuned to meet
  // WCAG 2.2 AA against their paired `on*` color (verified in the contrast
  // test).

  /// Light error-container tint (a desaturated wash of [danger]).
  static const dangerContainer = Color(0xFFF7E4E2);

  /// On-color for [dangerContainer] (a deep [danger] shade) — AA on the tint.
  static const onDangerContainer = Color(0xFF5A1B16);

  /// Sync-status "online & caught up" green — the only non-brand-palette hue
  /// the shell needs (the prototype's sync pill; amber = in-progress states
  /// reuses [honey]). Legible as a 9px dot on the plum header.
  static const online = Color(0xFF7BC98A);

  // Dark-mode plum-derived text/danger shades (prototype is light-first; the
  // dark scheme derives from the plum tokens above).

  /// Dark-mode body text on plum surfaces (a lifted [cream]).
  static const darkOnSurfaceVariant = Color(0xFFD9D2E6);

  /// Dark-mode danger (a lightened [danger] that reads on plum).
  static const dangerDark = Color(0xFFE88A84);

  /// Dark-mode error-container ground (a deep danger shade).
  static const dangerContainerDark = Color(0xFF5A2320);

  /// On-color for [dangerContainerDark] (a light danger tint).
  static const onDangerContainerDark = Color(0xFFF2C7C3);
}
