import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shell/sync_status.dart';
import '../sync/sync_rejected_repository.dart';
import '../todos/todos_repository.dart';
import 'notification_checker.dart';
import 'notification_dedup_store.dart';
import 'notification_feed_provider.dart';
import 'notification_preferences_repository.dart';

/// Seam for [NotificationDedupStore] (mirrors `notificationPreferencesRepositoryProvider`'s
/// own rationale) — lets tests substitute an in-memory-backed store without
/// a real platform [LocalPrefs].
final notificationDedupStoreProvider = Provider<NotificationDedupStore>(
  (ref) => NotificationDedupStore(),
);

/// Wires the app-open/foreground notification check (#82, D-24): runs once
/// when first watched (the app's own cold start — `app.dart` watches this
/// alongside `membershipLossPurgeProvider`) and again every time the app
/// returns to the foreground. There is no background timer/poll in the PWA
/// phase (D-24) — [AppLifecycleListener.onResume] is the only re-trigger.
///
/// A thin Riverpod adapter only: all the actual detection/gating logic
/// lives in [NotificationChecker] (`notification_checker.dart`), which is
/// tested directly against fakes with no Riverpod involved. This file's own
/// job is gathering the current facts from the app's real data sources
/// (the org-wide todos list, the device's own sync state) and publishing
/// the result to [notificationFeedProvider] for `shell/app_shell.dart` to
/// display.
final notificationCheckProvider = Provider<void>((ref) {
  // Establish an active subscription to both source providers up front,
  // synchronously, during THIS provider's own build — not left to the
  // bare `ref.read(...future)` calls inside the async `runCheck` closure
  // below. [todosStreamProvider] is `.autoDispose` (org-scoped, torn down
  // when no screen needs it) and would otherwise risk being torn down
  // before it ever emits (e.g. the very first cold-start check, before the
  // Todos tab has mounted); a bare `.future` read with no prior listener
  // proved unreliable for [syncRejectedOpsProvider] too. A no-op
  // `ref.listen` keeps each alive for as long as THIS provider is watched
  // (the whole app session, per `app.dart`) without making this provider
  // itself rebuild on every todos/rejection change — unlike `ref.watch`,
  // which would re-run this whole setup (and re-register the lifecycle
  // listener) on every update.
  ref.listen(todosStreamProvider, (_, __) {});
  ref.listen(syncRejectedOpsProvider, (_, __) {});

  Future<void> runCheck() async {
    try {
      final todos = await ref.read(todosStreamProvider.future);
      final status = ref.read(syncStatusProvider);
      final rejected = await ref.read(syncRejectedOpsProvider.future);

      final checker = NotificationChecker(
        dedupStore: ref.read(notificationDedupStoreProvider),
        preferences: ref.read(notificationPreferencesRepositoryProvider),
      );
      final notifications = checker.check(
        todos: todos,
        today: DateTime.now(),
        pendingCount: status.pendingCount,
        rejectedOpIds: rejected.map((op) => op.id).toSet(),
      );

      ref.read(notificationFeedProvider.notifier).publish(notifications);
    } catch (_) {
      // Best-effort (mirrors `core/sync/local_data_purge.dart`'s own
      // `_purge` rationale): a failed check — no organization/PowerSync
      // session yet, a local-store read error — must never crash the app
      // over a background consistency sweep. The next app-open/resume
      // tries again.
    }
  }

  final listener = AppLifecycleListener(onResume: () => unawaited(runCheck()));
  ref.onDispose(listener.dispose);

  unawaited(runCheck()); // the app's own cold start counts as "opened".
});
