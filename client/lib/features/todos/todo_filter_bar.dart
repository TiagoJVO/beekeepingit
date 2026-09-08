import 'package:flutter/material.dart';

import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_widgets.dart';
import 'todo_filters.dart';
import 'todo_priority.dart';

/// The status/priority/due-date filter bar + sort controls for the main
/// Todos tab (#53, FR-TD-1; compacted for #635, FR-UX-1/FR-AX-1) — mirrors
/// activity_list_widgets.dart's own `ActivityFilterBar` (same combinable-
/// filters UX), extended with a third filter (status) and a sort field +
/// direction toggle, since Todos is the first list with a user-facing sort
/// control (no repo precedent yet). Purely presentational: the caller
/// (todos_list_screen.dart) owns the actual filter/sort STATE
/// (todo_filters.dart's providers) and passes the current selection + change
/// callbacks in.
///
/// **#635 redesign, replacing the four `DropdownButtonFormField`s this bar
/// used to render (todo_list_widgets.dart's retired `_filterDropdown`,
/// #626):** at a 375 CSS px phone viewport those four full-width fields, each
/// with its own label, stacked to roughly 268px — over a third of a small
/// phone's viewport spent on chrome above a list the field workflow needs to
/// scan quickly. The four are now three compact controls:
///
///  * **Estado** ([status]) is the one dimension worth a genuine multi-option
///    chip row (short values, the dominant filter this tab already
///    defaults non-trivially, #427/D-29) — a horizontally-scrollable,
///    single-select row of [BrandChip]s, turning "open dropdown, read menu,
///    tap option" into one tap. #661 added a fifth chip to it ("needs
///    attention", the overdue ∪ due-soon preset Home's "view all" link
///    opens); the row already scrolls horizontally, so it absorbs the extra
///    option without a layout change.
///  * **Prioridade** ([priority]) and **Prazo** ([due]) are each a single
///    *menu chip* that opens a [showModalBottomSheet] picker (this repo's
///    established sheet convention — `apiary_detail_screen.dart`,
///    `apiary_map_info_sheet.dart`, `journey_picker.dart`,
///    `journey_quick_create_sheet.dart` — over a dropdown/menu-anchor, since
///    a sheet puts large, gloves-friendly targets in one-handed thumb reach,
///    D-18). The chip reads its bare category label when cleared and
///    `category: value` (`todoFilterChipLabel`) once a non-default value is
///    picked, so the chip itself carries the selection with no separate
///    label needed.
///  * **Ordenar por** ([sortField]) is the same menu-chip shape, always
///    showing `category: value` (there is no "no sort" state) — its own
///    direction toggle [IconButton] is unchanged, since flipping direction
///    needs to stay a single tap, not a second sheet round trip.
///
/// Gloves-friendly (FR-UX-1/FR-AX-1): every interactive control here meets
/// the app's 44x44 [kMinTapTarget] minimum, matching `ActivityFilterBar`'s
/// own — [BrandChip]'s own default height already sits exactly at that
/// floor, so no control here overrides it.
class TodoFilterBar extends StatelessWidget {
  const TodoFilterBar({
    required this.status,
    required this.priority,
    required this.due,
    required this.sortField,
    required this.sortDirection,
    required this.onStatusChanged,
    required this.onPriorityChanged,
    required this.onDueChanged,
    required this.onSortFieldChanged,
    required this.onSortDirectionToggle,
    required this.onClearFilters,
    super.key,
  });

  final TodoStatusFilter status;
  final String? priority;
  final TodoDueFilter due;
  final TodoSortField sortField;
  final SortDirection sortDirection;
  final ValueChanged<TodoStatusFilter> onStatusChanged;
  final ValueChanged<String?> onPriorityChanged;
  final ValueChanged<TodoDueFilter> onDueChanged;
  final ValueChanged<TodoSortField> onSortFieldChanged;

