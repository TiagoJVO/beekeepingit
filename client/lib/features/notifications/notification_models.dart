import '../todos/todo_due.dart';
import 'notification_events.dart';

// `TodoDueBucket` (which due-date window a todo falls in, #82/FR-TD-1) used
// to be declared here. It now lives in `features/todos/todo_due.dart`
// alongside the rule that computes it, so the notification engine and
// #658/D-35's Home summary share one answer to "what's overdue / due soon".
// Re-exported so every existing import site of this file — and the bucket
// names persisted in `NotificationDedupState.todoDueBuckets` — keep working
// untouched.
export '../todos/todo_due.dart' show TodoDueBucket;

/// Which sync-result outcome occurred (#82, D-24, FR-OF-2's notify-and-fix
/// rule) — computed by `notification_engine.dart`'s
/// `computeSyncNotifications`. `conflict` (an offline edit superseded by a
/// newer write) is deliberately NOT a case here: unlike these two, it has no
/// durable local record to check at app-open (sync.md's LWW-loss log is
/// server-authored history, not a client dead-letter table) — it is already
/// delivered live the moment it happens (`shell/sync_status.dart`'s
/// `supersededNotificationProvider`), which this engine's preference gate
/// (`notificationEventSyncConflict`) covers directly at the display site
/// instead of re-detecting it here.
enum SyncNotificationOutcome { failure, success }

/// One in-app notification ready for display (#82, D-24). Sealed + an
/// exhaustive `switch` at the one display site (`shell/app_shell.dart`)
/// resolves each variant to its localized message — this file stays
/// localization-agnostic, matching `todo_priority.dart`'s own split between
/// "which value" (here) and "which label" (`AppLocalizations`, at the
/// display site).
sealed class AppNotification {
  const AppNotification();

  /// The preference-key (`notification_events.dart`'s catalog) this
  /// notification is gated by — `NotificationChecker.check` filters on this.
  String get eventKey;
}

/// A todo crossing into (or further into) its due-date reminder window —
/// org-wide (D-23): [todoId]/[title] identify the todo, not who it's
/// notifying, since every org member who opens the app sees the same event
/// regardless of [Todo.assigneeId].
final class TodoDueAppNotification extends AppNotification {
  const TodoDueAppNotification({
    required this.todoId,
    required this.title,
    required this.bucket,
  });

  final String todoId;
  final String title;
  final TodoDueBucket bucket;

  @override
  String get eventKey => notificationEventTodoDueReminder;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TodoDueAppNotification &&
          runtimeType == other.runtimeType &&
          todoId == other.todoId &&
          title == other.title &&
          bucket == other.bucket);

  @override
  int get hashCode => Object.hash(todoId, title, bucket);

  @override
  String toString() =>
      'TodoDueAppNotification(todoId: $todoId, title: $title, bucket: $bucket)';
}

/// A sync-result event (D-24: a push failure needing a fix, or a completion)
/// — carries no entity id, since it reflects the caller's OWN device sync
/// state (`shell/sync_status.dart`), not another org member's.
final class SyncResultAppNotification extends AppNotification {
  const SyncResultAppNotification({required this.outcome});

  final SyncNotificationOutcome outcome;

  @override
  String get eventKey => switch (outcome) {
    SyncNotificationOutcome.failure => notificationEventSyncFailure,
    SyncNotificationOutcome.success => notificationEventSyncSuccess,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncResultAppNotification &&
          runtimeType == other.runtimeType &&
          outcome == other.outcome);

  @override
  int get hashCode => outcome.hashCode;

  @override
  String toString() => 'SyncResultAppNotification(outcome: $outcome)';
}
