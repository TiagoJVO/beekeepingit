import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/storage/local_prefs.dart';
import 'notification_events.dart';

/// Reads/writes the caller's per-event notification preferences (#82's
/// preference-key contract, D-24, FR-ST-1). A single JSON-encoded
/// `{eventKey: enabled}` map under one [LocalPrefs] key — mirrors
/// `profile_repository.dart`'s `kProfileCacheKey`/`kOrganizationCacheKey`
/// convention (one JSON blob, one key) rather than a PowerSync table: these
/// preferences never need SQL querying or the sync engine's own reactivity,
/// just a plain per-device key-value read/write, checked once per app-open
/// notification check (`notification_checker.dart`). Kept local-only
/// (not synced to the server, unlike `locale` on the profile resource) — v1
/// has no cross-device requirement for these, and the toggle-list story
/// (#288) only ever needs "persists per user and survives app restarts"
/// (its own AC), which a purged-on-logout local key already satisfies (see
/// [kNotificationPreferencesKey]'s own doc).
class NotificationPreferencesRepository {
  NotificationPreferencesRepository({LocalPrefs? prefs})
    : _prefs = prefs ?? createLocalPrefs();

  final LocalPrefs _prefs;

  /// Every known v1 event key, resolved to its stored value or
  /// [notificationEventDefaultEnabled] when absent (first run, or a newer
  /// event this client version didn't know about when the value was last
  /// written).
  Map<String, bool> readAll() {
    final stored = _readStored();
    return {
      for (final key in knownNotificationEvents)
        key: stored[key] as bool? ?? notificationEventDefaultEnabled,
    };
  }

  bool isEnabled(String eventKey) =>
      readAll()[eventKey] ?? notificationEventDefaultEnabled;

  void setEnabled(String eventKey, bool enabled) {
    final current = readAll();
    current[eventKey] = enabled;
    _prefs.write(kNotificationPreferencesKey, jsonEncode(current));
  }

  /// Best-effort parse of the stored blob — a missing, malformed, or
  /// wrong-shaped value degrades to "nothing stored" (every event then reads
  /// as its default) rather than throwing, matching
  /// `profile_repository.dart`'s own tolerant-cache convention.
  Map<String, dynamic> _readStored() {
    final raw = _prefs.read(kNotificationPreferencesKey);
    if (raw == null) return const {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      return const {};
    } on TypeError {
      return const {};
    }
  }
}

final notificationPreferencesRepositoryProvider =
    Provider<NotificationPreferencesRepository>(
      (ref) => NotificationPreferencesRepository(),
    );

/// Reactive per-user preference state (mirrors `core/l10n/locale_provider.dart`'s
/// own "established pattern for a persisted, reactive per-user preference"):
/// #288's toggle list reads this to render its switches and calls
/// [setEnabled] when the user flips one; the notification engine
/// (`notification_checker.dart`) reads the same repository directly at each
/// app-open check (it doesn't need reactivity — it runs once per check, not
/// continuously while a widget is mounted).
class NotificationPreferencesController extends Notifier<Map<String, bool>> {
  @override
  Map<String, bool> build() =>
      ref.watch(notificationPreferencesRepositoryProvider).readAll();

  void setEnabled(String eventKey, bool enabled) {
    ref
        .read(notificationPreferencesRepositoryProvider)
        .setEnabled(eventKey, enabled);
    state = {...state, eventKey: enabled};
  }
}

final notificationPreferencesProvider =
    NotifierProvider<NotificationPreferencesController, Map<String, bool>>(
      NotificationPreferencesController.new,
    );
