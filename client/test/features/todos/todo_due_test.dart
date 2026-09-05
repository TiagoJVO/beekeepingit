import 'package:beekeepingit_client/features/todos/todo_due.dart';
import 'package:beekeepingit_client/features/todos/todo_filters.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter_test/flutter_test.dart';

Todo _todo({
  String id = 't1',
  String title = 'Inspect hives',
  String priority = todoPriorityMedium,
  String status = 'open',
  String? dueDate,
}) => Todo(
  id: id,
  title: title,
  priority: priority,
  status: status,
  dueDate: dueDate,
);

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  final today = DateTime(2026, 7, 27);
  String inDays(int days) => _isoDate(today.add(Duration(days: days)));

  group('dueSoonWindowDays', () {
    const cases = <({String name, String priority, int expected})>[
      (
        name: 'high warns 3 days ahead',
        priority: todoPriorityHigh,
        expected: 3,
      ),
      (
        name: 'medium warns 2 days ahead',
        priority: todoPriorityMedium,
        expected: 2,
      ),
      (name: 'low warns 1 day ahead', priority: todoPriorityLow, expected: 1),
      // An unknown priority (a newer value replicated down from a newer
      // server) falls back to the narrowest window rather than throwing —
      // pinned here so the lift can't quietly change the fallback.
      (
        name: 'an unknown priority falls back to 1',
        priority: 'urgent!!',
        expected: 1,
      ),
      (name: 'an empty priority falls back to 1', priority: '', expected: 1),
    ];

    for (final c in cases) {
      test(c.name, () {
        expect(dueSoonWindowDays(c.priority), c.expected);
      });
    }
  });

  group('todoDueBucket', () {
    const cases =
        <
          ({
            String name,
            String priority,
            String status,
            int? dueInDays,
            TodoDueBucket? expected,
          })
        >[
          // Due TODAY is due-soon, never overdue — must agree with
          // todo_filters.dart's own isOverdue (a todo due exactly today is NOT
          // overdue).
          (
            name: 'due today is dueSoon for high',
            priority: todoPriorityHigh,
            status: 'open',
            dueInDays: 0,
            expected: TodoDueBucket.dueSoon,
          ),
          (
            name: 'due today is dueSoon for medium',
            priority: todoPriorityMedium,
            status: 'open',
            dueInDays: 0,
            expected: TodoDueBucket.dueSoon,
          ),
          (
            name: 'due today is dueSoon for low',
            priority: todoPriorityLow,
            status: 'open',
            dueInDays: 0,
            expected: TodoDueBucket.dueSoon,
          ),
          // Window edges, per priority: in-bucket AT the window, out one day past.
          (
            name: 'high is dueSoon 3 days out',
            priority: todoPriorityHigh,
            status: 'open',
            dueInDays: 3,
            expected: TodoDueBucket.dueSoon,
          ),
          (
            name: 'high is not bucketed 4 days out',
            priority: todoPriorityHigh,
            status: 'open',
            dueInDays: 4,
            expected: null,
          ),
          (
            name: 'medium is dueSoon 2 days out',
            priority: todoPriorityMedium,
            status: 'open',
            dueInDays: 2,
            expected: TodoDueBucket.dueSoon,
          ),
          (
            name: 'medium is not bucketed 3 days out',
            priority: todoPriorityMedium,
            status: 'open',
            dueInDays: 3,
            expected: null,
          ),
          (
            name: 'low is dueSoon 1 day out',
            priority: todoPriorityLow,
            status: 'open',
            dueInDays: 1,
            expected: TodoDueBucket.dueSoon,
          ),
          (
            name: 'low is not bucketed 2 days out',
            priority: todoPriorityLow,
            status: 'open',
            dueInDays: 2,
            expected: null,
          ),
          // An unknown priority uses the same fallback window as low.
          (
            name: 'an unknown priority is dueSoon 1 day out',
            priority: 'urgent!!',
            status: 'open',
            dueInDays: 1,
            expected: TodoDueBucket.dueSoon,
          ),
          (
            name: 'an unknown priority is not bucketed 2 days out',
            priority: 'urgent!!',
            status: 'open',
            dueInDays: 2,
            expected: null,
          ),
          // Past due, at every priority, is overdue regardless of window width.
          (
            name: 'due yesterday is overdue',
            priority: todoPriorityMedium,
            status: 'open',
            dueInDays: -1,
            expected: TodoDueBucket.overdue,
          ),
          (
            name: 'long past due is overdue',
            priority: todoPriorityHigh,
            status: 'open',
            dueInDays: -30,
            expected: TodoDueBucket.overdue,
          ),
          // Done and no-due-date are never bucketed.
          (
            name: 'a done todo due today is null',
            priority: todoPriorityHigh,
            status: 'done',
            dueInDays: 0,
            expected: null,
          ),
          (
            name: 'a done todo long past due is null',
            priority: todoPriorityHigh,
            status: 'done',
            dueInDays: -30,
            expected: null,
          ),
          (
            name: 'a todo with no due date is null',
            priority: todoPriorityHigh,
            status: 'open',
            dueInDays: null,
            expected: null,
          ),
          (
            name: 'a done todo with no due date is null',
            priority: todoPriorityHigh,
            status: 'done',
            dueInDays: null,
            expected: null,
          ),
        ];

    for (final c in cases) {
      test(c.name, () {
        final todo = _todo(
          priority: c.priority,
          status: c.status,
          dueDate: c.dueInDays == null ? null : inDays(c.dueInDays!),
        );

        expect(todoDueBucket(todo, today), c.expected);
      });
    }

    test('never disagrees with todo_filters.dart isOverdue', () {
      for (final priority in const [
        todoPriorityLow,
        todoPriorityMedium,
        todoPriorityHigh,
        'urgent!!',
      ]) {
        for (final status in const ['open', 'done']) {
          for (var offset = -5; offset <= 5; offset++) {
            final todo = _todo(
              priority: priority,
              status: status,
              dueDate: inDays(offset),
            );

            expect(
              todoDueBucket(todo, today) == TodoDueBucket.overdue,
              isOverdue(todo, today),
              reason:
                  'priority=$priority status=$status offset=$offset must '
                  'bucket as overdue exactly when isOverdue says so',
            );
          }
        }
      }
    });

    test('ignores the time-of-day component of today', () {
      final lateToday = DateTime(2026, 7, 27, 23, 59, 59);
      final todo = _todo(priority: todoPriorityLow, dueDate: inDays(0));

      expect(todoDueBucket(todo, lateToday), TodoDueBucket.dueSoon);
    });
  });
}
