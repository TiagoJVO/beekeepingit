# Melargil — Flutter design system (as-built)

> **Status: as-built.** This documents how the prototype's look-and-feel
> (`prototype.md`, the directional guideline) is implemented in the Flutter
> client. When building or restyling a screen, compose the tokens and widgets
> below instead of re-deriving paddings/radii/colours inline — that is what
> keeps existing and future screens visually consistent. `prototype.md` remains
> the directional source of truth for _look_; this is the _mechanism_.

## Where the system lives (`client/lib/theming/`)

| File                 | What                                                                                                                                                                             |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `brand_tokens.dart`  | Every brand **colour** hex (single source of truth). Includes the activity-type palette, notes-card and trailing-chevron tints.                                                  |
| `brand_dimens.dart`  | Every brand **radius / control height / spacing** value.                                                                                                                         |
| `brand_theme.dart`   | `BrandTheme` `ThemeExtension` — look-and-feel roles Material's `ColorScheme` lacks (hero surface, eyebrow, notes, per-type accents). Read via `context.brand`. Brightness-aware. |
| `app_theme.dart`     | Builds `ThemeData` from the above: colour scheme **plus** component themes (cards, inputs, buttons, chips, nav, FAB) so default widgets already look right.                      |
| `brand_widgets.dart` | The shared building blocks screens compose (see below).                                                                                                                          |

Field-action buttons live in `core/widgets/field_action_button.dart`
(`PrimaryActionButton` = honey 60px; `SecondaryActionButton` = outlined plum 56px,
`destructive:` for delete/logout). Tap-target floor: `core/widgets/tap_target.dart`.

## The scale (from the prototype)

- **Radii:** field `14`, button/card `16`, large card `18`, hero `20`, tile
  `12`, badge `8`, chips = pills. (`BrandDimens.radius*` / `border*`.) The brand
  mark's `28` sits outside that range on purpose — it is an app-icon tile, not a
  card.
- **Heights:** primary button `60`, secondary `56`, input `58`, search `52`,
  chip `44` (small `40`). Never below the 44px gloves-friendly floor.
- **Gutters:** list/content screens `16`, form screens `20`; scrollables pad
  `120` at the bottom to clear the FAB (`BrandDimens.scrollBottomInset`).
  That inset is for screens a FAB actually floats over — a tab root, or a
  pushed screen with its own FAB (e.g. `todo_detail_screen.dart`). A
  full-screen **form** is a pushed route with no FAB at all (the shell hides
  its own on any pushed route), and its pinned action bar sits outside the
  scroll view (`#341`/`#357`) — so it pads a plain `8` at the bottom and lets
  the bar do the clearing.
- **The bottom band, off the shell:** a scrollable reserves that band for the
  toast as much as for the FAB, so a screen with **neither** still reserves it
  — the members list, the stock-declaration log, the needs-fix list and the
  full history timeline all did not, which is `#773`. Take it from
  `BrandDimens.scrollBottomInsetOf(context)`, never the bare constant: outside
  the shell there is no bottom navigation for `Scaffold` to strip the window's
  bottom padding against, so a fixed `SnackBar` carries the home-indicator
  inset **inside its own bar** and covers that much more of the body (measured
  142 rather than 108 at 200% text on a 375×812 phone). Read off the
  `MediaQuery` the `Scaffold` hands the body, that inset is `0` inside the
  shell and the real value outside it, so the one call is right on both sides.
  A screen that genuinely needs nothing says so in a comment where the padding
  would have gone — a silent flat gutter reads as an oversight, because that
  is what `#773` was.

## Widgets (`brand_widgets.dart`) — compose these

- **`BrandMark({size, borderRadius})`** — the app's **one** brand mark: the
  Melargil bee, clipped to the app-icon squircle. It draws
  `client/assets/brand/app-icon-512.png`, which is a byte-identical copy of the
  shipped PWA icon `client/web/icons/Icon-512.png` (`#233`/`#681`), so the mark
  a screen shows and the icon the OS shows are the same artwork rather than two
  that can drift (`#686`). The artwork carries its own amber ground, so there is
  no light/dark variant and nothing to tint; it is a logotype, so the AA
  contrast floor does not apply. Its screen-reader label comes from the ARB
  files (`appLogoLabel`). **Never redraw the mark inline** — before `#686` the
  login screen drew a Material honeycomb glyph on a honey tile, which is how the
  app ended up presenting two marks at once.
  `client/test/brand_mark_asset_test.dart` fails if the copy and the icon
  diverge — regenerating the icon set (`#682`) must re-copy it.
