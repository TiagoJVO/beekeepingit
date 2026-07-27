import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/notifications/notification_events.dart';
import 'package:beekeepingit_client/features/notifications/notification_preferences_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalPrefs] fake — mirrors profile_repository_test.dart's
/// own `_FakeLocalPrefs` convention (no real localStorage on the VM tests
/// run on).
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
  group('NotificationPreferencesRepository', () {
    test('every known event defaults to enabled when nothing is stored', () {
      final repo = NotificationPreferencesRepository(prefs: _FakeLocalPrefs());

      final all = repo.readAll();

      for (final key in knownNotificationEvents) {
        expect(all[key], isTrue, reason: '$key should default to enabled');
      }
      expect(repo.isEnabled(notificationEventTodoDueReminder), isTrue);
    });

    test(
      'setEnabled persists a per-event override that isEnabled reflects',
      () {
        final repo = NotificationPreferencesRepository(
          prefs: _FakeLocalPrefs(),
        );

        repo.setEnabled(notificationEventSyncFailure, false);

        expect(repo.isEnabled(notificationEventSyncFailure), isFalse);
        // Untouched events stay at their default.
        expect(repo.isEnabled(notificationEventTodoDueReminder), isTrue);
      },
    );

    test('a preference survives across repository instances (durability)', () {
      final prefs = _FakeLocalPrefs();
      NotificationPreferencesRepository(
        prefs: prefs,
      ).setEnabled(notificationEventTodoDueReminder, false);

      final reloaded = NotificationPreferencesRepository(prefs: prefs);

      expect(reloaded.isEnabled(notificationEventTodoDueReminder), isFalse);
    });

    test('tolerates a corrupt stored value by degrading to defaults', () {
      final prefs = _FakeLocalPrefs()
        ..write(kNotificationPreferencesKey, 'not json{{{');
      final repo = NotificationPreferencesRepository(prefs: prefs);

      expect(repo.isEnabled(notificationEventSyncSuccess), isTrue);
    });
  });

  group('NotificationPreferencesController', () {
    test('exposes the repository state reactively and re-emits on change', () {
      final prefs = _FakeLocalPrefs();
      final container = ProviderContainer(
        overrides: [
          notificationPreferencesRepositoryProvider.overrideWithValue(
            NotificationPreferencesRepository(prefs: prefs),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        container.read(
          notificationPreferencesProvider,
        )[notificationEventSyncFailure],
        isTrue,
      );

      container
          .read(notificationPreferencesProvider.notifier)
          .setEnabled(notificationEventSyncFailure, false);

      expect(
        container.read(
          notificationPreferencesProvider,
        )[notificationEventSyncFailure],
        isFalse,
      );
      // The write went through the injected repository too, not just
      // in-memory controller state.
      expect(
        NotificationPreferencesRepository(
          prefs: prefs,
        ).isEnabled(notificationEventSyncFailure),
        isFalse,
      );
    });
  });
}
