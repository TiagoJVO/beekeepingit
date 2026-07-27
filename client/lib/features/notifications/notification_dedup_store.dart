import 'dart:convert';

import '../../core/storage/local_prefs.dart';

/// The notification engine's durable "already notified for this condition"
/// state (#82 AC: "once per condition change, not once per app-open" —
/// requires tracking state that survives restarts). Read once, mutated, and
/// written back by [NotificationDedupStore] on every app-open check
/// (`notification_checker.dart`).
class NotificationDedupState {
  const NotificationDedupState({
    this.todoDueBuckets = const {},
    this.notifiedSyncFailureIds = const {},
    this.wasFullySynced = true,
  });

  /// Per-todo-id last-notified due bucket (`'due_soon'` | `'overdue'`,
  /// `notification_engine.dart`'s bucket keys). A todo absent from this map
  /// has never matched either bucket, or has since left it (completed, due
  /// date pushed out, deleted) — either way, a later (re-)crossing is
  /// treated as new.
  final Map<String, String> todoDueBuckets;

  /// Rejected-op ids (`RejectedOp.id`, `features/sync/sync_rejected_repository.dart`)
  /// already surfaced as a "needs fixing" notification. Re-notify only for
  /// ids not yet in this set — a genuinely NEW failure, not the same one
  /// still sitting in the dead-letter queue across a later app-open.
  final Set<String> notifiedSyncFailureIds;

  /// Whether the last check found everything fully synced (no pending
  /// writes, no rejected ops needing a fix). Drives the "sync completed"
  /// notification firing only on the false→true transition, not on every
  /// open while it stays true.
  ///
  /// Defaults to `true` (not `false`) — deliberately: on a genuinely fresh
  /// device with no prior recorded state, there is no earlier "not synced"
  /// baseline to have recovered FROM, so the first-ever check must not
  /// manufacture a false "just finished syncing!" notification out of
  /// nothing. `computeSyncNotifications` only ever notifies success on an
  /// observed false→true transition; starting from `true` means a
  /// brand-new device that happens to have nothing pending on its very
  /// first check stays silent, exactly as it should.
  final bool wasFullySynced;

  NotificationDedupState copyWith({
    Map<String, String>? todoDueBuckets,
    Set<String>? notifiedSyncFailureIds,
    bool? wasFullySynced,
  }) => NotificationDedupState(
    todoDueBuckets: todoDueBuckets ?? this.todoDueBuckets,
    notifiedSyncFailureIds:
        notifiedSyncFailureIds ?? this.notifiedSyncFailureIds,
    wasFullySynced: wasFullySynced ?? this.wasFullySynced,
  );

  factory NotificationDedupState.fromJson(Map<String, dynamic> json) =>
      NotificationDedupState(
        todoDueBuckets:
            (json['todoDueBuckets'] as Map<String, dynamic>? ?? const {}).map(
              (key, value) => MapEntry(key, value as String),
            ),
        notifiedSyncFailureIds:
            ((json['notifiedSyncFailureIds'] as List<dynamic>?) ?? const [])
                .map((e) => e as String)
                .toSet(),
        // Falls back to the same default the constructor uses (`true`) —
        // see [wasFullySynced]'s own doc — for a stored blob that predates
        // this field, not a hardcoded value that could drift from it.
        wasFullySynced:
            json['wasFullySynced'] as bool? ??
            const NotificationDedupState().wasFullySynced,
      );

  Map<String, dynamic> toJson() => {
    'todoDueBuckets': todoDueBuckets,
    'notifiedSyncFailureIds': notifiedSyncFailureIds.toList(),
    'wasFullySynced': wasFullySynced,
  };
}

/// Reads/writes [NotificationDedupState] as one JSON blob under one
/// [LocalPrefs] key — mirrors
/// `notification_preferences_repository.dart`'s own convention (and its
/// rationale: no SQL querying or sync-engine reactivity needed, just a plain
/// per-device snapshot read once per check). Purged on logout
/// ([kNotificationDedupStateKey]'s own doc) so a second user on a shared
/// device starts with a clean dedup slate rather than inheriting the prior
/// user's "already notified" history.
class NotificationDedupStore {
  NotificationDedupStore({LocalPrefs? prefs})
    : _prefs = prefs ?? createLocalPrefs();

  final LocalPrefs _prefs;

  /// The stored state, or the empty default when nothing is stored yet
  /// (first run) or the stored value is malformed — degrades rather than
  /// throwing, matching `notification_preferences_repository.dart`'s own
  /// tolerant-parse convention.
  NotificationDedupState read() {
    final raw = _prefs.read(kNotificationDedupStateKey);
    if (raw == null) return const NotificationDedupState();
    try {
      return NotificationDedupState.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on FormatException {
      return const NotificationDedupState();
    } on TypeError {
      return const NotificationDedupState();
    }
  }

  void write(NotificationDedupState state) {
    _prefs.write(kNotificationDedupStateKey, jsonEncode(state.toJson()));
  }
}
