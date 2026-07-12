import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart' as ps;

import '../core/sync/powersync_service.dart';
import '../core/sync/sync_events.dart';

export '../core/sync/sync_events.dart' show SupersededChange;

/// Connectivity/pending-change state shown by the header's sync-status pill
/// and the offline banner (FR-UX-2, #197; wired to PowerSync in #58).
enum SyncConnectivity { online, offline }

class SyncStatus {
  const SyncStatus({
    required this.connectivity,
    required this.pendingCount,
    this.syncing = false,
    this.hasError = false,
  });

  final SyncConnectivity connectivity;
  final int pendingCount;

  /// An upload/download is in flight right now (drives the pill's "Syncing"
  /// state — sync.md §8's `syncing` per-record status, generalized to the
  /// connection as a whole for the header pill).
  final bool syncing;

  /// The last upload or download attempt errored and PowerSync is waiting to
  /// retry. The SDK owns the actual backoff timer (sync.md §7.1/§10); this
  /// just surfaces "a retry is pending" to the UI.
  final bool hasError;

  bool get isOnline => connectivity == SyncConnectivity.online;
}

/// Broadcasts a [SupersededChange] every time [BeekeepingitConnector.uploadData]
/// observes a `superseded` result in the batch-apply response (sync.md §5.2/
/// §8). A [StreamProvider.autoDispose] over the connector's own broadcast
/// stream — the shell listens to it (via `ref.listen`) to show a one-shot,
/// non-blocking toast; it isn't state a widget should render synchronously,
/// so nothing depends on its `AsyncValue` beyond that listener.
final supersededNotificationProvider =
    StreamProvider.autoDispose<SupersededChange>((ref) async* {
      final session = await ref.watch(powerSyncProvider.future);
      yield* session.connector.supersededChanges;
    });

/// Real connectivity + pending-change count, sourced from
/// [ps.PowerSyncDatabase.statusStream] (connectivity/uploading/error) and
/// [ps.PowerSyncDatabase.getUploadQueueStats] (pending count).
///
/// `pendingCount` is re-read on every status change rather than derived from
/// the status event itself: the `powersync` package's `SyncStatus` doesn't
/// carry queue depth, only connectivity/upload-in-progress/error flags. The
/// extra query (`SELECT count(*) FROM ps_crud`) is cheap and only runs on
/// transitions, not polled.
///
/// Internal — [syncStatusProvider] below is the public seam callers use; it
/// unwraps the [AsyncValue] with a sane default so widgets (and #197's
/// existing header pill/offline banner, which predate PowerSync being wired
/// up) can keep depending on a plain [SyncStatus], not an [AsyncValue].
final _syncStatusStreamProvider = StreamProvider<SyncStatus>((ref) async* {
  final session = await ref.watch(powerSyncProvider.future);
  final db = session.db;

  Future<SyncStatus> toStatus(ps.SyncStatus s) async {
    final queue = await db.getUploadQueueStats();
    return SyncStatus(
      connectivity: s.connected
          ? SyncConnectivity.online
          : SyncConnectivity.offline,
      pendingCount: queue.count,
      syncing: s.uploading || s.downloading,
      hasError: s.anyError != null,
    );
  }

  yield await toStatus(db.currentStatus);
  yield* db.statusStream.asyncMap(toStatus);
});

/// Public seam (#197's stub, replaced in #58): connectivity + pending-count
/// state for the header pill and offline banner. Reports **offline,
/// nothing pending** while the PowerSync database is still opening (or
/// errored) — a device that hasn't finished bootstrapping the sync engine
/// yet is not meaningfully "online" from the user's point of view, and this
/// avoids widgets needing to handle a loading/error `AsyncValue` for what
/// they treat as simple, always-available state.
final syncStatusProvider = Provider<SyncStatus>((ref) {
  final async = ref.watch(_syncStatusStreamProvider);
  return async.value ??
      const SyncStatus(connectivity: SyncConnectivity.offline, pendingCount: 0);
});

/// One-shot manual "sync now" (the prototype's "Sincronizar agora";
/// sync.md §7.1's override — "a user-triggered sync now always attempts
/// once, gate or no gate"). PowerSync has no standalone "flush now" call;
/// the documented way to force an immediate reconnect + upload/download
/// attempt is a disconnect/connect cycle on the *same* connector, which
/// re-invokes `fetchCredentials`/`uploadData` right away instead of waiting
/// on the SDK's own retry backoff.
final syncNowProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final session = await ref.read(powerSyncProvider.future);
    await session.db.disconnect();
    await session.db.connect(connector: session.connector);
  };
});
