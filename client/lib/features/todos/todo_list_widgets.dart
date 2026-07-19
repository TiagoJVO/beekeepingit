import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import 'todo_filters.dart';
import 'todo_priority.dart';
import 'todos_repository.dart';

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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<TodoStatusFilter>(
                  key: const Key('todo-filter-status-field'),
                  initialValue: status,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.todoFilterStatusLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: TodoStatusFilter.all,
                      child: Text(l10n.todoFilterStatusAll),
                    ),
                    DropdownMenuItem(
                      value: TodoStatusFilter.open,
                      child: Text(l10n.todoFilterStatusOpen),
                    ),
                    DropdownMenuItem(
                      value: TodoStatusFilter.overdue,
                      child: Text(l10n.todoFilterStatusOverdue),
                    ),
                    DropdownMenuItem(
                      value: TodoStatusFilter.done,
                      child: Text(l10n.todoFilterStatusDone),
                    ),
                  ],
                  onChanged: (v) => onStatusChanged(v ?? TodoStatusFilter.all),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  key: const Key('todo-filter-priority-field'),
                  initialValue: priority,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.todoFilterPriorityLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(l10n.todoFilterPriorityAll),
                    ),
                    for (final p in knownTodoPriorities)
                      DropdownMenuItem(
                        value: p,
                        child: Text(todoPriorityLabel(l10n, p) ?? p),
                      ),
                  ],
                  onChanged: onPriorityChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<TodoDueFilter>(
                  key: const Key('todo-filter-due-field'),
                  initialValue: due,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.todoFilterDueLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: TodoDueFilter.any,
                      child: Text(l10n.todoFilterDueAny),
                    ),
                    DropdownMenuItem(
                      value: TodoDueFilter.today,
                      child: Text(l10n.todoFilterDueToday),
                    ),
                    DropdownMenuItem(
                      value: TodoDueFilter.thisWeek,
                      child: Text(l10n.todoFilterDueThisWeek),
                    ),
                    DropdownMenuItem(
                      value: TodoDueFilter.thisMonth,
                      child: Text(l10n.todoFilterDueThisMonth),
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
                child: DropdownButtonFormField<TodoSortField>(
                  key: const Key('todo-sort-field-field'),
                  initialValue: sortField,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.todoSortFieldLabel,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: TodoSortField.dueDate,
                      child: Text(l10n.todoSortFieldDueDate),
                    ),
                    DropdownMenuItem(
                      value: TodoSortField.priority,
                      child: Text(l10n.todoSortFieldPriority),
                    ),
                    DropdownMenuItem(
                      value: TodoSortField.status,
                      child: Text(l10n.todoSortFieldStatus),
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
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.todosEmpty),
            ),
          );
        }
        if (vm.filtered.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.todosFilterNoResults),
            ),
          );
        }
        return ListView.separated(
          key: const Key('todo-list'),
          itemCount: vm.filtered.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
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
    final statusColor = todo.isDone
        ? theme.colorScheme.onSurfaceVariant
        : overdue
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;

    return ListTile(
      key: Key('todo-${todo.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      // Tapping a row opens the read-focused detail screen (#293), not the
      // edit form directly — mirrors _ActivityTile/journey list row's own
      // tap-to-detail convention (activity_list_widgets.dart,
      // journeys_list_screen.dart).
      onTap: () => context.go('/todos/${todo.id}'),
      // The leading icon is the ONLY status signal for an open, non-overdue
      // row (no visible badge — that's reserved for overdue/done, this
      // file's own doc comment) — its `semanticLabel` gives screen readers a
      // text alternative (WCAG 2.2 AA 1.1.1), never relying on the icon
      // shape/color alone.
      leading: Icon(
        todo.isDone
            ? Icons.check_circle
            : overdue
            ? Icons.warning_amber_outlined
            : Icons.radio_button_unchecked,
        color: statusColor,
        semanticLabel: l10n.todoStatusSemanticLabel(statusWord),
      ),
      title: Text(
        todo.title,
        style: todo.isDone
            ? TextStyle(
                decoration: TextDecoration.lineThrough,
                color: theme.colorScheme.onSurfaceVariant,
              )
            : null,
      ),
      subtitle: Row(
        children: [
          Flexible(
            child: Text(
              '$dueText · $priorityLabel',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      // Text + icon together (never color alone, WCAG 2.2 AA 1.4.1, #53 AC):
      // only rendered for an overdue row — done/open rows are already
      // distinguished by the leading icon + (for done) the strikethrough
      // title above.
      trailing: overdue ? _OverdueBadge(label: l10n.todoOverdueBadge) : null,
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
        borderRadius: BorderRadius.circular(12),
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
