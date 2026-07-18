import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'todo_priority.dart';
import 'todos_repository.dart';

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// The three-way lifecycle bucket a todo falls into (#53 AC: "distinguishes
/// open, completed, and overdue todos"). [open] deliberately EXCLUDES an
/// overdue todo — [overdue] is its own bucket — so the three states read as
/// mutually exclusive both in the status filter dropdown and in `sortTodos`'
/// status ordering, rather than "open" silently meaning "not done" (which
/// would blur into overdue).
enum TodoStatusFilter { all, open, overdue, done }

/// A due-date filter preset (#53 AC: "filterable by due date"). Presets
/// (not a raw date-range picker, a judgment call documented in the PR
/// description) since the issue's own hint frames due-date browsing as
/// "overdue" (its own separate [TodoStatusFilter] bucket, not duplicated
/// here) and "due in the next week" — the AI examples FR-AI-1 will build on
/// later (EPIC-08).
enum TodoDueFilter { any, today, thisWeek, thisMonth }

/// A sortable field (#53 AC: "sortable by due date, priority, and status").
enum TodoSortField { dueDate, priority, status }

enum SortDirection { ascending, descending }

/// True when [todo] is open (not done) and its due date has already passed
/// [today] — the calendar date only, never time-of-day (matches [Todo.
/// dueDate]'s own plain `YYYY-MM-DD` shape, no time component to compare). A
/// todo due exactly [today] is NOT overdue; a done todo is never overdue
/// regardless of its due date; a todo with no due date can never be overdue.
bool isOverdue(Todo todo, DateTime today) {
  if (todo.isDone) return false;
  if (todo.dueDate == null) return false;
  final due = _dateOnly(DateTime.parse(todo.dueDate!));
  return due.isBefore(_dateOnly(today));
}

/// Keeps only todos in [status]'s bucket relative to [today] (#53 AC:
/// "filterable by status (open, completed, overdue)"), or every todo when
/// [status] is [TodoStatusFilter.all] (the filter's cleared/default state).
List<Todo> filterTodosByStatus(
  List<Todo> todos,
  TodoStatusFilter status,
  DateTime today,
) {
  return switch (status) {
    TodoStatusFilter.all => todos,
    TodoStatusFilter.open =>
      todos.where((t) => !t.isDone && !isOverdue(t, today)).toList(),
    TodoStatusFilter.overdue =>
      todos.where((t) => isOverdue(t, today)).toList(),
    TodoStatusFilter.done => todos.where((t) => t.isDone).toList(),
  };
}

/// Keeps only [priority]-matching todos, or every todo when [priority] is
/// null (the filter's cleared/default "all priorities" state) — mirrors
/// activity_filters.dart's `filterActivitiesByType` empty-selection
/// passthrough.
List<Todo> filterTodosByPriority(List<Todo> todos, String? priority) {
  if (priority == null) return todos;
  return todos.where((t) => t.priority == priority).toList();
}

DateTime _startOfWeek(DateTime today) {
  final day = _dateOnly(today);
  // DateTime.weekday: Monday == 1 .. Sunday == 7.
  return day.subtract(Duration(days: day.weekday - 1));
}

DateTime _endOfWeek(DateTime today) =>
    _startOfWeek(today).add(const Duration(days: 6));

DateTime _startOfMonth(DateTime today) => DateTime(today.year, today.month, 1);

DateTime _endOfMonth(DateTime today) =>
    // Day 0 of next month == the last day of this month.
    DateTime(today.year, today.month + 1, 0);