  /// Flips the current [sortDirection] — a plain toggle (not a
  /// [ValueChanged]) since there are only ever two states, mirroring
  /// apiaries_list_screen.dart's own list/map view toggle button convention.
  final VoidCallback onSortDirectionToggle;

  /// Resets status/priority/due back to their defaults — deliberately never
  /// touches [sortField]/[sortDirection] (#53's own doc: sort is a display
  /// preference, not a filter, so "clear filters" leaves it alone, mirroring
  /// activityFilterClearAction's own "type + date range only" scope).
  final VoidCallback onClearFilters;

  bool get _hasFilter =>
      status != TodoStatusFilter.all ||
      priority != null ||
      due != TodoDueFilter.any;

  String _statusChipLabel(AppLocalizations l10n, TodoStatusFilter value) =>
      switch (value) {
        TodoStatusFilter.all => l10n.todoFilterStatusAll,
        TodoStatusFilter.open => l10n.todoFilterStatusOpen,
        TodoStatusFilter.needsAttention => l10n.todoFilterStatusNeedsAttention,
        TodoStatusFilter.overdue => l10n.todoFilterStatusOverdue,
        TodoStatusFilter.done => l10n.todoFilterStatusDone,
      };

  String _dueOptionLabel(AppLocalizations l10n, TodoDueFilter value) =>
      switch (value) {
        TodoDueFilter.any => l10n.todoFilterDueAny,
        TodoDueFilter.today => l10n.todoFilterDueToday,
        TodoDueFilter.thisWeek => l10n.todoFilterDueThisWeek,
        TodoDueFilter.thisMonth => l10n.todoFilterDueThisMonth,
      };

  String _sortFieldOptionLabel(AppLocalizations l10n, TodoSortField value) =>
      switch (value) {
        TodoSortField.dueDate => l10n.todoSortFieldDueDate,
        TodoSortField.priority => l10n.todoSortFieldPriority,
        TodoSortField.status => l10n.todoSortFieldStatus,
      };

  Future<void> _pickPriority(BuildContext context) async {
    final result = await showModalBottomSheet<(String?,)>(
      context: context,
      // Not scroll-controlled sheets cap their height to a fraction of the
      // available space (9/16), which is tighter than this option list's
      // own natural height — `isScrollControlled: true` lets the sheet size
      // to its content instead (mirrors journey_picker.dart's own sheet,
      // whose content is taller still).
      isScrollControlled: true,
      builder: (_) => _PriorityFilterSheet(current: priority),
    );
    if (!context.mounted || result == null) return;
    onPriorityChanged(result.$1);
  }

