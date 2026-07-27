import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/settings/notification_settings_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalPrefs] fake — same convention as
/// `profile_repository_test.dart`/`auth_controller_test.dart`.
class _FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> _store = {};

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

void main() {
  group('NotificationSettingsRepository', () {
    test('notifications default to enabled when nothing is persisted yet', () {
      final repo = NotificationSettingsRepository(prefs: _FakeLocalPrefs());

      expect(repo.isNotificationsEnabled(), isTrue);
    });

    test('setNotificationsEnabled(false) persists and is read back', () {
      final prefs = _FakeLocalPrefs();
      final repo = NotificationSettingsRepository(prefs: prefs);

      repo.setNotificationsEnabled(false);

      expect(repo.isNotificationsEnabled(), isFalse);
      expect(prefs.read(kNotificationsEnabledKey), isNotNull);
    });

    test('setNotificationsEnabled persists across a fresh repository '
        'instance (survives app restart)', () {
      final prefs = _FakeLocalPrefs();
      NotificationSettingsRepository(
        prefs: prefs,
      ).setNotificationsEnabled(false);

      final reopened = NotificationSettingsRepository(prefs: prefs);

      expect(reopened.isNotificationsEnabled(), isFalse);
    });
  });

  group('notificationsEnabledProvider', () {
    ProviderContainer buildContainer(LocalPrefs prefs) {
      final container = ProviderContainer(
        overrides: [
          notificationSettingsRepositoryProvider.overrideWithValue(
            NotificationSettingsRepository(prefs: prefs),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('reads the persisted value on first read', () {
      final prefs = _FakeLocalPrefs();
      NotificationSettingsRepository(
        prefs: prefs,
      ).setNotificationsEnabled(false);
      final container = buildContainer(prefs);

      expect(container.read(notificationsEnabledProvider), isFalse);
    });

    test('defaults to enabled when nothing is persisted', () {
      final container = buildContainer(_FakeLocalPrefs());

      expect(container.read(notificationsEnabledProvider), isTrue);
    });

    test('setEnabled updates state and persists the new value', () {
      final prefs = _FakeLocalPrefs();
      final container = buildContainer(prefs);

      container.read(notificationsEnabledProvider.notifier).setEnabled(false);

      expect(container.read(notificationsEnabledProvider), isFalse);
      expect(
        NotificationSettingsRepository(prefs: prefs).isNotificationsEnabled(),
        isFalse,
      );
    });
  });
}
