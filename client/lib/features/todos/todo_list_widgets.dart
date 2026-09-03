import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import 'todo_filters.dart';
import 'todo_priority.dart';
import 'todos_repository.dart';

/// Below this available width the status + priority filters stack onto their
/// own rows instead of sharing one (#626). Two-up at a 375 CSS px phone
/// viewport leaves each field roughly 155 px, which is not enough for the
/// longer Portuguese values — `Todas as prioridades` then wrapped and the
/// dropdown button clipped the second line away, so the filter read `Todas
/// as`: a dangling article with no ellipsis to signal truncation
/// (NFR-I18N-1, FR-UX-1). English (`All priorities`) happens to fit, which is
/// why the cramped row survived review. Above this width both fields have
/// room, so the bar stays compact — it sits on the app's home screen (D-29)
/// where vertical space is scarce.
const double _kStackFiltersBelowWidth = 480;

/// One option of a filter dropdown: the value it selects and the localized
/// label shown for it.
typedef _FilterOption<T> = ({T value, String label});

/// One filter dropdown of [TodoFilterBar].
///
/// Beyond deduplicating four near-identical fields this centralizes the two
/// things every filter here needs and `DropdownButtonFormField` does not do
/// on its own: `isExpanded`, so the button fills its slot, and a
/// `selectedItemBuilder` that caps the SHOWN selection at one ellipsized
/// line. Without the latter a value too long for its slot soft-wraps and the
/// button's fixed height clips the second line, truncating mid-phrase with
/// no ellipsis (#626). The menu's own items deliberately keep their full,
/// wrappable text — the dropdown is where the user reads the whole label.
Widget _filterDropdown<T>({
  required Key fieldKey,
  required String label,
  required T value,
  required List<_FilterOption<T>> options,
  required ValueChanged<T?> onChanged,
}) {
  return DropdownButtonFormField<T>(
    key: fieldKey,
    initialValue: value,
    isExpanded: true,
    decoration: InputDecoration(labelText: label, isDense: true),
    selectedItemBuilder: (context) => [
      for (final option in options)
        Text(
          option.label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
        ),
    ],
    items: [
      for (final option in options)
        DropdownMenuItem<T>(value: option.value, child: Text(option.label)),
    ],
    onChanged: onChanged,
  );
}