  Future<void> _pickDue(BuildContext context) async {
    final result = await showModalBottomSheet<TodoDueFilter>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _DueFilterSheet(current: due),
    );
    if (!context.mounted || result == null) return;
    onDueChanged(result);
  }

  Future<void> _pickSortField(BuildContext context) async {
    final result = await showModalBottomSheet<TodoSortField>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SortFieldSheet(current: sortField),
    );
    if (!context.mounted || result == null) return;
    onSortFieldChanged(result);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final priorityValueLabel = priority == null
        ? null
        : (todoPriorityLabel(l10n, priority!) ?? priority);
    final priorityChipLabel = priorityValueLabel == null
        ? l10n.todoFilterPriorityLabel
        : l10n.todoFilterChipLabel(
            l10n.todoFilterPriorityLabel,
            priorityValueLabel,
          );
    final dueChipLabel = due == TodoDueFilter.any
        ? l10n.todoFilterDueLabel
        : l10n.todoFilterChipLabel(
            l10n.todoFilterDueLabel,
            _dueOptionLabel(l10n, due),
          );
    final sortFieldChipLabel = l10n.todoFilterChipLabel(
      l10n.todoSortFieldLabel,
      _sortFieldOptionLabel(l10n, sortField),
    );
    final directionLabel = sortDirection == SortDirection.ascending
        ? l10n.todoSortDirectionAscendingLabel
        : l10n.todoSortDirectionDescendingLabel;

    return Padding(
      key: const Key('todo-filter-bar'),
      padding: const EdgeInsets.fromLTRB(
        BrandDimens.gutter,
        8,
        BrandDimens.gutter,
        4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Row A: the one genuine multi-option chip — status is the
          // dominant, short-valued filter, so it gets a dedicated
          // horizontally-scrollable row rather than sharing space with a
          // menu chip (#635).
          //
          // `SingleChildScrollView` + `Row`, NOT a horizontal `ListView`: a
          // horizontal `ListView` inside a `Column` needs a bounded
          // cross-axis (height) constraint, which would force a fixed
          // `SizedBox` here and clip a [BrandChip] at larger text scales.
          // `SingleChildScrollView` lets the row size itself to its tallest
          // child instead.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final value in TodoStatusFilter.values) ...[
                  if (value != TodoStatusFilter.values.first)
                    const SizedBox(width: 8),
                  BrandChip(
                    key: Key('todo-filter-status-chip-${value.name}'),
                    label: _statusChipLabel(l10n, value),
                    selected: status == value,
                    onTap: () => onStatusChanged(value),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Row B: the priority/due/sort-field menu chips share a scrollable
          // row, with the sort-direction toggle and (when a filter is
          // active) the clear button pinned outside it so they never scroll
          // out of reach.
          Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      BrandChip(
                        key: const Key('todo-filter-priority-chip'),
                        label: priorityChipLabel,
                        selected: priority != null,
                        onTap: () => _pickPriority(context),
                      ),
                      const SizedBox(width: 8),
                      BrandChip(
                        key: const Key('todo-filter-due-chip'),
                        label: dueChipLabel,
                        selected: due != TodoDueFilter.any,
                        onTap: () => _pickDue(context),
                      ),
                      const SizedBox(width: 8),
                      BrandChip(
                        key: const Key('todo-sort-field-chip'),
                        label: sortFieldChipLabel,
                        // Sort always has a value (no "cleared" state), so
                        // this chip is always drawn in its filled/selected
                        // form — mirrors the priority/due chips' own "value
                        // selected" look rather than adding a third visual
                        // state.
                        selected: true,
                        onTap: () => _pickSortField(context),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _FilterIconAction(
                itemKey: const Key('todo-sort-direction-button'),
                icon: sortDirection == SortDirection.ascending
                    ? Icons.arrow_upward
                    : Icons.arrow_downward,
                tooltip: directionLabel,
                semanticsLabel: l10n.todoSortDirectionAction(directionLabel),
                onTap: onSortDirectionToggle,
              ),
              if (_hasFilter) ...[
                const SizedBox(width: 4),
                _FilterIconAction(
                  itemKey: const Key('todo-filter-clear-button'),
                  icon: Icons.clear,
                  tooltip: l10n.todoFilterClearAction,
                  semanticsLabel: l10n.todoFilterClearAction,
                  onTap: onClearFilters,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// The sort-direction/clear icon buttons' own control (#635, FR-AX-1, D-18) —
/// deliberately NOT a Material [IconButton]: that widget attaches its OWN
/// semantics node (from its internal [Tooltip]) directly to itself, so an
/// ANCESTOR `Semantics(label: ...)` wrapped around an [IconButton] is never
/// reached by a query that starts at the button's own key — `Tooltip`
/// populates that node's `tooltip` property, not its `label`, which is the
/// actual AC-2 defect this control fixes. Mirrors
/// `apiary_map_info_sheet.dart`'s own `MapCircleControl`/
/// `apiaries_list_screen.dart`'s own `_ToggleSegment`: a bare [Tooltip] +
/// [InkWell] has no such built-in semantics node of its own, so the
/// ancestor [Semantics] here is the ONLY one in the subtree and a query by
/// key correctly finds its `label`.
class _FilterIconAction extends StatelessWidget {
  const _FilterIconAction({
    required this.itemKey,
    required this.icon,
    required this.tooltip,
    required this.semanticsLabel,
    required this.onTap,
  });

  /// Key on the tappable [InkWell] — the widget a test taps and measures.
  final Key itemKey;
  final IconData icon;
  final String tooltip;
  final String semanticsLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticsLabel,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          key: itemKey,
          borderRadius: BorderRadius.circular(BrandDimens.radiusTile),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(
              minWidth: kMinTapTarget,
              minHeight: kMinTapTarget,
            ),
            alignment: Alignment.center,
            child: Icon(icon),
          ),
        ),
      ),
    );
  }
}

/// The priority filter's bottom-sheet picker (#635) — a plain option list
/// (mirrors `apiary_detail_screen.dart`'s own `_AddCounterSheet`), returning
/// a ONE-TUPLE `(String?,)` rather than a bare `String?`: the "All
/// priorities" option's own value is `null`, which would otherwise be
/// indistinguishable from the sheet being dismissed without a choice (no
/// tuple at all) — and those two outcomes must NOT both clear the filter.
class _PriorityFilterSheet extends StatelessWidget {
  const _PriorityFilterSheet({required this.current});

  final String? current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final options = <(String? value, String label)>[
      (null, l10n.todoFilterPriorityAll),
      for (final p in knownTodoPriorities) (p, todoPriorityLabel(l10n, p) ?? p),
    ];
    return SafeArea(
      child: Padding(
        key: const Key('todo-filter-priority-sheet'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              l10n.todoFilterPriorityLabel,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            ),
            for (final option in options)
              ListTile(
                key: Key('todo-filter-priority-option-${option.$1 ?? 'all'}'),
                title: Text(
                  option.$2,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: option.$1 == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop((option.$1,)),
              ),
          ],
        ),
      ),
    );
  }
}

