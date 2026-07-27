import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/notifications/notification_checker.dart';
import 'package:beekeepingit_client/features/notifications/notification_dedup_store.dart';
import 'package:beekeepingit_client/features/notifications/notification_events.dart';
import 'package:beekeepingit_client/features/notifications/notification_models.dart';
import 'package:beekeepingit_client/features/notifications/notification_preferences_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> store = {};

  @override
  String? read(String key) => store[key];

  @override
  void write(String key, String value) => store[key] = value;

  @override
  void remove(String key) => store.remove(key);
}

Todo _overdueTodo(String id, {String? assigneeId}) => Todo(
  id: id,
  title: 'Feed hive $id',
  priority: 'medium',
  status: 'open',
  dueDate: '2020-01-01',
  assigneeId: assigneeId,
);

void main() {
  group('NotificationChecker.check', () {
    test('surfaces a todo-due and a sync-failure notification together', () {
      final prefs = _FakeLocalPrefs();
      final checker = NotificationChecker(
        dedupStore: NotificationDedupStore(prefs: prefs),
        preferences: NotificationPreferencesRepository(prefs: prefs),
      );

      final result = checker.check(
        todos: [_overdueTodo('t1')],
        today: DateTime(2026, 7, 27),
        pendingCount: 0,
        rejectedOpIds: {'op-1'},
      );

      expect(result.whereType<TodoDueAppNotification>(), hasLength(1));
      expect(result.whereType<SyncResultAppNotification>(), hasLength(1));
    });

    test(
      'a disabled event produces no notification even though its condition is true',
      () {
        final prefs = _FakeLocalPrefs();
        NotificationPreferencesRepository(
          prefs: prefs,
        ).setEnabled(notificationEventTodoDueReminder, false);
        final checker = NotificationChecker(
          dedupStore: NotificationDedupStore(prefs: prefs),
          preferences: NotificationPreferencesRepository(prefs: prefs),
        );

        final result = checker.check(
          todos: [_overdueTodo('t1')],
          today: DateTime(2026, 7, 27),
          pendingCount: 3,
          rejectedOpIds: const {},
        );

        expect(result, isEmpty);
      },
    );

    test('dedup state persists across calls (simulating the app reopening): '
        'the same condition does not re-notify on the second check', () {
      final prefs = _FakeLocalPrefs();
      final dedupStore = NotificationDedupStore(prefs: prefs);
      final checker = NotificationChecker(
        dedupStore: dedupStore,
        preferences: NotificationPreferencesRepository(prefs: prefs),
      );
      final todos = [_overdueTodo('t1')];

      final firstOpen = checker.check(
        todos: todos,
        today: DateTime(2026, 7, 27),
        pendingCount: 0,
        rejectedOpIds: const {},
      );
      // A second, brand-new NotificationChecker instance (e.g. a fresh
      // provider container after a real app restart) reading the SAME
      // underlying store must still remember what was already notified.
      final checkerAfterRestart = NotificationChecker(
        dedupStore: NotificationDedupStore(prefs: prefs),
        preferences: NotificationPreferencesRepository(prefs: prefs),
      );
      final secondOpen = checkerAfterRestart.check(
        todos: todos,
        today: DateTime(2026, 7, 27),
        pendingCount: 0,
        rejectedOpIds: const {},
      );

      expect(firstOpen, isNotEmpty);
      expect(secondOpen, isEmpty);
    });

    test(
      'the org-wide reminder audience is preserved end-to-end regardless of assignee',
      () {
        final prefs = _FakeLocalPrefs();
        final checker = NotificationChecker(
          dedupStore: NotificationDedupStore(prefs: prefs),
          preferences: NotificationPreferencesRepository(prefs: prefs),
        );

        final result = checker.check(
          todos: [_overdueTodo('t1', assigneeId: 'a-different-member')],
          today: DateTime(2026, 7, 27),
          pendingCount: 0,
          rejectedOpIds: const {},
        );

        expect(result.whereType<TodoDueAppNotification>(), hasLength(1));
      },
    );
  });
}
