import 'package:flutter/material.dart';

import 'tap_target.dart';

/// The shared searchable-picker row skeleton (#762, D-18) — the D-18
/// semantics + [kMinTapTarget] tap-target contract every "search the org's
/// locally-synced set and pick one/many" list already needed, extracted
/// after FOUR hand-rolled copies had accumulated: `todo_apiary_picker_field
/// .dart`'s and `todo_assignee_picker_field.dart`'s byte-identical single-
/// select `_TodoOptionTile`, `apiary_multi_select_field.dart`'s checkbox
/// `_ApiaryCheckTile`, and `new_activity_flow_screen.dart`'s navigating
/// `_ApiaryOptionTile` (the last landed as a deliberate copy — #634's own
/// doc comment named this exact extraction as follow-up work while parallel
/// changes owned the other three files).
///
/// [mode] is the FULL parameterization #762 asked for, not just the row's
/// outer chrome (`Semantics`/`Material`/`InkWell`/`ConstrainedBox`/
/// `Padding`/`ExcludeSemantics` — the part every one of the four copies
/// already agreed on byte-for-byte): it also picks the row's CONTENT —
/// trailing icon, font weight, and single- vs. two-line layout — because
/// that content was the same three shapes repeated, not something to leave
/// each call site re-deriving. Content is copied verbatim from the four
/// originals with ONE deliberate exception — the `fontFamily` pin — see
/// below.
///
///  - [OptionRowMode.singleSelect] — a radio-style trailing icon
///    (`radio_button_checked`/`_unchecked`), label weight w700 when
///    [selected] else w500. Used by both todo pickers, including their
///    leading "none"/"unassigned" clear row — that row is not a distinct
///    shape, just another single-select row whose label happens to mean
///    "clear the association", so it needs no dedicated flag here.
///  - [OptionRowMode.multiSelect] — a checkbox-style trailing icon
///    (`check_box`/`check_box_outline_blank`), constant w600 label weight,
///    and the extra `SizedBox(width: 12)` gap `apiary_multi_select_field
///    .dart` already had before its icon.
///  - [OptionRowMode.navigate] — no selection state at all (tapping IS the
///    choice): a constant w700 label, an optional [subtitle] second line,
///    and a trailing `chevron_right`.
///
/// [selected] is `bool?` rather than `bool` on purpose: passing `false` for
/// [OptionRowMode.navigate] would still set `Semantics.selected` (to
/// "not selected"), changing what a screen reader announces for a plain
/// navigating row versus today's `Semantics(button:, label:)`-only tile.
/// `null` omits the property entirely; only [singleSelect]/[multiSelect]
/// callers pass a real bool.
///
/// [cardColor]/[cardShape] exist only for the [navigate] row's own Material
/// surface (explicit color + shape + `Clip.antiAlias`, matching D-16's map-
/// chrome precedent for a filled/bordered card) — the other two modes stay
/// `MaterialType.transparency` inside their caller's own bordered list
/// container. Both are plain [Color]/[ShapeBorder] values a caller builds
/// with its own brand tokens; this file cannot import `theming/brand_*`
/// (see "Why `core/widgets/`" below), so it never constructs a
/// `RoundedRectangleBorder`/`BrandDimens` value itself.
///
/// **Why `core/widgets/` and not `features/apiaries/`.** This row never
/// mentions "apiary" — one of its four callers ([TodoAssigneePickerField])
/// picks an org member, not an apiary — so it belongs beside the other
/// app-wide, feature-agnostic tap-target primitives (`tap_target.dart`,
/// `field_action_button.dart`) rather than a feature folder. Every file in
/// this directory is layered strictly below `theming/`: it reads
/// `Theme.of(context)` for colors like every other widget here, but never
/// imports `brand_dimens.dart`/`brand_theme.dart`/`brand_widgets.dart`. A
/// caller that wants brand-specific chrome (the bordered list container
/// three of the four callers still build themselves, deliberately left
/// alone by #762 — see each call site) builds it with those tokens and
/// hands this row only plain [Color]/[ShapeBorder] values.
///
/// **Why the four `Text` calls don't pin `fontFamily`.** Every one of the
/// four originals set `fontFamily: AppTheme.bodyFontFamily` explicitly on
/// each `TextStyle`. This file cannot do the same — `AppTheme` lives in
/// `theming/`, and this directory must not import it (see above) — so
/// [OptionRowMode.singleSelect]/[OptionRowMode.multiSelect]/
/// [OptionRowMode.navigate]'s label and [subtitle] styles omit `fontFamily`
/// and rely on ambient resolution instead: `Material`'s `textStyle`
/// defaults to `Theme.of(context).textTheme.bodyMedium`, and `AppTheme`
/// deliberately leaves `bodyMedium` on Archivo (the app's body font). That
/// reliance is not an unstated gap: `test/core/widgets/option_row_test.dart`
/// asserts the RESOLVED `TextStyle.fontFamily` (via each row's own
/// `RenderParagraph`, not a value this widget declares) equals
/// `AppTheme.bodyFontFamily` for every mode. #628 (`9b553fe`) is exactly the
/// failure this guards against — a `theming/` change silently repointing a
/// widget onto the wrong font, caught there only because a test asserted
/// the resolved style rather than assuming it.
///
/// **What deliberately stays at each call site — do not "finish the job" by
/// moving it here.** The search field and its `filterApiariesByQuery` call,
/// the bordered `Container`/`ListView` the row sits inside, the empty/no-
/// results/loading/error branches (all four render a genuinely different
/// widget for these — a plain `Text`, an `EmptyState` with an icon, an
/// `EmptyState` without one, or no case at all), and
/// `ApiaryMultiSelectField`'s select-all/clear-all controls plus its
/// selected-count footer. These differ because the four screens are
/// different, not because nobody got round to unifying them — normalizing
/// them here would be a behaviour change, not a refactor.
enum OptionRowMode {
  /// A single-select row: tapping REPLACES the current selection. Radio-
  /// style trailing icon.
  singleSelect,

