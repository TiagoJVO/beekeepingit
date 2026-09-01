import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:powersync/powersync.dart';

import '../../features/settings/sync_settings_repository.dart';
import '../auth/auth_controller.dart';
import 'connectivity_probe.dart';
import 'connectivity_signal.dart';
import 'local_store.dart';
import 'powersync_connector.dart';
import 'powersync_local_store.dart';
import 'powersync_schema.dart';
import 'sync_gate.dart';

const _dbFilename = 'beekeepingit.db';

/// Test-only seam over the single step in [powerSyncProvider] that needs a
/// real device: constructing and initializing the on-device
/// [PowerSyncDatabase]. When non-null, [_openDatabase] calls this instead.
///
/// Why it exists (#286): `PowerSyncDatabase`'s *constructor* immediately
/// registers the database path in PowerSync's process-wide active-instance
/// registry (`ActiveDatabaseGroup`), and only `close()` deregisters it —
/// after awaiting the same initialization the constructor kicked off. Under
/// `testWidgets` that initialization never resolves: its real disk/isolate
/// I/O doesn't progress under the widget binding's fake-async clock (probed
/// locally: `initialize()` completes in a plain `test()`, and is still
/// pending after 2s of pumped time inside `testWidgets`). So the provider
/// body below stays suspended right here, never reaches its `ref.onDispose`,
/// and the registration is never released — the same outcome an *erroring*
/// open would have. Every widget test rendering a screen that watches
/// `syncStatusProvider` (or any repository provider) therefore leaked one
/// registration, and PowerSync logged "Multiple instances for the same
/// database have been detected" from the second one onward — hundreds of
/// lines of noise across an otherwise green `flutter test` run.
///
/// `test/flutter_test_config.dart` sets this once for the whole suite to a
/// future that never completes, which is what widget tests already observe
/// today (`powerSyncProvider` stays pending) minus the leaked database
/// handle and the stray on-disk `beekeepingit.db`. A widget test that needs
/// a *resolved* sync session still overrides the Riverpod providers it
/// depends on, as `account_screen_test.dart`/`app_shell_test.dart` already
/// do; awaiting `powerSyncProvider` itself without an override hangs until
/// the test times out.
///
/// Never set outside tests — production leaves it null and opens the real
/// database below.
@visibleForTesting
Future<PowerSyncDatabase> Function()? debugOpenPowerSyncDatabase;

/// Opens (and initializes) the on-device database, honoring the
/// [debugOpenPowerSyncDatabase] test seam.
Future<PowerSyncDatabase> _openDatabase() async {
  final openOverride = debugOpenPowerSyncDatabase;
  if (openOverride != null) return openOverride();

  final db = PowerSyncDatabase(schema: appSchema, path: _dbFilename);
  await db.initialize();
  return db;
}

/// Serializes a sequence of async teardowns against the *next* caller's
/// startup — the general pattern behind [powerSyncProvider]'s dispose-race
/// fix (HIGH finding: Riverpod's `ref.onDispose` is `void Function()`, so it
/// never awaits whatever Future a callback returns; without this, a rebuild
/// soon after disposal — logout → fresh login, or the #125 membership-loss
/// purge's `ref.invalidate` — could open a new [PowerSyncDatabase] against
/// the same on-disk file while the previous one's `db.close()` is still in
/// flight, producing PowerSync's own "Multiple instances for the same
/// database" warning, per its own docs "unexpected results").
///
/// `@visibleForTesting` and standalone (no PowerSync/Riverpod dependency) so
/// the actual serialization logic is unit-testable with fake delayed
/// Futures, independent of a real PowerSyncDatabase or widget lifecycle.
@visibleForTesting
class TeardownGuard {
  Future<void>? _pending;

  /// Awaits any teardown registered by a previous [registerTeardown] call
  /// that hasn't finished yet. Resolves immediately if nothing is pending.
  Future<void> waitForPrior() => _pending ?? Future.value();

