import 'todo_filters.dart' show isOverdue;
import 'todo_priority.dart';
import 'todos_repository.dart';

/// Which due-date window a todo currently falls in (#82, FR-TD-1) — computed
/// by [todoDueBucket] relative to the todo's own due date/priority (D-24). A
/// closed set (never an open string) since every caller must handle both
/// cases explicitly — Dart's exhaustive `switch` over an enum is a compile
/// error if a case is missed.
///
/// Defined here in `features/todos/` — not in the notifications feature that
/// first needed it — since #658/D-35's Home summary asks the same "what's
/// overdue / due soon" question as the notification engine, and the two must
/// never answer it differently. `notification_models.dart` re-exports this
/// enum, so its existing import sites (and the bucket names persisted in
/// `NotificationDedupState.todoDueBuckets`) are unaffected by the move.
enum TodoDueBucket { dueSoon, overdue }

/// How many days ahead of its due date a todo starts counting as "due soon"
/// (#82 AC: "fire relative to the todo's due date/priority") — a higher
/// priority todo warns earlier, since it typically needs more lead time to
/// act on. No spec value is given anywhere in `requirements/`, so these are
/// this story's own deliberate, simple default (documented here rather than
/// left as a bare magic number, coding-style.md): high=3 days, medium=2,
/// low=1. An unknown priority (a newer value replicated down from a newer
/// server) falls back to the narrowest window rather than throwing, matching
/// `todo_priority.dart`'s own graceful-degradation convention. Adjusting the
/// window later is a one-line, code-only change — the bucket *keys*
/// persisted in `NotificationDedupState` don't encode the window width, so
/// widening/narrowing it doesn't invalidate stored state.
int dueSoonWindowDays(String priority) => switch (priority) {
  todoPriorityHigh => 3,
  todoPriorityMedium => 2,
  todoPriorityLow => 1,
  _ => 1,
};

/// The due-date bucket [todo] currently falls in relative to [today], or
/// null when it isn't due-soon/overdue at all (no due date, already done, or
/// due further out than its own priority's window). Reuses
/// `todo_filters.dart`'s own [isOverdue] for the overdue check (DRY,
/// coding-style.md) rather than re-deriving "what counts as overdue" here —
/// the Todos tab's filter, the notification engine and the Home summary
/// (#658, D-35) must never disagree on that question, which is why this
/// lives in shared todo domain code instead of privately inside any one of
/// them.
TodoDueBucket? todoDueBucket(Todo todo, DateTime today) {
  if (todo.isDone) return null;
  final dueDate = todo.dueDate;
  if (dueDate == null) return null;
  if (isOverdue(todo, today)) return TodoDueBucket.overdue;

  final due = DateTime.parse(dueDate);
  final dueOnly = DateTime(due.year, due.month, due.day);
  final todayOnly = DateTime(today.year, today.month, today.day);
  final daysUntilDue = dueOnly.difference(todayOnly).inDays;
  if (daysUntilDue >= 0 && daysUntilDue <= dueSoonWindowDays(todo.priority)) {
    return TodoDueBucket.dueSoon;
  }
  return null;
}