/// The status/priority/due-date filter bar + sort controls for the main
/// Todos tab (#53, FR-TD-1) — mirrors activity_list_widgets.dart's own
/// `ActivityFilterBar` (same combinable-filters UX), extended with a third
/// filter (status) and a sort field + direction toggle, since Todos is the
/// first list with a user-facing sort control (no repo precedent yet).
/// Purely presentational: the caller (todos_list_screen.dart) owns the
/// actual filter/sort STATE (todo_filters.dart's providers) and passes the
/// current selection + change callbacks in.
///
/// Gloves-friendly (FR-UX-1/FR-AX-1): every interactive control here meets
/// the app's 44x44 [kMinTapTarget] minimum, matching `ActivityFilterBar`'s
/// own.
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BrandDimens.gutter,
        8,
        BrandDimens.gutter,
        4,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final statusField = _filterDropdown<TodoStatusFilter>(
            fieldKey: const Key('todo-filter-status-field'),
            label: l10n.todoFilterStatusLabel,
            value: status,
            options: [
              (value: TodoStatusFilter.all, label: l10n.todoFilterStatusAll),
              (value: TodoStatusFilter.open, label: l10n.todoFilterStatusOpen),
              (
                value: TodoStatusFilter.overdue,
                label: l10n.todoFilterStatusOverdue,
              ),
              (value: TodoStatusFilter.done, label: l10n.todoFilterStatusDone),
            ],
            onChanged: (v) => onStatusChanged(v ?? TodoStatusFilter.all),
          );
          final priorityField = _filterDropdown<String?>(
            fieldKey: const Key('todo-filter-priority-field'),
            label: l10n.todoFilterPriorityLabel,
            value: priority,
            options: [
              (value: null, label: l10n.todoFilterPriorityAll),
              for (final p in knownTodoPriorities)
                (value: p, label: todoPriorityLabel(l10n, p) ?? p),
            ],
            onChanged: onPriorityChanged,
          );
          // Narrow (a phone in portrait): one filter per row, so a long
          // localized value gets the full width rather than half of it
          // (#626). Wide: both on one row, keeping the bar compact.
          final stacked = constraints.maxWidth < _kStackFiltersBelowWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (stacked) ...[
                statusField,
                const SizedBox(height: 8),
                priorityField,
              ] else
                Row(
                  children: [
                    Expanded(child: statusField),
                    const SizedBox(width: 8),
                    Expanded(child: priorityField),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _filterDropdown<TodoDueFilter>(
                      fieldKey: const Key('todo-filter-due-field'),
                      label: l10n.todoFilterDueLabel,
                      value: due,
                      options: [
                        (
                          value: TodoDueFilter.any,
                          label: l10n.todoFilterDueAny,
                        ),
                        (
                          value: TodoDueFilter.today,
                          label: l10n.todoFilterDueToday,
                        ),
                        (
                          value: TodoDueFilter.thisWeek,
                          label: l10n.todoFilterDueThisWeek,
                        ),
                        (
                          value: TodoDueFilter.thisMonth,
                          label: l10n.todoFilterDueThisMonth,
                        ),
                      ],
                      onChanged: (v) => onDueChanged(v ?? TodoDueFilter.any),
                    ),
                  ),
                  if (_hasFilter) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      key: const Key('todo-filter-clear-button'),
                      tooltip: l10n.todoFilterClearAction,
                      constraints: const BoxConstraints(
                        minWidth: kMinTapTarget,
                        minHeight: kMinTapTarget,
                      ),
                      icon: const Icon(Icons.clear),
                      onPressed: onClearFilters,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _filterDropdown<TodoSortField>(
                      fieldKey: const Key('todo-sort-field-field'),
                      label: l10n.todoSortFieldLabel,
                      value: sortField,
                      options: [
                        (
                          value: TodoSortField.dueDate,
                          label: l10n.todoSortFieldDueDate,
                        ),
                        (
                          value: TodoSortField.priority,
                          label: l10n.todoSortFieldPriority,
                        ),
                        (
                          value: TodoSortField.status,
                          label: l10n.todoSortFieldStatus,
                        ),
                      ],
                      onChanged: (v) =>
                          onSortFieldChanged(v ?? TodoSortField.dueDate),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    key: const Key('todo-sort-direction-button'),
                    tooltip: sortDirection == SortDirection.ascending
                        ? l10n.todoSortDirectionAscendingLabel
                        : l10n.todoSortDirectionDescendingLabel,
                    constraints: const BoxConstraints(
                      minWidth: kMinTapTarget,
                      minHeight: kMinTapTarget,
                    ),
                    icon: Icon(
                      sortDirection == SortDirection.ascending
                          ? Icons.arrow_upward
                          : Icons.arrow_downward,
                    ),
                    onPressed: onSortDirectionToggle,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// The main Todos tab's body (#53): loading/error states, the two distinct
/// empty states (mirrors activity_list_widgets.dart's `ActivityListView` own
/// `hasAnyActivities` vs. "filters matched nothing" split — here "zero
/// todos at all" vs. "the current filters matched none", #53 AC), and the
/// list itself, one row per todo distinguishing open/overdue/done (#53 AC).
class TodoListView extends StatelessWidget {
  const TodoListView({required this.viewModel, super.key});

  final AsyncValue<TodosViewModel> viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return viewModel.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.todosError('$err')),
        ),
      ),
      data: (vm) {
        if (!vm.hasAnyTodos) {
          return EmptyState(
            message: l10n.todosEmpty,
            icon: Icons.checklist_outlined,
          );
        }
        if (vm.filtered.isEmpty) {
          return EmptyState(message: l10n.todosFilterNoResults);
        }
        return ListView.separated(
          key: const Key('todo-list'),
          padding: const EdgeInsets.fromLTRB(
            BrandDimens.gutter,
            4,
            BrandDimens.gutter,
            BrandDimens.scrollBottomInset,
          ),
          itemCount: vm.filtered.length,
          separatorBuilder: (_, _) =>
              const SizedBox(height: BrandDimens.gapCard),
          itemBuilder: (context, i) =>
              _TodoTile(todo: vm.filtered[i], today: vm.today),
        );
      },
    );
  }
}