  /// Registers [teardown] as the new "in flight" teardown for the *next*
  /// [waitForPrior] call to await. Fire-and-forget by design — [teardown]
  /// starts running immediately but is never awaited here, mirroring the
  /// synchronous-callback constraint of Riverpod's `ref.onDispose` this
  /// exists to work around.
  void registerTeardown(Future<void> Function() teardown) {
    _pending = teardown();
  }
}

/// Process-wide by necessity: the race [TeardownGuard] guards against is
/// between *separate* [powerSyncProvider] instances (e.g. a disposed
/// ProviderScope followed by a fresh one), which by definition don't share a
/// `ref` to hang shared state off of.
final _teardownGuard = TeardownGuard();

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
  // Serialize against the previous instance's teardown (see [TeardownGuard]'s
  // doc) — without this, a rebuild soon after disposal (logout → fresh
  // login, or the #125 membership-loss purge's `ref.invalidate`) could open a
  // new [PowerSyncDatabase] against the same on-disk file while the old
  // one's `db.close()` is still in flight.
  await _teardownGuard.waitForPrior();

  final db = await _openDatabase();

  final connector = BeekeepingitConnector(
    getAccessToken: () =>
        ref.read(authControllerProvider.notifier).accessToken(),
  );
  final probe = HttpConnectivityProbe();

  // Tracks the engine's own connectivity so a connect attempt is only ever
  // issued while actually disconnected — guards against the gate's own probe
  // loop and a concurrent manual "sync now" (SyncGate.requestSync) both
  // resolving to a connect() call around the same time.
  var connected = false;

  final gate = SyncGate(
    probe: probe,
    onGatePassed: () async {
      if (connected) return;
      await db.connect(connector: connector);
    },
    // The browser's `online` event, so a reconnect cuts a pending backoff
    // short and re-probes at once instead of leaving a queued offline write
    // unflushed for up to the gate's ~2-min max backoff (#240, FR-OF-3). A
    // hint only — the probe still decides whether the link is usable.
    onConnectivityRestored: createConnectivitySignal().onRestored,
  );

  // Re-arm the gate whenever the engine transitions from connected to
  // disconnected, so the *next* connect attempt is gated again instead of
  // being left to PowerSync's own unconditional retry (sync.md §7.1: the
  // gate governs "connect/flush", not just the very first attempt). Split
  // into [rearmGateOnDisconnect] (HIGH finding: this wiring previously had
  // zero test coverage) so the transition logic is unit-testable with a fake
  // `bool` stream, independent of a real PowerSyncDatabase.
  //
  // Gated by the auto-sync setting (FR-ST-1, #81): re-arming unconditionally
  // here would undo a user's "auto-sync off" choice the moment a manual
  // "sync now" (`syncNowProvider` → `SyncGate.requestSync`, which bypasses
  // the gate entirely) connects and then later disconnects — this is the one
  // other place besides the toggle listener below that can re-enable the
  // probe loop, so it must consult the same setting.
  final statusSub = rearmGateOnDisconnect(
    connectedStream: db.statusStream.map((status) => status.connected),
    rearm: () => applyAutoSyncSetting(
      enabled: ref.read(autoSyncEnabledProvider),
      gate: gate,
    ),
    onConnectedChanged: (isConnected) => connected = isConnected,
  );

  // Initial gate start, honoring the persisted auto-sync setting (FR-ST-1,
  // #81) — defaults to `true` (SyncSettingsRepository), matching the
  // unconditional `gate.start()` this replaces for anyone who never visits
  // the settings screen.
  applyAutoSyncSetting(enabled: ref.read(autoSyncEnabledProvider), gate: gate);

  // Live toggle (AC: "changing a setting takes effect without requiring a
  // reinstall"): `ref.listen`, not `ref.watch` — this must NOT rebuild (and
  // thereby tear down/reopen) the whole PowerSync session on every toggle,
  // only react to it.
  final autoSyncSub = ref.listen<bool>(autoSyncEnabledProvider, (_, enabled) {
    applyAutoSyncSetting(enabled: enabled, gate: gate);
  });

  // Synchronous by construction — Riverpod's `ref.onDispose` is a
  // `void Function()` and never awaits a Future a callback returns (HIGH
  // finding). [TeardownGuard.registerTeardown] starts the teardown
  // immediately but doesn't await it either; it's stashed so the *next*
  // [powerSyncProvider] instance can await it before opening a new database.
  ref.onDispose(() {
    autoSyncSub.close();
    _teardownGuard.registerTeardown(() async {
      await statusSub.cancel();
      gate.dispose();
      probe.dispose();
      await db.disconnect();
      await db.close();
      connector.dispose();
    });
  });
  return PowerSyncSession(db: db, connector: connector, gate: gate);
});

