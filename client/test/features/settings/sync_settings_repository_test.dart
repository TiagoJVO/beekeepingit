import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/settings/sync_settings_repository.dart';
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
  group('SyncSettingsRepository', () {
    test('auto-sync defaults to enabled when nothing is persisted yet', () {
      final repo = SyncSettingsRepository(prefs: _FakeLocalPrefs());

      expect(repo.isAutoSyncEnabled(), isTrue);
    });

    test('setAutoSyncEnabled(false) persists and is read back', () {
      final prefs = _FakeLocalPrefs();
      final repo = SyncSettingsRepository(prefs: prefs);

      repo.setAutoSyncEnabled(false);

      expect(repo.isAutoSyncEnabled(), isFalse);
      expect(prefs.read(kAutoSyncEnabledKey), isNotNull);
    });

    test('setAutoSyncEnabled persists across a fresh repository instance '
        '(survives app restart)', () {
      final prefs = _FakeLocalPrefs();
      SyncSettingsRepository(prefs: prefs).setAutoSyncEnabled(false);

      final reopened = SyncSettingsRepository(prefs: prefs);

      expect(reopened.isAutoSyncEnabled(), isFalse);
    });
  });

  group('autoSyncEnabledProvider', () {
    ProviderContainer buildContainer(LocalPrefs prefs) {
      final container = ProviderContainer(
        overrides: [
          syncSettingsRepositoryProvider.overrideWithValue(
            SyncSettingsRepository(prefs: prefs),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('reads the persisted value on first read', () {
      final prefs = _FakeLocalPrefs();
      SyncSettingsRepository(prefs: prefs).setAutoSyncEnabled(false);
      final container = buildContainer(prefs);

      expect(container.read(autoSyncEnabledProvider), isFalse);
    });

    test('defaults to enabled when nothing is persisted', () {
      final container = buildContainer(_FakeLocalPrefs());

      expect(container.read(autoSyncEnabledProvider), isTrue);
    });

    test('setEnabled updates state and persists the new value', () {
      final prefs = _FakeLocalPrefs();
      final container = buildContainer(prefs);

      container.read(autoSyncEnabledProvider.notifier).setEnabled(false);

      expect(container.read(autoSyncEnabledProvider), isFalse);
      expect(SyncSettingsRepository(prefs: prefs).isAutoSyncEnabled(), isFalse);
    });

    test('notifies listeners when toggled', () {
      final container = buildContainer(_FakeLocalPrefs());
      final seen = <bool>[];
      container.listen(
        autoSyncEnabledProvider,
        (_, next) => seen.add(next),
        fireImmediately: true,
      );

      container.read(autoSyncEnabledProvider.notifier).setEnabled(false);
      container.read(autoSyncEnabledProvider.notifier).setEnabled(true);

      expect(seen, [true, false, true]);
    });
  });
}
