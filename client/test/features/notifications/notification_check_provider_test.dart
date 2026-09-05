import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/notifications/notification_check_provider.dart';
import 'package:beekeepingit_client/features/notifications/notification_dedup_store.dart';
import 'package:beekeepingit_client/features/notifications/notification_feed_provider.dart';
import 'package:beekeepingit_client/features/notifications/notification_models.dart';
import 'package:beekeepingit_client/features/notifications/notification_preferences_repository.dart';
import 'package:beekeepingit_client/features/settings/notification_settings_repository.dart';
import 'package:beekeepingit_client/features/sync/sync_rejected_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/shell/sync_status.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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

Todo _overdueTodo(String id) => Todo(
  id: id,
  title: 'Feed hive $id',
  priority: 'medium',
  status: 'open',
  dueDate: '2020-01-01',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer buildContainer({
    required List<Todo> todos,
    required List<RejectedOp> rejected,
    required SyncStatus status,
    LocalPrefs? prefs,
  }) {
    final localPrefs = prefs ?? _FakeLocalPrefs();
    final container = ProviderContainer(
      overrides: [
        todosStreamProvider.overrideWith((ref) => Stream.value(todos)),
        syncRejectedOpsProvider.overrideWith((ref) => Stream.value(rejected)),
        syncStatusProvider.overrideWithValue(status),
        notificationDedupStoreProvider.overrideWithValue(
          NotificationDedupStore(prefs: localPrefs),
        ),
        notificationPreferencesRepositoryProvider.overrideWithValue(
          NotificationPreferencesRepository(prefs: localPrefs),
        ),
        notificationSettingsRepositoryProvider.overrideWithValue(
          NotificationSettingsRepository(prefs: localPrefs),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('notificationCheckProvider', () {
    test(
      'runs a check immediately when first watched (app cold start)',
      () async {
        final container = buildContainer(
          todos: [_overdueTodo('t1')],
          rejected: const [],
          status: const SyncStatus(
            connectivity: SyncConnectivity.online,
            pendingCount: 0,
          ),
        );

        container.listen(notificationCheckProvider, (_, _) {});
        await pumpEventQueue();

        final published = container.read(notificationFeedProvider);
        expect(published.whereType<TodoDueAppNotification>(), hasLength(1));
      },
    );

    test('a failed check degrades silently (best-effort)', () async {
      final container = ProviderContainer(
        overrides: [
          // A stream that errors immediately — stands in for "no
          // organization/PowerSync session yet" without touching the real
          // native PowerSync stack. The check must swallow this, not crash.
          todosStreamProvider.overrideWith(
            (ref) => Stream<List<Todo>>.error(Exception('no session yet')),
          ),
          syncRejectedOpsProvider.overrideWith((ref) => Stream.value(const [])),
          syncStatusProvider.overrideWithValue(
            const SyncStatus(
              connectivity: SyncConnectivity.offline,
              pendingCount: 0,
            ),
          ),
          notificationDedupStoreProvider.overrideWithValue(
            NotificationDedupStore(prefs: _FakeLocalPrefs()),
          ),
          notificationPreferencesRepositoryProvider.overrideWithValue(
            NotificationPreferencesRepository(prefs: _FakeLocalPrefs()),
          ),
          notificationSettingsRepositoryProvider.overrideWithValue(
            NotificationSettingsRepository(prefs: _FakeLocalPrefs()),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        () => container.listen(notificationCheckProvider, (_, _) {}),
        returnsNormally,
      );
      await pumpEventQueue();

      expect(container.read(notificationFeedProvider), isEmpty);
    });

    test('publishes nothing when nothing crosses a new condition', () async {
      final container = buildContainer(
        todos: const [],
        rejected: const [],
        status: const SyncStatus(
          connectivity: SyncConnectivity.offline,
          pendingCount: 2,
        ),
      );

      container.listen(notificationCheckProvider, (_, _) {});
      await pumpEventQueue();

      expect(container.read(notificationFeedProvider), isEmpty);
    });

    test('the master notification switch off suppresses runCheck\'s published '
        'notifications entirely (#500, FR-ST-1, D-24)', () async {
      final prefs = _FakeLocalPrefs();
      NotificationSettingsRepository(prefs: prefs)
          .setNotificationsEnabled(false);
      final container = buildContainer(
        todos: [_overdueTodo('t1')],
        rejected: const [],
        status: const SyncStatus(
          connectivity: SyncConnectivity.online,
          pendingCount: 0,
        ),
        prefs: prefs,
      );

      container.listen(notificationCheckProvider, (_, _) {});
      await pumpEventQueue();

      expect(container.read(notificationFeedProvider), isEmpty);
    });
  });
}