/// Keeps only todos whose due date falls within [due]'s window relative to
/// [today] (#53 AC: "filterable by due date"), or every todo when [due] is
/// [TodoDueFilter.any] (the filter's cleared/default state). A todo with no
/// due date never matches any preset but [TodoDueFilter.any]. "This
/// week"/"this month" are calendar boundaries (Monday-Sunday / calendar
/// month), not a rolling N-day window — so a todo already overdue earlier
/// in the current week/month still matches (combinable with
/// [TodoStatusFilter.overdue] via [filterTodos] for "overdue, due this
/// week").
List<Todo> filterTodosByDue(
  List<Todo> todos,
  TodoDueFilter due,
  DateTime today,
) {
  if (due == TodoDueFilter.any) return todos;
  return todos.where((t) {
    if (t.dueDate == null) return false;
    final d = _dateOnly(DateTime.parse(t.dueDate!));
    return switch (due) {
      TodoDueFilter.any => true,
      TodoDueFilter.today => d == _dateOnly(today),
      TodoDueFilter.thisWeek =>
        !d.isBefore(_startOfWeek(today)) && !d.isAfter(_endOfWeek(today)),
      TodoDueFilter.thisMonth =>
        !d.isBefore(_startOfMonth(today)) && !d.isAfter(_endOfMonth(today)),
    };
  }).toList();
}

/// Applies the status, priority and due-date filters together (#53 AC: the
/// three filters combine) — the three predicates are independent, so
/// application order doesn't affect the result (mirrors activity_filters.
/// dart's own `filterActivities`).
List<Todo> filterTodos(
  List<Todo> todos, {
  TodoStatusFilter status = TodoStatusFilter.all,
  String? priority,
  TodoDueFilter due = TodoDueFilter.any,
  required DateTime today,
}) => filterTodosByDue(
  filterTodosByPriority(filterTodosByStatus(todos, status, today), priority),
  due,
  today,
);

int _statusRank(Todo todo, DateTime today) {
  if (isOverdue(todo, today)) return 0;
  if (!todo.isDone) return 1;
  return 2;
}

int _compareDueDate(Todo a, Todo b, SortDirection direction) {
  final da = a.dueDate == null ? null : DateTime.parse(a.dueDate!);
  final db = b.dueDate == null ? null : DateTime.parse(b.dueDate!);
  // A null due date always sorts last, regardless of [direction] — "no due
  // date" isn't a value that should flip to "first" just because the
  // direction toggled (#53's own design call, documented in the PR
  // description: no repo precedent for a sort-direction toggle yet).
  if (da == null && db == null) return 0;
  if (da == null) return 1;
  if (db == null) return -1;
  final cmp = da.compareTo(db);
  return direction == SortDirection.ascending ? cmp : -cmp;
}

int _comparePriority(Todo a, Todo b, SortDirection direction) {
  final cmp = todoPriorityRank(
    a.priority,
  ).compareTo(todoPriorityRank(b.priority));
  return direction == SortDirection.ascending ? cmp : -cmp;
}

int _compareStatus(Todo a, Todo b, DateTime today, SortDirection direction) {
  final cmp = _statusRank(a, today).compareTo(_statusRank(b, today));
  return direction == SortDirection.ascending ? cmp : -cmp;
}

/// Each [TodoSortField]'s own sensible default [SortDirection] (#53 AC:
/// "sortable by due date, priority, and status") — due date defaults to
/// soonest/overdue-first (ascending), priority to most-urgent-first
/// (descending, high -> low), status to the fixed lifecycle order
/// (ascending: overdue -> open -> done). Used to reset the direction toggle
/// whenever the sort field itself changes, so switching field never leaves
/// a stale, field-inappropriate direction selected.
SortDirection defaultSortDirectionFor(TodoSortField field) => switch (field) {
  TodoSortField.dueDate => SortDirection.ascending,
  TodoSortField.priority => SortDirection.descending,
  TodoSortField.status => SortDirection.ascending,
};

