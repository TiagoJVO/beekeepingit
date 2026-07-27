import 'package:beekeepingit_client/features/notifications/notification_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('notification event catalog (#82 preference-key contract)', () {
    test('the v1 event catalog contains exactly the four known keys', () {
      expect(knownNotificationEvents, [
        notificationEventTodoDueReminder,
        notificationEventSyncFailure,
        notificationEventSyncSuccess,
        notificationEventSyncConflict,
      ]);
    });

    test('every catalog key is a distinct, stable string', () {
      expect(knownNotificationEvents.toSet(), hasLength(4));
      expect(notificationEventTodoDueReminder, 'todo_due_reminder');
      expect(notificationEventSyncFailure, 'sync_failure');
      expect(notificationEventSyncSuccess, 'sync_success');
      expect(notificationEventSyncConflict, 'sync_conflict');
    });

    test('v1 default is opt-out — every event starts enabled', () {
      expect(notificationEventDefaultEnabled, isTrue);
    });
  });
}
