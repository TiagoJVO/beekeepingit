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

/// [d] reduced to its calendar day — a local midnight, matching the plain
/// `YYYY-MM-DD` shape [Todo.dueDate] itself carries (no time component to
/// compare). Shared with `todo_filters.dart`'s own calendar-window presets so
/// "which day is this" is answered one way across the feature.
///
/// Deliberately NOT the UTC normalization [_daysBetween] uses: this one is
/// only ever compared with another value from the same function (equality,
/// `isBefore`), where the timezone cancels out, while [_daysBetween]
/// SUBTRACTS two instants and would lose an hour to a DST transition (#665).
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// True when [todo] is open (not done) and its due date has already passed
/// [today] — the calendar date only, never time-of-day. A todo due exactly
/// [today] is NOT overdue; a done todo is never overdue regardless of its due
/// date; a todo with no due date can never be overdue.
///
/// Lives here, with [todoDueBucket] and [dueSoonWindowDays], rather than in
/// `todo_filters.dart` where #53 first wrote it: this file is the single
/// owner of "what does this todo's due date mean right now", and the Todos
/// tab's status filter, the D-24 reminder engine and D-35's Home summary all
/// read that one answer instead of each keeping their own (#661).
bool isOverdue(Todo todo, DateTime today) {
  if (todo.isDone) return false;
  final dueDate = todo.dueDate;
  if (dueDate == null) return false;
  return dateOnly(DateTime.parse(dueDate)).isBefore(dateOnly(today));
}

/// Whole days between two calendar days, counted on **UTC** midnights — the
/// client's one day-difference convention, shared verbatim with
/// `apiary_visit_recency.dart`'s `_daysBetween` and `home_screen.dart`'s
/// `_daysLate`.
///
/// Subtracting LOCAL midnights instead would silently lose an hour across a
/// spring-forward DST transition, and [Duration.inDays] truncates that 23-hour
/// day straight off the count: a real 3-day gap read as 2, bucketing a todo
/// [TodoDueBucket.dueSoon] — and firing its D-24 reminder — a day early
/// (#665). These UTC instants are never stored or displayed; they exist only
/// for this subtraction.
int _daysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// The due-date bucket [todo] currently falls in relative to [today], or
/// null when it isn't due-soon/overdue at all (no due date, already done, or
/// due further out than its own priority's window). Reuses this file's own
/// [isOverdue] for the overdue check (DRY, coding-style.md) rather than
/// re-deriving "what counts as overdue" here — the Todos tab's filter, the
/// notification engine and the Home summary (#658, D-35) must never disagree
/// on that question, which is why this lives in shared todo domain code
/// instead of privately inside any one of them.
TodoDueBucket? todoDueBucket(Todo todo, DateTime today) {
  if (todo.isDone) return null;
  final dueDate = todo.dueDate;
  if (dueDate == null) return null;
  if (isOverdue(todo, today)) return TodoDueBucket.overdue;

  final due = DateTime.parse(dueDate);
  final daysUntilDue = _daysBetween(today, due);
  if (daysUntilDue >= 0 && daysUntilDue <= dueSoonWindowDays(todo.priority)) {
    return TodoDueBucket.dueSoon;
  }
  return null;
}

/// True when [todo] is in EITHER due bucket as of [today] — overdue or due
/// soon. The union D-35's Home "tasks needing attention" section shows, and
/// the set `TodoStatusFilter.needsAttention` filters the Todos tab to
/// (#661).
///
/// Deliberately phrased as "[todoDueBucket] returned something" rather than
/// as a predicate of its own: there is exactly ONE definition of overdue and
/// of due-soon in this app, and every surface that asks the question — the
/// Home count, the Todos tab's filtered list, the D-24 reminder engine —
/// reads it from here, so they cannot drift apart. Widening or narrowing the
/// rule stays a single edit to [todoDueBucket]/[dueSoonWindowDays].
bool todoNeedsAttention(Todo todo, DateTime today) =>
    todoDueBucket(todo, today) != null;
