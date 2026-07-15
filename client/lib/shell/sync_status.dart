import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:powersync/powersync.dart' as ps;

import '../core/sync/powersync_service.dart';
import '../core/sync/sync_events.dart';
import '../core/sync/sync_gate.dart';

export '../core/sync/sync_events.dart' show SupersededChange, RejectedChange;
export '../core/sync/sync_gate.dart' show SyncGateState;

/// Connectivity/pending-change state shown by the header's sync-status pill
/// and the offline banner (FR-UX-2, #197; wired to PowerSync in #58).
enum SyncConnectivity { online, offline }

class SyncStatus {
  const SyncStatus({
    required this.connectivity,
    required this.pendingCount,
    this.syncing = false,
    this.hasError = false,
    this.gateState = SyncGateState.passed,
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

  /// The connection-quality gate's current state (FR-OF-3, sync.md §7.1,
  /// #55). Added additively — existing `connectivity`/`syncing`/`hasError`
  /// consumers are unaffected; a caller that wants to show "waiting for
  /// better signal" checks [isWaitingForSignal].
  final SyncGateState gateState;

  bool get isOnline => connectivity == SyncConnectivity.online;

  /// The gate is backing off after a failed probe — the device has *some*
  /// connectivity signal but the engine is deliberately not attempting to
  /// connect/flush yet (sync.md §7.1). Manual "sync now" always bypasses
  /// this (`syncNowProvider`).
  bool get isWaitingForSignal => gateState == SyncGateState.waitingForSignal;
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

/// Broadcasts a [RejectedChange] every time [BeekeepingitConnector.uploadData]
/// permanently rejects an offline write (a validation-class `4xx`; sync.md §8's
/// `rejected` state, D-12). The shell listens (via `ref.listen`) to show a
/// one-shot, non-blocking toast routing to the needs-fix list — the durable
/// record lives in the `sync_rejected_ops` dead-letter (read via
/// `syncRejectedOpsProvider`), so this stream is purely the notification, like
/// [supersededNotificationProvider].
final rejectedNotificationProvider = StreamProvider.autoDispose<RejectedChange>(
  (ref) async* {
    final session = await ref.watch(powerSyncProvider.future);
    yield* session.connector.rejectedChanges;
  },
);

/// Real connectivity + pending-change count, sourced from
/// [ps.PowerSyncDatabase.statusStream] (connectivity/uploading/error),
/// [ps.PowerSyncDatabase.getUploadQueueStats] (pending count), and
/// [SyncGate.stateStream] (FR-OF-3's "waiting for better signal" state, #55).
///
/// `pendingCount` is re-read on every status change rather than derived from
/// the status event itself: the `powersync` package's `SyncStatus` doesn't
/// carry queue depth, only connectivity/upload-in-progress/error flags. The
/// extra query (`SELECT count(*) FROM ps_crud`) is cheap and only runs on
/// transitions, not polled.
///
/// The engine's status and the gate's state change independently (a probe
/// can fail while the engine is still reporting its last-known connectivity,
/// and vice versa), so this listens to **both** streams and re-emits a
/// combined [SyncStatus] whenever either changes — rather than pulling in a
/// stream-combining package for two sources.
///
/// Internal — [syncStatusProvider] below is the public seam callers use; it
/// unwraps the [AsyncValue] with a sane default so widgets (and #197's
/// existing header pill/offline banner, which predate PowerSync being wired
/// up) can keep depending on a plain [SyncStatus], not an [AsyncValue].
final _syncStatusStreamProvider = StreamProvider<SyncStatus>((ref) async* {
  final session = await ref.watch(powerSyncProvider.future);
  final db = session.db;
  final gate = session.gate;

  yield* combineSyncStatus(
    engineStatus: db.statusStream.map(_engineConnectivityOf),
    initialEngineStatus: _engineConnectivityOf(db.currentStatus),
    gateState: gate.stateStream,
    initialGateState: gate.state,
    pendingCount: () async => (await db.getUploadQueueStats()).count,
  );
});

/// The subset of [ps.SyncStatus] the combine step actually needs, as a plain
/// record rather than the real PowerSync type — whose constructor is
/// `@internal` (application code must never construct one directly) — so
/// [combineSyncStatus] is unit-testable with a fake `Stream` of these,
/// independent of a real [ps.PowerSyncDatabase].
typedef EngineConnectivity = ({
  bool connected,
  bool uploading,
  bool downloading,
  Object? anyError,
});

EngineConnectivity _engineConnectivityOf(ps.SyncStatus s) => (
  connected: s.connected,
  uploading: s.uploading,
  downloading: s.downloading,
  anyError: s.anyError,
);

/// Combines the engine's connectivity/upload-in-progress stream and the
/// gate's own state stream into a single [SyncStatus] stream — the actual
/// combining logic of [_syncStatusStreamProvider], split out so it's
/// unit-testable with fake streams and a fake `pendingCount` supplier (HIGH
/// finding: this provider body previously had zero test coverage; mirrors
/// `handleUploadResponse`'s extraction in powersync_connector.dart).
///
/// [pendingCount] is invoked to (re)read the upload-queue depth every time
/// either input changes — see [_syncStatusStreamProvider]'s original doc for
/// why (the `powersync` package's own `SyncStatus` doesn't carry queue
/// depth). Emits one initial [SyncStatus] right away from
/// [initialEngineStatus]/[initialGateState], same as the original
/// `unawaited(emit())` behavior. Cancelling the returned stream's
/// subscription cancels both [engineStatus] and [gateState] subscriptions.
///
/// `@visibleForTesting` — production only ever calls this from
/// [_syncStatusStreamProvider].
@visibleForTesting
Stream<SyncStatus> combineSyncStatus({
  required Stream<EngineConnectivity> engineStatus,
  required EngineConnectivity initialEngineStatus,
  required Stream<SyncGateState> gateState,
  required SyncGateState initialGateState,
  required Future<int> Function() pendingCount,
}) {
  final controller = StreamController<SyncStatus>();
  var lastEngine = initialEngineStatus;
  var lastGate = initialGateState;

  Future<void> emit() async {
    if (controller.isClosed) return;
    final count = await pendingCount();
    if (controller.isClosed) return;
    controller.add(
      SyncStatus(
        connectivity: lastEngine.connected
            ? SyncConnectivity.online
            : SyncConnectivity.offline,
        pendingCount: count,
        syncing: lastEngine.uploading || lastEngine.downloading,
        hasError: lastEngine.anyError != null,
        gateState: lastGate,
      ),
    );
  }

  final engineSub = engineStatus.listen((s) {
    lastEngine = s;
    emit();
  });
  final gateSub = gateState.listen((s) {
    lastGate = s;
    emit();
  });

  controller.onCancel = () async {
    await engineSub.cancel();
    await gateSub.cancel();
  };

  unawaited(emit());

  return controller.stream;
}

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
/// once, gate or no gate"). Bypasses [SyncGate] entirely via
/// [SyncGate.requestSync] rather than probing first — the beekeeper on the
/// hill may know things the probe doesn't (§7.1). PowerSync has no
/// standalone "flush now" call; the documented way to force an immediate
/// reconnect + upload/download attempt is a disconnect/connect cycle on the
/// *same* connector, which re-invokes `fetchCredentials`/`uploadData` right
/// away instead of waiting on the SDK's own retry backoff.
final syncNowProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    final session = await ref.read(powerSyncProvider.future);
    await session.db.disconnect();
    await session.gate.requestSync();
  };
});
