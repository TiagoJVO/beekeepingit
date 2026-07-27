import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/bool_pref.dart';
import '../../core/storage/local_prefs.dart';

/// The "sync settings" half of the settings screen (FR-ST-1, #81):
/// device-local preferences that gate the EPIC-06 sync layer's own connect
/// behavior (`core/sync/powersync_service.dart`, `core/sync/sync_gate.dart`).
///
/// Deliberately device-local ([LocalPrefs]), not the server-synced Profile
/// resource (`features/profile/profile_repository.dart`, which carries
/// `locale`): auto-sync gates *this device's* on-device PowerSync engine
/// before it ever talks to the network, so it must be readable without a
/// network round-trip — round-tripping to the profile endpoint to decide
/// whether to use the network is a chicken-and-egg problem the server-synced
/// resource can't solve any better than the local store can. It's also
/// genuinely per-installation (a metered-data phone and an unmetered desktop
/// may reasonably disagree), unlike `locale`, which is a property of the
/// person and should follow them to any device.
class SyncSettingsRepository {
  SyncSettingsRepository({LocalPrefs? prefs})
    : _prefs = prefs ?? createLocalPrefs();

  final LocalPrefs _prefs;

  static const _defaultAutoSyncEnabled = true;

  BoolPref get _autoSyncPref => BoolPref(
    _prefs,
    kAutoSyncEnabledKey,
    defaultValue: _defaultAutoSyncEnabled,
  );

  /// Whether the sync engine should connect/reconnect automatically
  /// (FR-OF-3's connection-quality-gated behavior). Defaults to `true` — the
  /// existing, pre-#81 behavior — so upgrading users see no change until they
  /// deliberately opt out. Manual "Sync now" (`syncNowProvider`) always works
  /// regardless of this setting (sync.md §7.1's override).
  bool isAutoSyncEnabled() => _autoSyncPref.read();

  void setAutoSyncEnabled(bool enabled) => _autoSyncPref.write(enabled);
}

final syncSettingsRepositoryProvider = Provider<SyncSettingsRepository>((ref) {
  return SyncSettingsRepository();
});

/// Reactive wrapper around [SyncSettingsRepository.isAutoSyncEnabled] — the
/// settings screen's switch and `powersync_service.dart`'s gate wiring both
/// watch/read this instead of the repository directly, so a toggle takes
/// effect immediately everywhere without a restart (AC: "changing a setting
/// takes effect without requiring a reinstall").
class AutoSyncController extends Notifier<bool> {
  @override
  bool build() => ref.read(syncSettingsRepositoryProvider).isAutoSyncEnabled();

  void setEnabled(bool enabled) {
    ref.read(syncSettingsRepositoryProvider).setAutoSyncEnabled(enabled);
    state = enabled;
  }
}

final autoSyncEnabledProvider = NotifierProvider<AutoSyncController, bool>(
  AutoSyncController.new,
);
