# Melargil — Flutter design system (as-built)

> **Status: as-built.** This documents how the prototype's look-and-feel
> (`prototype.md`, the directional guideline) is implemented in the Flutter
> client. When building or restyling a screen, compose the tokens and widgets
> below instead of re-deriving paddings/radii/colours inline — that is what
> keeps existing and future screens visually consistent. `prototype.md` remains
> the directional source of truth for _look_; this is the _mechanism_.

## Where the system lives (`client/lib/theming/`)

| File                | What                                                                                                                                   |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `brand_tokens.dart` | Every brand **colour** hex (single source of truth). Includes the activity-type palette, notes-card and trailing-chevron tints.        |
| `brand_dimens.dart` | Every brand **radius / control height / spacing** value.                                                                               |
| `brand_theme.dart`  | `BrandTheme` `ThemeExtension` — look-and-feel roles Material's `ColorScheme` lacks (hero surface, eyebrow, notes, per-type accents). Read via `context.brand`. Brightness-aware. |
| `app_theme.dart`    | Builds `ThemeData` from the above: colour scheme **plus** component themes (cards, inputs, buttons, chips, nav, FAB) so default widgets already look right. |
| `brand_widgets.dart`| The shared building blocks screens compose (see below).                                                                                |

Field-action buttons live in `core/widgets/field_action_button.dart`
(`PrimaryActionButton` = honey 60px; `SecondaryActionButton` = outlined 56px,
`destructive:` for delete/logout). Tap-target floor: `core/widgets/tap_target.dart`.

## The scale (from the prototype)

- **Radii:** field `14`, button/card `16`, large card `18`, hero `20`, tile
  `12`, badge `8`, chips = pills. (`BrandDimens.radius*` / `border*`.)
- **Heights:** primary button `60`, secondary `56`, input `58`, search `52`,
  chip `44` (small `40`). Never below the 44px gloves-friendly floor.
- **Gutters:** list/content screens `16`, form screens `20`; scrollables pad
  `120` at the bottom to clear the FAB (`BrandDimens.scrollBottomInset`).

## Widgets (`brand_widgets.dart`) — compose these

- **`Eyebrow(text)`** — gold, uppercase, letter-spaced section/step label.
- **`SectionHeader(text)`** — Playfair 19 serif header between content blocks.
- **`LabeledField(label:, child:)`** — label _above_ the field (the prototype
  pattern), not a floating Material label. Wrap `TextFormField`/`DropdownButton`.
- **`HeroCard(child:)`** — the plum detail/settings header (radius 20, white
  foreground via `context.brand.onHeroSurface`).
- **`BrandCard(child:, onTap:)`** — white card on the 1px hairline; tappable
  ripple when `onTap` is set.
- **`BrandRowCard(title:, subtitle:, leading:, trailing:, onTap:)`** — the
  standard list row (leading tile · title/subtitle · trailing · chevron).
- **`LeadingIconTile(icon:, color:, tint:)`** — the rounded tinted icon square.
- **`NotesCard(text:)`** — the sand "sticky note" callout.
- **`EmptyState(message:, icon:)`** — centered empty/no-results message.
- **`BrandChip(label:, selected:, onTap:, accent:)`** — selectable pill filter.
- **`MenuListCard(rows: [MenuRow(...)])`** — grouped settings/menu card with
  hairline-divided rows.

## Rules

- **One honey primary action per screen** — `PrimaryActionButton` (or a
  `FilledButton`, which inherits the honey shape). Secondary = outlined plum;
  destructive = `SecondaryActionButton(destructive: true)`.
- **Never hardcode a hex or a radius in a screen.** Pull colour from
  `Theme.of(context).colorScheme` / `context.brand` / `BrandTokens`, and
  radii/heights from `BrandDimens`.
- **Strings stay in l10n** (`AppLocalizations`) — EN/PT. Restyling is visual;
  it never inlines copy.
- **Preserve accessibility:** keep the 44px tap-target floor, AA contrast (the
  `test/theming/app_theme_contrast_test.dart` gate), and existing widget `Key`s
  that tests and semantics rely on.
