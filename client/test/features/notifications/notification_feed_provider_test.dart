import 'package:beekeepingit_client/features/notifications/notification_feed_provider.dart';
import 'package:beekeepingit_client/features/notifications/notification_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('notificationFeedProvider', () {
    test('starts empty', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(notificationFeedProvider), isEmpty);
    });

    test('publish appends to the pending queue rather than replacing it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const first = SyncResultAppNotification(
        outcome: SyncNotificationOutcome.success,
      );
      const second = TodoDueAppNotification(
        todoId: 't1',
        title: 'Feed hive',
        bucket: TodoDueBucket.overdue,
      );

      container.read(notificationFeedProvider.notifier).publish([first]);
      container.read(notificationFeedProvider.notifier).publish([second]);

      expect(container.read(notificationFeedProvider), [first, second]);
    });

    test('publishing an empty list is a no-op', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(notificationFeedProvider.notifier).publish(const []);

      expect(container.read(notificationFeedProvider), isEmpty);
    });

    test('drain clears the queue once notifications have been delivered', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const notification = SyncResultAppNotification(
        outcome: SyncNotificationOutcome.success,
      );
      container.read(notificationFeedProvider.notifier).publish([notification]);

      container.read(notificationFeedProvider.notifier).drain();

      expect(container.read(notificationFeedProvider), isEmpty);
    });
  });
}