/// Sorts (a copy of) [todos] by [field]/[direction] (#53 AC: "sortable by
/// due date, priority, and status") — never mutates the input list (this
/// repo's own immutability convention). Ties break on [Todo.id] for a
/// deterministic order regardless of the input's own iteration order.
List<Todo> sortTodos(
  List<Todo> todos, {
  required TodoSortField field,
  required SortDirection direction,
  required DateTime today,
}) {
  final sorted = List<Todo>.from(todos);
  sorted.sort((a, b) {
    final cmp = switch (field) {
      TodoSortField.dueDate => _compareDueDate(a, b, direction),
      TodoSortField.priority => _comparePriority(a, b, direction),
      TodoSortField.status => _compareStatus(a, b, today, direction),
    };
    return cmp != 0 ? cmp : a.id.compareTo(b.id);
  });
  return sorted;
}

/// The filtered + sorted, ready-to-render state for the Todos tab (#53) —
/// mirrors activity_filters.dart's own `ActivitiesViewModel` split between
/// "no todos at all yet" (the onboarding-style empty state) and "the current
/// filters matched nothing" (the no-results state, #53 AC).
class TodosViewModel {
  const TodosViewModel({
    required this.hasAnyTodos,
    required this.filtered,
    required this.today,
  });

  final bool hasAnyTodos;
  final List<Todo> filtered;

  /// The "now" this view model's [filtered]/sort was computed against
  /// (`todosViewModelProvider`'s own single `DateTime.now()` call) — carried
  /// on the view model itself, rather than the rendering layer
  /// (`TodoListView`/its tile) calling `DateTime.now()` a second time, so a
  /// row's own overdue badge can never disagree with the filtering/sorting
  /// that already decided it belongs in this list (no risk of the two calls
  /// straddling a midnight rollover).
  final DateTime today;
}

/// The Todos tab's filter/sort state providers (#53). Plain `autoDispose`
/// (not `.family`-scoped like activity_filters.dart's own) — mirrors
/// journey_filters.dart's own un-scoped convention: there is only ever one
/// Todos tab, no embedded/per-apiary variant, so per-instance scoping has no
/// second consumer to serve yet (YAGNI).
final todoStatusFilterProvider = StateProvider.autoDispose<TodoStatusFilter>(
  (ref) => TodoStatusFilter.all,
);

final todoPriorityFilterProvider = StateProvider.autoDispose<String?>(
  (ref) => null,
);

final todoDueFilterProvider = StateProvider.autoDispose<TodoDueFilter>(
  (ref) => TodoDueFilter.any,
);

final todoSortFieldProvider = StateProvider.autoDispose<TodoSortField>(
  (ref) => TodoSortField.dueDate,
);

final todoSortDirectionProvider = StateProvider.autoDispose<SortDirection>(
  (ref) => defaultSortDirectionFor(TodoSortField.dueDate),
);

/// Combines [todosStreamProvider] with the filter/sort state providers above
/// into one ready-to-render state (#53). Mirrors activity_filters.dart's own
/// `activitiesViewModelProvider`: `today` is computed once per rebuild (not
/// injected — this codebase has no clock-abstraction precedent yet, see
/// activity_list_widgets.dart's own bare `DateTime.now()` call for its date-
/// range picker), so the overdue/due-date-preset boundary can shift across
/// midnight exactly like the rest of the app's date handling.
final todosViewModelProvider = Provider.autoDispose<AsyncValue<TodosViewModel>>(
  (ref) {
    final todosAsync = ref.watch(todosStreamProvider);
    final status = ref.watch(todoStatusFilterProvider);
    final priority = ref.watch(todoPriorityFilterProvider);
    final due = ref.watch(todoDueFilterProvider);
    final sortField = ref.watch(todoSortFieldProvider);
    final sortDirection = ref.watch(todoSortDirectionProvider);
    final today = DateTime.now();

    return todosAsync.whenData((todos) {
      final filtered = filterTodos(
        todos,
        status: status,
        priority: priority,
        due: due,
        today: today,
      );
      final sorted = sortTodos(
        filtered,
        field: sortField,
        direction: sortDirection,
        today: today,
      );
      return TodosViewModel(
        hasAnyTodos: todos.isNotEmpty,
        filtered: sorted,
        today: today,
      );
    });
  },
);