- **`Eyebrow(text)`** — gold, uppercase, letter-spaced section/step label.
- **`SectionHeader(text)`** — Playfair 19 serif header between content blocks.
- **`LabeledField(label:, child:)`** — label _above_ the field (the prototype
  pattern), not a floating Material label. Wrap `TextFormField`/`DropdownButton`.
  It also hands the label to the wrapped control as that control's **accessible
  name** — the name `InputDecoration.labelText` used to put on the input's own
  semantics node, and what `client/e2e`'s `getByLabel(...)` reads — and excludes
  the visible `Text` from semantics so it is announced once, not twice. Pass
  `labelsChild: false` when the child is a **group** rather than one control (a
  picker's search box plus its result list, a block with its own buttons, a
  read-only value supplying its own combined label); annotating a group folds
  the label into whichever descendant node comes first.
- **`HeroCard(child:)`** — the plum detail/settings header (radius 20, white
  foreground via `context.brand.onHeroSurface`).
- **`BrandCard(child:, onTap:)`** — white card on the 1px hairline; tappable
  ripple when `onTap` is set. Passing `semanticLabel` makes the card announce
  as **one node** — its child's own semantics are excluded, so the label is
  the whole announcement (`#662`). Don't pass it on a card whose child has its
  own focusable controls.
- **`BrandRowCard(title:, subtitle:, leading:, trailing:, onTap:)`** — the
  standard list row (leading tile · title/subtitle · trailing · chevron).
  A `trailing` badge that carries meaning of its own (overdue, open/closed,
  progress) must spell that meaning into `trailingSemanticLabel`, or it is
  silent to a screen reader; leave it null when the badge only restates the
  subtitle, so the row doesn't say the same sentence twice.
- **`LeadingIconTile(icon:, color:, tint:)`** — the rounded tinted icon square.
- **`NotesCard(text:)`** — the sand "sticky note" callout.
- **`EmptyState(message:, icon:)`** — centered empty/no-results message.
- **`BrandChip(label:, selected:, onTap:, accent:)`** — selectable pill filter.
- **`MenuListCard(rows: [MenuRow(...)])`** — grouped settings/menu card with
  hairline-divided rows.

## Rules

- **One honey primary action per screen** — `PrimaryActionButton` or the FAB.
  Those two pin the honey fill themselves; a bare `FilledButton` inherits the
  brand shape/height but takes the scheme's accent, not honey. Secondary =
  outlined plum (`SecondaryActionButton`); destructive =
  `SecondaryActionButton(destructive: true)`.
- **Honey is a fill, never a foreground on a light ground** — honey text or
  icons on cream measure 1.84:1. So `colorScheme.primary` is **plum** in light
  mode (the accent Material draws as a foreground: outlined/text-button
  labels, chevrons, selection tints) and honey only appears as a background
  paired with `BrandTokens.onHoney`, or as a highlight on a plum ground / map
  imagery. In dark mode plum is the ground, so `primary` is honey there
  (8.02:1 on plum 950) and the secondary button's label is cream (`#627`).
- **Selection state is the accent, not honey** — a selected view-toggle
  segment, a switched-on `Switch`, a selected chip and a focus ring all draw
  `primary`, so in light mode they are plum-filled with a white on-colour
  (9.62:1) rather than honey-filled. That is the point: honey marks the one
  action to take, so it can't also mark every "this one is selected".
- **One field-label pattern, app-wide** — every form field wears its label
  above the box via `LabeledField`; `InputDecoration.labelText` is not used on
  a form (`#629`). List screens' compact filter/sort bars and their
  hint-only search boxes are not form fields and keep their own treatment.
  A label above a field also means a submit button cannot share the field's
  row: aligned to the row's top it rides up level with the label, and any
  fixed nudge back down breaks at a larger OS text scale — put it underneath.
- **Never hardcode a hex or a radius in a screen.** Pull colour from
  `Theme.of(context).colorScheme` / `context.brand` / `BrandTokens`, and
  radii/heights from `BrandDimens`.
- **Strings stay in l10n** (`AppLocalizations`) — EN/PT. Restyling is visual;
  it never inlines copy.
- **Preserve accessibility:** keep the 44px tap-target floor, AA contrast (the
  `test/theming/app_theme_contrast_test.dart` gate), and existing widget `Key`s
  that tests and semantics rely on.
