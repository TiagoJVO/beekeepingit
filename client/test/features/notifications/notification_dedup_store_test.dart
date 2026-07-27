import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/notifications/notification_dedup_store.dart';
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

void main() {
  group('NotificationDedupState', () {
    test('round-trips through JSON', () {
      const state = NotificationDedupState(
        todoDueBuckets: {'todo-1': 'overdue', 'todo-2': 'due_soon'},
        notifiedSyncFailureIds: {'op-1', 'op-2'},
        wasFullySynced: true,
      );

      final restored = NotificationDedupState.fromJson(state.toJson());

      expect(restored.todoDueBuckets, state.todoDueBuckets);
      expect(restored.notifiedSyncFailureIds, state.notifiedSyncFailureIds);
      expect(restored.wasFullySynced, state.wasFullySynced);
    });

    test('copyWith replaces only the given fields', () {
      const state = NotificationDedupState(
        todoDueBuckets: {'todo-1': 'overdue'},
        notifiedSyncFailureIds: {'op-1'},
        wasFullySynced: false,
      );

      final updated = state.copyWith(wasFullySynced: true);

      expect(updated.todoDueBuckets, state.todoDueBuckets);
      expect(updated.notifiedSyncFailureIds, state.notifiedSyncFailureIds);
      expect(updated.wasFullySynced, isTrue);
    });
  });

  group('NotificationDedupStore', () {
    test('reads the empty/default state when nothing is stored yet', () {
      final store = NotificationDedupStore(prefs: _FakeLocalPrefs());

      final state = store.read();

      expect(state.todoDueBuckets, isEmpty);
      expect(state.notifiedSyncFailureIds, isEmpty);
      // Defaults to true, not false — see NotificationDedupState.wasFullySynced's
      // own doc: a fresh device has no prior "not synced" baseline to have
      // recovered from, so the very first check must not manufacture a
      // false "just finished syncing!" notification.
      expect(state.wasFullySynced, isTrue);
    });

    test('a written state survives across store instances (app restart)', () {
      final prefs = _FakeLocalPrefs();
      const written = NotificationDedupState(
        todoDueBuckets: {'todo-9': 'due_soon'},
        notifiedSyncFailureIds: {'op-9'},
        wasFullySynced: true,
      );
      NotificationDedupStore(prefs: prefs).write(written);

      final reloaded = NotificationDedupStore(prefs: prefs).read();

      expect(reloaded.todoDueBuckets, written.todoDueBuckets);
      expect(reloaded.notifiedSyncFailureIds, written.notifiedSyncFailureIds);
      expect(reloaded.wasFullySynced, isTrue);
    });

    test(
      'tolerates a corrupt stored value by degrading to the empty state',
      () {
        final prefs = _FakeLocalPrefs()
          ..write(kNotificationDedupStateKey, '{not valid json');

        final state = NotificationDedupStore(prefs: prefs).read();

        expect(state.todoDueBuckets, isEmpty);
        expect(state.notifiedSyncFailureIds, isEmpty);
        expect(state.wasFullySynced, isTrue);
      },
    );
  });
}
