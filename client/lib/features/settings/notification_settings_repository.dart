import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/bool_pref.dart';
import '../../core/storage/local_prefs.dart';

/// The "notification preferences" master switch (FR-ST-1, D-24, #81):
/// device-local, in-app-only ("Enable notifications" at the top of the
/// settings screen's Notifications section, gating everything below it).
///
/// This is deliberately the *only* notification preference this story owns.
/// The per-event catalog (todo due-date reminders, sync results, ...) and its
/// preference-key contract belong to the notification engine (#82 — "this
/// story owns the preference-key contract those toggles write to"); the
/// per-event toggle list UI is #288's. This repository exists so #81's
/// settings screen has one real, working, testable notification preference
/// today, and so the container it builds for #288 has something meaningful
/// to gate (see `notification_settings_section.dart`'s `eventTogglesSlot`).
///
/// Device-local rather than the server-synced Profile resource, for the same
/// reason as `sync_settings_repository.dart`: D-24 is explicit that v1
/// notifications are in-app-only with **no backend notification service** —
/// there is no server resource for this to live on, and "what to surface on
/// app-open, on this device" is inherently a per-installation concern in this
/// phase (push/cross-device sync of notification prefs is deferred with push
/// itself, per D-24).
class NotificationSettingsRepository {
  NotificationSettingsRepository({LocalPrefs? prefs})
    : _prefs = prefs ?? createLocalPrefs();

  final LocalPrefs _prefs;

  static const _defaultNotificationsEnabled = true;

  BoolPref get _notificationsPref => BoolPref(
    _prefs,
    kNotificationsEnabledKey,
    defaultValue: _defaultNotificationsEnabled,
  );

  bool isNotificationsEnabled() => _notificationsPref.read();

  void setNotificationsEnabled(bool enabled) =>
      _notificationsPref.write(enabled);
}

final notificationSettingsRepositoryProvider =
    Provider<NotificationSettingsRepository>((ref) {
      return NotificationSettingsRepository();
    });

/// Reactive wrapper around [NotificationSettingsRepository] — mirrors
/// `sync_settings_repository.dart`'s `AutoSyncController` shape so both
/// settings sections (and, later, the notification engine, #82) follow the
/// same pattern.
class NotificationsEnabledController extends Notifier<bool> {
  @override
  bool build() =>
      ref.read(notificationSettingsRepositoryProvider).isNotificationsEnabled();

  void setEnabled(bool enabled) {
    ref
        .read(notificationSettingsRepositoryProvider)
        .setNotificationsEnabled(enabled);
    state = enabled;
  }
}

final notificationsEnabledProvider =
    NotifierProvider<NotificationsEnabledController, bool>(
      NotificationsEnabledController.new,
    );
