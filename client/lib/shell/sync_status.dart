import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Connectivity/pending-change state shown by the header's sync-status pill
/// and the offline banner (FR-UX-2, #197).
enum SyncConnectivity { online, offline }

class SyncStatus {
  const SyncStatus({required this.connectivity, required this.pendingCount});

  final SyncConnectivity connectivity;
  final int pendingCount;

  bool get isOnline => connectivity == SyncConnectivity.online;
}

/// **Stub** (#197): reports a fixed "online, nothing pending" status so the
/// header pill and offline banner have something real to render against.
/// Wiring this to PowerSync's actual `PowerSyncDatabase.statusStream`
/// (connectivity + `hasSynced`/upload-queue depth for the pending count) is
/// #58 — this provider is the seam that issue is expected to replace/extend;
/// callers only depend on [SyncStatus], not on how it's produced.
final syncStatusProvider = Provider<SyncStatus>((ref) {
  return const SyncStatus(
    connectivity: SyncConnectivity.online,
    pendingCount: 0,
  );
});