/// The due-date filter's bottom-sheet picker (#635) — same option-list shape
/// as [_PriorityFilterSheet]; no tuple wrapper needed since [TodoDueFilter]
/// is never itself null.
class _DueFilterSheet extends StatelessWidget {
  const _DueFilterSheet({required this.current});

  final TodoDueFilter current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String label(TodoDueFilter value) => switch (value) {
      TodoDueFilter.any => l10n.todoFilterDueAny,
      TodoDueFilter.today => l10n.todoFilterDueToday,
      TodoDueFilter.thisWeek => l10n.todoFilterDueThisWeek,
      TodoDueFilter.thisMonth => l10n.todoFilterDueThisMonth,
    };
    return SafeArea(
      child: Padding(
        key: const Key('todo-filter-due-sheet'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              l10n.todoFilterDueLabel,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            ),
            for (final value in TodoDueFilter.values)
              ListTile(
                key: Key('todo-filter-due-option-${value.name}'),
                title: Text(
                  label(value),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: value == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(value),
              ),
          ],
        ),
      ),
    );
  }
}

/// The sort-field bottom-sheet picker (#635) — same option-list shape as
/// [_PriorityFilterSheet]; no tuple wrapper needed since [TodoSortField] is
/// never itself null.
class _SortFieldSheet extends StatelessWidget {
  const _SortFieldSheet({required this.current});

  final TodoSortField current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    String label(TodoSortField value) => switch (value) {
      TodoSortField.dueDate => l10n.todoSortFieldDueDate,
      TodoSortField.priority => l10n.todoSortFieldPriority,
      TodoSortField.status => l10n.todoSortFieldStatus,
    };
    return SafeArea(
      child: Padding(
        key: const Key('todo-sort-field-sheet'),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(
              l10n.todoSortFieldLabel,
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            ),
            for (final value in TodoSortField.values)
              ListTile(
                key: Key('todo-sort-field-option-${value.name}'),
                title: Text(
                  label(value),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: value == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(value),
              ),
          ],
        ),
      ),
    );
  }
}
