import '../todos/todo_due.dart';
import '../todos/todos_repository.dart';
import 'notification_models.dart';

/// The result of one [computeTodoDueNotifications] pass: the notifications
/// to show now, plus the full updated dedup map to persist
/// (`NotificationDedupState.todoDueBuckets`) for the *next* check to diff
/// against.
typedef TodoDueComputation = ({
  List<AppNotification> toNotify,
  Map<String, String> nextBuckets,
});

/// The result of one [computeSyncNotifications] pass — mirrors
/// [TodoDueComputation]'s own shape for the sync-result dedup fields
/// (`NotificationDedupState.notifiedSyncFailureIds`/`wasFullySynced`).
typedef SyncComputation = ({
  List<AppNotification> toNotify,
  Set<String> nextNotifiedFailureIds,
  bool nextWasFullySynced,
});

String _bucketKey(TodoDueBucket bucket) => switch (bucket) {
  TodoDueBucket.dueSoon => 'due_soon',
  TodoDueBucket.overdue => 'overdue',
};

/// Detects todo due-date reminder events (#82, FR-TD-1, D-24) across
/// [todos] — the caller's ENTIRE org-wide todo list (D-23: "assignment isn't
/// an access boundary"), never pre-filtered by assignee, so the reminder
/// audience is naturally every org member who opens the app, not just a
/// todo's own assignee.
///
/// Compares each todo's current bucket against [previousBuckets] (the last
/// persisted `NotificationDedupState.todoDueBuckets`) to implement the
/// once-per-condition-change repeat policy (#82 AC): a todo notifies again
/// only when its bucket key differs from what's already stored — a brand
/// new crossing, or a due-soon → overdue escalation. A todo that leaves both
/// buckets (completed, due date pushed out, deleted) is simply absent from
/// [TodoDueComputation.nextBuckets], so a later re-crossing is treated as
/// new rather than permanently suppressed.
TodoDueComputation computeTodoDueNotifications({
  required List<Todo> todos,
  required DateTime today,
  required Map<String, String> previousBuckets,
}) {
  final nextBuckets = <String, String>{};
  final toNotify = <AppNotification>[];

  for (final todo in todos) {
    final bucket = todoDueBucket(todo, today);
    if (bucket == null) continue;

    final key = _bucketKey(bucket);
    nextBuckets[todo.id] = key;
    if (previousBuckets[todo.id] != key) {
      toNotify.add(
        TodoDueAppNotification(
          todoId: todo.id,
          title: todo.title,
          bucket: bucket,
        ),
      );
    }
  }

  return (toNotify: toNotify, nextBuckets: nextBuckets);
}

/// Detects sync-result events (#82, D-24, FR-OF-2's notify-and-fix rule)
/// from the caller's own device sync state: [pendingCount] (queued,
/// not-yet-uploaded writes) and [rejectedOpIds] (the dead-letter queue's
/// current row ids, `features/sync/sync_rejected_repository.dart`'s
/// `RejectedOp.id`).
///
/// **Failure** notifies once per genuinely new rejected op — an id not
/// already in [previousNotifiedFailureIds] — so a still-outstanding
/// rejection from an earlier check never re-fires (once-per-condition-change,
/// #82 AC), while a distinct new rejection (or the same record failing again
/// after a fix attempt, which mints a fresh dead-letter row id —
/// `powersync_connector.dart`'s delete-then-insert) correctly notifies
/// again.
///
/// **Success** ("fully synced": no pending writes AND no rejections) fires
/// once on the false→true transition from [previousWasFullySynced], not on
/// every check while it stays fully synced.
SyncComputation computeSyncNotifications({
  required int pendingCount,
  required Set<String> rejectedOpIds,
  required Set<String> previousNotifiedFailureIds,
  required bool previousWasFullySynced,
}) {
  final toNotify = <AppNotification>[];

  final hasNewFailure = rejectedOpIds.any(
    (id) => !previousNotifiedFailureIds.contains(id),
  );
  if (hasNewFailure) {
    toNotify.add(
      const SyncResultAppNotification(outcome: SyncNotificationOutcome.failure),
    );
  }

  final isFullySynced = pendingCount == 0 && rejectedOpIds.isEmpty;
  if (isFullySynced && !previousWasFullySynced) {
    toNotify.add(
      const SyncResultAppNotification(outcome: SyncNotificationOutcome.success),
    );
  }

  return (
    toNotify: toNotify,
    nextNotifiedFailureIds: {...rejectedOpIds},
    nextWasFullySynced: isFullySynced,
  );
}
