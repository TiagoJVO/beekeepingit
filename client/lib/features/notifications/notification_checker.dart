import '../settings/notification_settings_repository.dart';
import '../todos/todos_repository.dart';
import 'notification_dedup_store.dart';
import 'notification_engine.dart';
import 'notification_models.dart';
import 'notification_preferences_repository.dart';

/// Orchestrates one full app-open/foreground notification check (#82, D-24):
/// reads the durable dedup state, runs the pure detection functions
/// (`notification_engine.dart`) against the caller-supplied current facts,
/// persists the updated dedup state, and filters the result by the user's
/// per-event preferences before returning it for display.
///
/// Deliberately a plain class over already-loaded data (todos/pending
/// count/rejected-op ids as constructor-call arguments to [check], not
/// Riverpod providers it reads itself) — mirrors `combineSyncStatus`'s own
/// extraction rationale (`shell/sync_status.dart`): this is the piece
/// [NFR-TST-1] needs covered, so it stays plain-Dart-testable against fakes,
/// independent of a real PowerSync session/org context. The thin adapter
/// that gathers those facts from the app's real providers and wires the
/// app-open/foreground signal lives in `notification_check_provider.dart`.
class NotificationChecker {
  const NotificationChecker({
    required this.dedupStore,
    required this.preferences,
    required this.settings,
  });

  final NotificationDedupStore dedupStore;
  final NotificationPreferencesRepository preferences;

  /// The master "Enable notifications" switch (#81, FR-ST-1, D-24, #500) —
  /// consulted in addition to [preferences]' per-event map. Gates delivery
  /// of every event family this checker computes, not just the settings
  /// screen's toggle-list UI.
  final NotificationSettingsRepository settings;

  /// Runs one check. [todos] must be the caller's ENTIRE org-wide todo list
  /// (D-23) — this never filters by assignee itself, so passing an
  /// already-assignee-filtered list would silently narrow the reminder
  /// audience against the AC's intent. [pendingCount]/[rejectedOpIds] are
  /// the caller's own device sync state (`shell/sync_status.dart`,
  /// `features/sync/sync_rejected_repository.dart`).
  ///
  /// Preference-gating (both the master switch and the per-event map)
  /// happens AFTER the dedup state is computed and persisted — a disabled/
  /// muted condition is still tracked (so re-enabling notifications later
  /// doesn't flood the user with every change that happened while it was
  /// off, #500), only its *display* is suppressed.
  List<AppNotification> check({
    required List<Todo> todos,
    required DateTime today,
    required int pendingCount,
    required Set<String> rejectedOpIds,
  }) {
    final state = dedupStore.read();

    final todoResult = computeTodoDueNotifications(
      todos: todos,
      today: today,
      previousBuckets: state.todoDueBuckets,
    );
    final syncResult = computeSyncNotifications(
      pendingCount: pendingCount,
      rejectedOpIds: rejectedOpIds,
      previousNotifiedFailureIds: state.notifiedSyncFailureIds,
      previousWasFullySynced: state.wasFullySynced,
    );

    dedupStore.write(
      state.copyWith(
        todoDueBuckets: todoResult.nextBuckets,
        notifiedSyncFailureIds: syncResult.nextNotifiedFailureIds,
        wasFullySynced: syncResult.nextWasFullySynced,
      ),
    );

    // The master switch short-circuits to no notifications (#500) — checked
    // AFTER the dedup write above, so the "already notified" state keeps
    // tracking conditions while muted.
    if (!settings.isNotificationsEnabled()) return const [];

    return [
      ...todoResult.toNotify,
      ...syncResult.toNotify,
    ].where((n) => preferences.isEnabled(n.eventKey)).toList();
  }
}
