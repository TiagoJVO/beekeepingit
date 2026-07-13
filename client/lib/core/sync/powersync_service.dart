import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';

import '../auth/auth_controller.dart';
import 'connectivity_probe.dart';
import 'powersync_connector.dart';
import 'powersync_schema.dart';
import 'sync_gate.dart';

const _dbFilename = 'beekeepingit.db';

/// Opens the on-device PowerSync database (local SQLite over OPFS/IndexedDB on
/// web) and connects it to the backend via [BeekeepingitConnector] — gated by
/// [SyncGate] (FR-OF-3, sync.md §7.1): the first `connect()` call, and every
/// reconnect after the link drops, waits for a passing connectivity-quality
/// probe rather than firing on the mere presence of "online". Read after
/// login, so `fetchCredentials` has a valid access token to mint a sync token.
///
/// Exposes the live [BeekeepingitConnector] and [SyncGate] too (not just the
/// db): #58's manual "sync now" needs to bypass the gate and
/// disconnect()/connect() the *same* connector — re-creating one would drop
/// its request-level state for no reason and diverge from how `connect()` is
/// normally called once at startup.
final powerSyncProvider = FutureProvider<PowerSyncSession>((ref) async {
  final db = PowerSyncDatabase(schema: appSchema, path: _dbFilename);
  await db.initialize();

  final connector = BeekeepingitConnector(
    getAccessToken: () =>
        ref.read(authControllerProvider.notifier).accessToken(),
  );

  // Tracks the engine's own connectivity so a connect attempt is only ever
  // issued while actually disconnected — guards against the gate's own probe
  // loop and a concurrent manual "sync now" (SyncGate.requestSync) both
  // resolving to a connect() call around the same time.
  var connected = false;

  final gate = SyncGate(
    probe: HttpConnectivityProbe(),
    onGatePassed: () async {
      if (connected) return;
      await db.connect(connector: connector);
    },
  );

  // Re-arm the gate whenever the engine transitions from connected to
  // disconnected, so the *next* connect attempt is gated again instead of
  // being left to PowerSync's own unconditional retry (sync.md §7.1: the
  // gate governs "connect/flush", not just the very first attempt).
  final statusSub = db.statusStream.listen((status) {
    if (connected && !status.connected) {
      gate.rearm();
    }
    connected = status.connected;
  });

  gate.start();

  ref.onDispose(() async {
    await statusSub.cancel();
    gate.dispose();
    await db.disconnect();
    await db.close();
    connector.dispose();
  });
  return PowerSyncSession(db: db, connector: connector, gate: gate);
});

/// The open database plus the connector and gate it was wired with (see
/// [powerSyncProvider]'s doc comment for why all three are needed).
class PowerSyncSession {
  const PowerSyncSession({
    required this.db,
    required this.connector,
    required this.gate,
  });

  final PowerSyncDatabase db;
  final BeekeepingitConnector connector;
  final SyncGate gate;
}
