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
  `136` at the bottom (`BrandDimens.scrollBottomInset`) to clear the FAB **and
  the confirmation toast** — a toast covering the card it just confirmed a save
  to is `#631`. That inset is for screens a FAB actually floats over — a tab
  root, or a pushed screen with its own FAB (e.g. `todo_detail_screen.dart`). A
  full-screen **form** is a pushed route with no FAB at all (the shell hides
  its own on any pushed route), and its pinned action bar sits outside the
  scroll view (`#341`/`#357`) — so it pads a plain `8` at the bottom and lets
  the bar do the clearing. Where the inset does apply, use the constant: four
  detail screens carrying their own smaller `96` is how `#631` got in.
- **Toasts:** nothing positions them — every `showSnackBar` call site hands the
  bar to `ScaffoldMessenger` and the enclosing `Scaffold` places it, at the top
  of its bottom chrome. The shell puts a `BrandDimens.gapToastNav` gutter inside
  its `bottomNavigationBar` slot so that anchor lands clear of the navigation
  bar instead of on its top edge (`#631`). Do **not** reach for
  `SnackBarBehavior.floating` to get the same gap: with a FAB on screen Flutter
  anchors a floating bar above the _FAB_, which is 194px up into the content.

  That gutter is **permanent, not toast-only** — it has to be, because the
  `Scaffold` computes its bottom-chrome height once, not per toast. It costs
  14px of body height on every tab. On a screen whose content sits on the
  scaffold background the band is the same colour as the content above it and
  is invisible; on a **full-bleed** screen it is not. `apiary_map_screen.dart`
  fills the tab body with a `Stack`, so the map ends 14px above the plum
  navigation bar with a cream strip between them, permanently. That is an
  accepted trade (`#631`): the toast is the app's only "your save worked"
  signal, and separating it from the navigation bar was judged worth a thin
  band on one tab. Weigh it before adding another full-bleed tab — and do not
  "fix" it by painting the gutter the navigation bar's colour, which restores
  exactly the two-dark-bars-read-as-one-block symptom `#631` set out to remove.

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
- **Content starts at the top, not the middle** — a screen whose body is a
  scrollable column wraps it in `Align(alignment: Alignment.topCenter, ...)`
  around the usual `ConstrainedBox(maxWidth: 480)`, never a plain `Center`
  (`#630`, `#769`). `Center` splits the leftover height into equal bands, so a
  screen shorter than its viewport starts mid-page with dead space under the
  header. Two deliberate exceptions: a `loading`/`error` branch keeps its own
  `Center` — a lone spinner or message does belong in the middle, which is why
  the `.when` sits outside the alignment wrapper rather than around it — and a
  short informational holding page with nothing to scroll
  (`organization_waiting_screen.dart`) stays centred on purpose. A body that is
  a `Column(mainAxisSize.max)` around an `Expanded` — the pinned-action form
  screens — already fills the height, so its wrapper is inert either way.
- **Never hardcode a hex or a radius in a screen.** Pull colour from
  `Theme.of(context).colorScheme` / `context.brand` / `BrandTokens`, and
  radii/heights from `BrandDimens`.
- **Strings stay in l10n** (`AppLocalizations`) — EN/PT. Restyling is visual;
  it never inlines copy.
- **Preserve accessibility:** keep the 44px tap-target floor, AA contrast (the
  `test/theming/app_theme_contrast_test.dart` gate), and existing widget `Key`s
  that tests and semantics rely on.
