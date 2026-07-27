import 'local_prefs_stub.dart'
    if (dart.library.js_interop) 'local_prefs_web.dart';

/// A tiny key-value seam over durable browser storage (`localStorage` on
/// web), used to cache last-known-good snapshots for offline-first reads
/// (#390) — e.g. the onboarding gate's profile/organization checks
/// (`features/profile/profile_repository.dart`,
/// `features/organization/organization_repository.dart`). Kept separate from
/// `core/auth/auth_platform.dart`'s own `readLocal`/`writeLocal`: that seam is
/// scoped to the OIDC redirect flow's concerns (session tokens, PKCE
/// verifier/state, browser navigation) and its non-web stub deliberately
/// *throws* (auth is only available on web) — general-purpose caching should
/// instead degrade silently (no cache) on a non-web/VM target, which is what
/// widget/unit tests run on.
abstract interface class LocalPrefs {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
}

/// Constructs the platform implementation for the current target.
LocalPrefs createLocalPrefs() => makeLocalPrefs();

/// Cache key for the onboarding gate's last-known-good profile snapshot
/// (`ProfileRepository.fetch()`). Public (not private to
/// profile_repository.dart) because `AuthController.logout()`/
/// `_clearLocalSession()` also needs it, to purge the cache on logout so a
/// second user on the same shared device never sees a prior user's cached
/// onboarding state (#390).
const kProfileCacheKey = 'bk.profile';

/// Cache key for the onboarding gate's last-known-good organization snapshot
/// (`OrganizationRepository.fetchMine()`) — see [kProfileCacheKey].
const kOrganizationCacheKey = 'bk.organization';

/// Settings key (FR-ST-1, #81) for the "auto-sync" preference —
/// `features/settings/sync_settings_repository.dart` reads/writes it, and
/// `core/sync/powersync_service.dart` honors it (EPIC-06's sync layer).
/// Public for the same reason as [kProfileCacheKey]: `AuthController.logout()`
/// purges it so a second user on a shared device doesn't inherit the prior
/// user's device-local sync preference.
const kAutoSyncEnabledKey = 'bk.settings.auto_sync_enabled';

/// Settings key (FR-ST-1, #81) for the notifications master switch —
/// `features/settings/notification_settings_repository.dart` reads/writes it.
/// Gates the notification engine's own per-event preferences below
/// ([kNotificationPreferencesKey]): `NotificationChecker.check` and
/// `shell/app_shell.dart`'s real-time sync-conflict toast listener both
/// consult this key in addition to the per-event map, so switching it off
/// stops delivery outright rather than only dimming the settings-screen
/// toggle list (D-24, #500). Purged on logout — see [kAutoSyncEnabledKey].
const kNotificationsEnabledKey = 'bk.settings.notifications_enabled';

/// Cache key for the notification engine's per-event preference map (#82's
/// preference-key contract, D-24, FR-ST-1) — see
/// `features/notifications/notification_preferences_repository.dart`. Purged
/// on logout (`auth_controller.dart`'s `_clearLocalSession`) for the same
/// reason as [kProfileCacheKey]: a second user on a shared device must never
/// inherit a prior user's notification toggles.
const kNotificationPreferencesKey = 'bk.notification_prefs';

/// Cache key for the notification engine's durable "already notified for
/// this condition" dedup state (#82's once-per-condition-change repeat
/// policy) — see `features/notifications/notification_dedup_store.dart`.
/// Purged on logout for the same reason as [kNotificationPreferencesKey].
const kNotificationDedupStateKey = 'bk.notification_state';