/// Applies the auto-sync setting (`features/settings/sync_settings_repository
/// .dart`, FR-ST-1/#81) to [gate]: enabling (re-)arms the probe loop —
/// [SyncGate.rearm] is safe to call whether the gate is freshly constructed,
/// already running, or previously stopped by this same function — and
/// disabling stops it, canceling any pending backoff timer so no further
/// automatic connect attempt is made. This is the sole place the setting's
/// two possible values are translated into gate calls, so both wiring points
/// above ([powerSyncProvider]'s initial setup and its live toggle listener)
/// share one tested decision.
///
/// Never disconnects an already-connected engine (`PowerSyncDatabase.connect`
/// is not [gate]'s to tear down, and an in-flight atomic push must not be
/// interrupted — FR-OF-2): disabling auto-sync only prevents *future*
/// automatic (re)connect attempts, matching FR-OF-3's framing of the gate as
/// an optimization over *when* to attempt a sync, never a hard block on an
/// active one.
///
/// `@visibleForTesting` — production only calls this from
/// [powerSyncProvider].
@visibleForTesting
void applyAutoSyncSetting({required bool enabled, required SyncGate gate}) {
  if (enabled) {
    gate.rearm();
  } else {
    gate.stop();
  }
}

/// Re-arms [gate]'s rearm callback the moment [connectedStream] transitions
/// from `true` to `false` — the whole reason `db.statusStream` is subscribed
/// to in [powerSyncProvider] (sync.md §7.1: the gate governs *every*
/// reconnect, not just the first). Split out of the provider body — which
/// only wires this to [PowerSyncDatabase.statusStream]/[SyncGate.rearm] via
/// [onConnectedChanged] — so the transition logic itself is unit-testable
/// with a fake `Stream<bool>` (mirrors `handleUploadResponse`'s extraction in
/// powersync_connector.dart). [onConnectedChanged] reports every observed
/// value so the caller can keep its own "are we connected right now"
/// bookkeeping (used by `onGatePassed`'s guard) off a single subscription,
/// rather than listening to the same stream twice.
///
/// `@visibleForTesting` — production only ever calls this from
/// [powerSyncProvider].
@visibleForTesting
StreamSubscription<bool> rearmGateOnDisconnect({
  required Stream<bool> connectedStream,
  required void Function() rearm,
  required void Function(bool connected) onConnectedChanged,
}) {
  var wasConnected = false;
  return connectedStream.listen((isConnected) {
    if (wasConnected && !isConnected) rearm();
    wasConnected = isConnected;
    onConnectedChanged(isConnected);
  });
}

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

/// The [LocalStoreEngine] seam (NFR-ARC-2, #55) over the same database
/// [powerSyncProvider] opens — so callers that only need read/write/`clear()`
/// (e.g. `AuthController.logout()`'s local-data wipe, #125) depend on the
/// engine-agnostic interface instead of reaching for [PowerSyncSession.db]
/// and wrapping it themselves. Feature repositories build their own
/// [PowerSyncLocalStore] today (`apiaries_repository.dart`) for symmetry with
/// their existing wiring; this provider exists for `core/` callers that sit
/// above any one feature.
final localStoreProvider = FutureProvider<LocalStoreEngine>((ref) async {
  final session = await ref.watch(powerSyncProvider.future);
  return PowerSyncLocalStore(session.db);
});
