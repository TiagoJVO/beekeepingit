import 'package:beekeepingit_client/features/notifications/notification_engine.dart';
import 'package:beekeepingit_client/features/notifications/notification_models.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter_test/flutter_test.dart';

Todo _todo({
  required String id,
  String title = 'Inspect hives',
  String priority = todoPriorityMedium,
  String status = 'open',
  String? dueDate,
  String? assigneeId,
}) => Todo(
  id: id,
  title: title,
  priority: priority,
  status: status,
  dueDate: dueDate,
  assigneeId: assigneeId,
);

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  final today = DateTime(2026, 7, 27);

  group('computeTodoDueNotifications — bucket detection', () {
    test('a todo due far in the future produces no notification', () {
      final todos = [
        _todo(id: 't1', dueDate: _isoDate(today.add(const Duration(days: 30)))),
      ];

      final result = computeTodoDueNotifications(
        todos: todos,
        today: today,
        previousBuckets: const {},
      );

      expect(result.toNotify, isEmpty);
      expect(result.nextBuckets, isEmpty);
    });

    test('a todo with no due date never notifies', () {
      final todos = [_todo(id: 't1')];

      final result = computeTodoDueNotifications(
        todos: todos,
        today: today,
        previousBuckets: const {},
      );

      expect(result.toNotify, isEmpty);
    });

    test('a done todo never notifies even if its due date has passed', () {
      final todos = [
        _todo(
          id: 't1',
          status: 'done',
          dueDate: _isoDate(today.subtract(const Duration(days: 5))),
        ),
      ];

      final result = computeTodoDueNotifications(
        todos: todos,
        today: today,
        previousBuckets: const {},
      );

      expect(result.toNotify, isEmpty);
      expect(result.nextBuckets, isEmpty);
    });

    test('a todo due yesterday is overdue and notifies', () {
      final todos = [
        _todo(
          id: 't1',
          dueDate: _isoDate(today.subtract(const Duration(days: 1))),
        ),
      ];

      final result = computeTodoDueNotifications(
        todos: todos,
        today: today,
        previousBuckets: const {},
      );

      expect(result.toNotify, [
        const TodoDueAppNotification(
          todoId: 't1',
          title: 'Inspect hives',
          bucket: TodoDueBucket.overdue,
        ),
      ]);
      expect(result.nextBuckets, {'t1': 'overdue'});
    });

    test('a todo due today is not overdue (matches isOverdue semantics)', () {
      final todos = [_todo(id: 't1', dueDate: _isoDate(today))];

      final result = computeTodoDueNotifications(
        todos: todos,
        today: today,
        previousBuckets: const {},
      );

      expect(
        (result.toNotify.single as TodoDueAppNotification).bucket,
        TodoDueBucket.dueSoon,
      );
    });

    test(
      'due-soon window widens with priority: high=3d, medium=2d, low=1d',
      () {
        final todos = [
          _todo(
            id: 'high',
            priority: todoPriorityHigh,
            dueDate: _isoDate(today.add(const Duration(days: 3))),
          ),
          _todo(
            id: 'medium',
            priority: todoPriorityMedium,
            dueDate: _isoDate(today.add(const Duration(days: 2))),
          ),
          _todo(
            id: 'low',
            priority: todoPriorityLow,
            dueDate: _isoDate(today.add(const Duration(days: 1))),
          ),
          // One day beyond each priority's own window: not due-soon yet.
          _todo(
            id: 'high-not-yet',
            priority: todoPriorityHigh,
            dueDate: _isoDate(today.add(const Duration(days: 4))),
          ),
          _todo(
            id: 'low-not-yet',
            priority: todoPriorityLow,
            dueDate: _isoDate(today.add(const Duration(days: 2))),
          ),
        ];

        final result = computeTodoDueNotifications(
          todos: todos,
          today: today,
          previousBuckets: const {},
        );

        final notifiedIds = result.toNotify
            .cast<TodoDueAppNotification>()
            .map((n) => n.todoId)
            .toSet();
        expect(notifiedIds, {'high', 'medium', 'low'});
        expect(result.nextBuckets['high'], 'due_soon');
        expect(result.nextBuckets.containsKey('high-not-yet'), isFalse);
        expect(result.nextBuckets.containsKey('low-not-yet'), isFalse);
      },
    );

    test(
      'the reminder audience is org-wide: assignee never gates the notification',
      () {
        final todos = [
          _todo(
            id: 'mine',
            assigneeId: 'me',
            dueDate: _isoDate(today.subtract(const Duration(days: 1))),
          ),
          _todo(
            id: 'someone-elses',
            assigneeId: 'someone-else',
            dueDate: _isoDate(today.subtract(const Duration(days: 1))),
          ),
          _todo(
            id: 'unassigned',
            dueDate: _isoDate(today.subtract(const Duration(days: 1))),
          ),
        ];

        final result = computeTodoDueNotifications(
          todos: todos,
          today: today,
          previousBuckets: const {},
        );

        final notifiedIds = result.toNotify
            .cast<TodoDueAppNotification>()
            .map((n) => n.todoId)
            .toSet();
        expect(notifiedIds, {'mine', 'someone-elses', 'unassigned'});
      },
    );
  });

  group(
    'computeTodoDueNotifications — once-per-condition-change repeat policy',
    () {
      test('the same bucket on a later check does not re-notify', () {
        final todos = [
          _todo(
            id: 't1',
            dueDate: _isoDate(today.subtract(const Duration(days: 1))),
          ),
        ];

        final first = computeTodoDueNotifications(
          todos: todos,
          today: today,
          previousBuckets: const {},
        );
        final second = computeTodoDueNotifications(
          todos: todos,
          today: today,
          previousBuckets: first.nextBuckets,
        );

        expect(first.toNotify, isNotEmpty);
        expect(second.toNotify, isEmpty);
      });

      test(
        'crossing from due-soon into overdue re-notifies (a genuine state change)',
        () {
          final dueSoonTodo = _todo(
            id: 't1',
            priority: todoPriorityHigh,
            dueDate: _isoDate(today.add(const Duration(days: 2))),
          );
          final firstCheck = computeTodoDueNotifications(
            todos: [dueSoonTodo],
            today: today,
            previousBuckets: const {},
          );
          expect(firstCheck.nextBuckets['t1'], 'due_soon');

          // Two days later, still with the same (now-past) due date: overdue.
          final laterToday = today.add(const Duration(days: 3));
          final secondCheck = computeTodoDueNotifications(
            todos: [dueSoonTodo],
            today: laterToday,
            previousBuckets: firstCheck.nextBuckets,
          );

          expect(secondCheck.toNotify, [
            TodoDueAppNotification(
              todoId: 't1',
              title: dueSoonTodo.title,
              bucket: TodoDueBucket.overdue,
            ),
          ]);
        },
      );

      test(
        'a todo that leaves the due-soon/overdue window (completed) drops its '
        'dedup entry, so a later re-crossing notifies again',
        () {
          final overdueTodo = _todo(
            id: 't1',
            dueDate: _isoDate(today.subtract(const Duration(days: 1))),
          );
          final firstCheck = computeTodoDueNotifications(
            todos: [overdueTodo],
            today: today,
            previousBuckets: const {},
          );
          expect(firstCheck.toNotify, isNotEmpty);

          // Completed: no longer in the bucket map at all.
          final completedTodo = _todo(
            id: 't1',
            status: 'done',
            dueDate: overdueTodo.dueDate,
          );
          final secondCheck = computeTodoDueNotifications(
            todos: [completedTodo],
            today: today,
            previousBuckets: firstCheck.nextBuckets,
          );
          expect(secondCheck.toNotify, isEmpty);
          expect(secondCheck.nextBuckets, isEmpty);

          // Reopened later, still overdue: treated as a brand-new crossing.
          final thirdCheck = computeTodoDueNotifications(
            todos: [overdueTodo],
            today: today,
            previousBuckets: secondCheck.nextBuckets,
          );
          expect(thirdCheck.toNotify, isNotEmpty);
        },
      );
    },
  );

  group('computeSyncNotifications', () {
    test('a brand-new rejected op notifies failure once', () {
      final result = computeSyncNotifications(
        pendingCount: 0,
        rejectedOpIds: {'op-1'},
        previousNotifiedFailureIds: const {},
        previousWasFullySynced: false,
      );

      expect(result.toNotify, [
        const SyncResultAppNotification(
          outcome: SyncNotificationOutcome.failure,
        ),
      ]);
      expect(result.nextNotifiedFailureIds, {'op-1'});
      expect(result.nextWasFullySynced, isFalse);
    });

    test(
      'the same outstanding failure does not re-notify on a later check',
      () {
        final first = computeSyncNotifications(
          pendingCount: 0,
          rejectedOpIds: {'op-1'},
          previousNotifiedFailureIds: const {},
          previousWasFullySynced: false,
        );

        final second = computeSyncNotifications(
          pendingCount: 0,
          rejectedOpIds: {'op-1'},
          previousNotifiedFailureIds: first.nextNotifiedFailureIds,
          previousWasFullySynced: first.nextWasFullySynced,
        );

        expect(second.toNotify, isEmpty);
      },
    );

    test(
      'a second, distinct failure alongside an already-known one re-notifies',
      () {
        final second = computeSyncNotifications(
          pendingCount: 0,
          rejectedOpIds: {'op-1', 'op-2'},
          previousNotifiedFailureIds: {'op-1'},
          previousWasFullySynced: false,
        );

        expect(second.toNotify, [
          const SyncResultAppNotification(
            outcome: SyncNotificationOutcome.failure,
          ),
        ]);
        expect(second.nextNotifiedFailureIds, {'op-1', 'op-2'});
      },
    );

    test('a fresh device with nothing ever pending does not fire a false '
        '"just synced" notification (NotificationDedupState\'s own default is '
        'wasFullySynced: true, not false, for exactly this reason)', () {
      final result = computeSyncNotifications(
        pendingCount: 0,
        rejectedOpIds: const {},
        previousNotifiedFailureIds: const {},
        previousWasFullySynced: true,
      );

      expect(result.toNotify, isEmpty);
    });

    test('transitioning to fully synced notifies success once', () {
      final result = computeSyncNotifications(
        pendingCount: 0,
        rejectedOpIds: const {},
        previousNotifiedFailureIds: const {},
        previousWasFullySynced: false,
      );

      expect(result.toNotify, [
        const SyncResultAppNotification(
          outcome: SyncNotificationOutcome.success,
        ),
      ]);
      expect(result.nextWasFullySynced, isTrue);
    });

    test('staying fully synced across later checks does not re-notify', () {
      final first = computeSyncNotifications(
        pendingCount: 0,
        rejectedOpIds: const {},
        previousNotifiedFailureIds: const {},
        previousWasFullySynced: false,
      );
      final second = computeSyncNotifications(
        pendingCount: 0,
        rejectedOpIds: const {},
        previousNotifiedFailureIds: first.nextNotifiedFailureIds,
        previousWasFullySynced: first.nextWasFullySynced,
      );

      expect(second.toNotify, isEmpty);
    });

    test(
      'pending writes alone (nothing rejected) is not yet "fully synced"',
      () {
        final result = computeSyncNotifications(
          pendingCount: 3,
          rejectedOpIds: const {},
          previousNotifiedFailureIds: const {},
          previousWasFullySynced: false,
        );

        expect(result.toNotify, isEmpty);
        expect(result.nextWasFullySynced, isFalse);
      },
    );

    test('going synced -> pending -> synced again re-notifies success', () {
      final synced = computeSyncNotifications(
        pendingCount: 0,
        rejectedOpIds: const {},
        previousNotifiedFailureIds: const {},
        previousWasFullySynced: false,
      );
      final pendingAgain = computeSyncNotifications(
        pendingCount: 2,
        rejectedOpIds: const {},
        previousNotifiedFailureIds: synced.nextNotifiedFailureIds,
        previousWasFullySynced: synced.nextWasFullySynced,
      );
      expect(pendingAgain.toNotify, isEmpty);

      final syncedAgain = computeSyncNotifications(
        pendingCount: 0,
        rejectedOpIds: const {},
        previousNotifiedFailureIds: pendingAgain.nextNotifiedFailureIds,
        previousWasFullySynced: pendingAgain.nextWasFullySynced,
      );

      expect(syncedAgain.toNotify, [
        const SyncResultAppNotification(
          outcome: SyncNotificationOutcome.success,
        ),
      ]);
    });

    test('a fixed rejection drops out of the dedup set (not held forever)', () {
      final withFailure = computeSyncNotifications(
        pendingCount: 0,
        rejectedOpIds: {'op-1'},
        previousNotifiedFailureIds: const {},
        previousWasFullySynced: false,
      );

      final fixed = computeSyncNotifications(
        pendingCount: 0,
        rejectedOpIds: const {},
        previousNotifiedFailureIds: withFailure.nextNotifiedFailureIds,
        previousWasFullySynced: withFailure.nextWasFullySynced,
      );
      expect(fixed.nextNotifiedFailureIds, isEmpty);

      // A brand-new failure with a fresh id after that is treated as new.
      final newFailure = computeSyncNotifications(
        pendingCount: 0,
        rejectedOpIds: {'op-2'},
        previousNotifiedFailureIds: fixed.nextNotifiedFailureIds,
        previousWasFullySynced: fixed.nextWasFullySynced,
      );
      expect(newFailure.toNotify, [
        const SyncResultAppNotification(
          outcome: SyncNotificationOutcome.failure,
        ),
      ]);
    });
  });
}
