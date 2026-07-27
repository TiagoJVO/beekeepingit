import 'package:beekeepingit_client/features/notifications/notification_events.dart';
import 'package:beekeepingit_client/features/notifications/notification_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TodoDueAppNotification', () {
    test('maps to the todo-due-reminder event key regardless of bucket', () {
      const dueSoon = TodoDueAppNotification(
        todoId: 't1',
        title: 'Inspect hives',
        bucket: TodoDueBucket.dueSoon,
      );
      const overdue = TodoDueAppNotification(
        todoId: 't1',
        title: 'Inspect hives',
        bucket: TodoDueBucket.overdue,
      );

      expect(dueSoon.eventKey, notificationEventTodoDueReminder);
      expect(overdue.eventKey, notificationEventTodoDueReminder);
    });

    test('two notifications with the same fields are equal', () {
      const a = TodoDueAppNotification(
        todoId: 't1',
        title: 'Inspect hives',
        bucket: TodoDueBucket.overdue,
      );
      const b = TodoDueAppNotification(
        todoId: 't1',
        title: 'Inspect hives',
        bucket: TodoDueBucket.overdue,
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('SyncResultAppNotification', () {
    test('maps failure/success to their own distinct event keys', () {
      const failure = SyncResultAppNotification(
        outcome: SyncNotificationOutcome.failure,
      );
      const success = SyncResultAppNotification(
        outcome: SyncNotificationOutcome.success,
      );

      expect(failure.eventKey, notificationEventSyncFailure);
      expect(success.eventKey, notificationEventSyncSuccess);
      expect(failure.eventKey == success.eventKey, isFalse);
    });
  });
}