class _TodoTile extends StatelessWidget {
  const _TodoTile({required this.todo, required this.today});

  final Todo todo;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final overdue = isOverdue(todo, today);
    final priorityLabel =
        todoPriorityLabel(l10n, todo.priority) ?? todo.priority;
    final dueText = todo.dueDate == null
        ? l10n.todoDueDateUnset
        : LocaleFormatting.of(context).date(DateTime.parse(todo.dueDate!));
    final statusWord = todo.isDone
        ? l10n.todoFilterStatusDone
        : overdue
        ? l10n.todoFilterStatusOverdue
        : l10n.todoFilterStatusOpen;
    final brand = context.brand;
    // The leading tile's brand accent carries the same three-way status
    // split the icon does: muted/generic for done, the terracotta treatment
    // accent for overdue (an attention state), the gold cresta accent for a
    // plain open row. Colours come from `context.brand`, never a raw hex.
    final statusVisual = todo.isDone
        ? brand.generic
        : overdue
        ? brand.treatment
        : brand.cresta;
    final statusIcon = todo.isDone
        ? Icons.check_circle
        : overdue
        ? Icons.warning_amber_outlined
        : Icons.radio_button_unchecked;

    // Composed from [BrandCard] in [BrandRowCard]'s exact shape (leading tile
    // · title/subtitle · trailing · chevron) rather than [BrandRowCard]
    // itself, because a done todo's title must keep its strikethrough (#53
    // AC: "distinguishes ... completed" — a non-colour-only signal, WCAG 2.2
    // AA 1.4.1) and BrandRowCard takes a plain title String with no room for
    // a per-row text decoration.
    return BrandCard(
      key: Key('todo-${todo.id}'),
      semanticLabel: '${todo.title}. $dueText · $priorityLabel',
      // Tapping a row opens the read-focused detail screen (#293), not the
      // edit form directly — mirrors _ActivityTile/journey list row's own
      // tap-to-detail convention (activity_list_widgets.dart,
      // journeys_list_screen.dart).
      onTap: () => context.go('/todos/${todo.id}'),
      child: Row(
        children: [
          // The leading icon is the ONLY status signal for an open,
          // non-overdue row (no visible badge — that's reserved for
          // overdue/done, this file's own doc comment) — the wrapping
          // `Semantics` label gives screen readers a text alternative (WCAG
          // 2.2 AA 1.1.1), never relying on the icon shape/colour alone.
          Semantics(
            label: l10n.todoStatusSemanticLabel(statusWord),
            child: LeadingIconTile(
              icon: statusIcon,
              color: statusVisual.color,
              tint: statusVisual.tint,
              size: BrandDimens.sizeLeadingTileSmall,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  todo.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                    color: todo.isDone
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurface,
                    decoration: todo.isDone ? TextDecoration.lineThrough : null,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$dueText · $priorityLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontSize: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          // Text + icon together (never color alone, WCAG 2.2 AA 1.4.1, #53
          // AC): only rendered for an overdue row — done/open rows are
          // already distinguished by the leading tile + (for done) the
          // strikethrough title above.
          if (overdue) ...[
            const SizedBox(width: 10),
            _OverdueBadge(label: l10n.todoOverdueBadge),
          ],
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(Icons.chevron_right, color: brand.trailingIcon),
          ),
        ],
      ),
    );
  }
}

/// The overdue badge (#53 AC: "distinguishes ... overdue") — text + a
/// warning icon together, never color alone (WCAG 2.2 AA 1.4.1), styled with
/// the theme's error container so it reads as a genuine attention state,
/// unlike the neutral priority/status pills elsewhere in this app (e.g.
/// journey_list_screen.dart's `_StatusBadge`/`_ProgressBadge`, which are
/// deliberately muted since "closed"/"progress" aren't alarm states).
class _OverdueBadge extends StatelessWidget {
  const _OverdueBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('todo-overdue-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(BrandDimens.radiusBadge),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: 14,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }
}