  /// A multi-select row: tapping TOGGLES membership in a set. Checkbox-
  /// style trailing icon.
  multiSelect,

  /// A plain navigating row: tapping is itself the whole action (e.g. "go
  /// to the form for this apiary"). No selection state, trailing chevron.
  navigate,
}

class OptionRow extends StatelessWidget {
  const OptionRow({
    required this.label,
    required this.mode,
    required this.onTap,
    this.subtitle,
    this.selected,
    this.cardColor,
    this.cardShape,
    super.key,
  });

  /// The row's own visible (and, via [Semantics.label], announced) text.
  final String label;

  /// An optional second line — only [OptionRowMode.navigate] renders it
  /// (`new_activity_flow_screen.dart`'s hive-count subtitle).
  final String? subtitle;

  final OptionRowMode mode;

  /// `null` omits `Semantics.selected` altogether (see this class's own doc
  /// comment) — pass a real bool for [OptionRowMode.singleSelect]/
  /// [OptionRowMode.multiSelect]; leave `null` for [OptionRowMode.navigate].
  final bool? selected;

  final VoidCallback onTap;

  /// [OptionRowMode.navigate]'s own Material surface color. Ignored by the
  /// other two modes (`MaterialType.transparency`).
  final Color? cardColor;

  /// [OptionRowMode.navigate]'s own Material shape (a caller-built
  /// `RoundedRectangleBorder`, typically with `BrandDimens.borderCard` +
  /// its card border color). Ignored by the other two modes.
  final ShapeBorder? cardShape;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = selected ?? false;

    final Widget content;
    switch (mode) {
      case OptionRowMode.singleSelect:
        content = Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  fontSize: 16,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isSelected
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ],
        );
      case OptionRowMode.multiSelect:
        content = Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              isSelected ? Icons.check_box : Icons.check_box_outline_blank,
              color: isSelected
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ],
        );
      case OptionRowMode.navigate:
        content = Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        );
    }

    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: kMinTapTarget),
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: content,
        ),
      ),
    );

    final material = mode == OptionRowMode.navigate
        ? Material(
            color: cardColor,
            shape: cardShape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(onTap: onTap, child: row),
          )
        : Material(
            type: MaterialType.transparency,
            child: InkWell(onTap: onTap, child: row),
          );

    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: material,
    );
  }
}
