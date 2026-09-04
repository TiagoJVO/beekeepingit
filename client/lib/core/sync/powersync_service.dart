import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:powersync/powersync.dart';

import '../../features/organization/organization_repository.dart';
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

  // Read into a local rather than handing the connector a `ref` to re-read
  // (#622): [BeekeepingitConnector] outlives this provider — PowerSync can
  // still call `fetchCredentials` during the fire-and-forget teardown
  // ([TeardownGuard]) — and a connector holding a `ref` would tie a
  // long-lived, engine-owned object to a Riverpod lifecycle it doesn't
  // control. The `ref.listen` further down keeps this local current for the
  // whole live session; once that subscription is closed on dispose the local
  // simply freezes at its last value, which is the right answer for a session
  // being torn down. (No claim of a ref-free teardown window: `getAccessToken`
  // just below, and the rearm callback further down, do read `ref` — this path
  // just doesn't add another one that would have to.)
  var hasMembership = ref.read(hasOrganizationProvider);

  final connector = BeekeepingitConnector(
    getAccessToken: () =>
        ref.read(authControllerProvider.notifier).accessToken(),
    hasMembership: () => hasMembership,
  );
  final probe = HttpConnectivityProbe();

  // Tracks the engine's own connectivity so a connect attempt is only ever
  // issued while actually disconnected — guards against the gate's own probe
  // loop and a concurrent manual "sync now" (SyncGate.requestSync) both
  // resolving to a connect() call around the same time.
  var connected = false;

  final gate = SyncGate(
    probe: probe,
    onGatePassed: () => connectIfAllowed(
      alreadyConnected: connected,
      hasMembership: hasMembership,
      connect: () => db.connect(connector: connector),
    ),
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
  // Gated by the same preconditions as everywhere else (FR-ST-1 #81, #622):
  // re-arming unconditionally here would undo a user's "auto-sync off" choice
  // the moment a manual "sync now" (`syncNowProvider` → `SyncGate.requestSync`,
  // which bypasses the gate entirely) connects and then later disconnects —
  // this is the one other place besides the listeners below that can re-enable
  // the probe loop, so it must consult the same answers.
  final statusSub = rearmGateOnDisconnect(
    connectedStream: db.statusStream.map((status) => status.connected),
    rearm: () => applySyncPreconditions(
      autoSyncEnabled: ref.read(autoSyncEnabledProvider),
      hasMembership: hasMembership,
      gate: gate,
    ),
    onConnectedChanged: (isConnected) => connected = isConnected,
  );

  // Initial gate start, honoring the persisted auto-sync setting (FR-ST-1,
  // #81) — defaults to `true` (SyncSettingsRepository), matching the
  // unconditional `gate.start()` this replaces for anyone who never visits
  // the settings screen — and the membership precondition (#622).
  applySyncPreconditions(
    autoSyncEnabled: ref.read(autoSyncEnabledProvider),
    hasMembership: hasMembership,
    gate: gate,
  );

  // Live toggle (AC: "changing a setting takes effect without requiring a
  // reinstall"): `ref.listen`, not `ref.watch` — this must NOT rebuild (and
  // thereby tear down/reopen) the whole PowerSync session on every toggle,
  // only react to it.
  final autoSyncSub = ref.listen<bool>(autoSyncEnabledProvider, (_, enabled) {
    applySyncPreconditions(
      autoSyncEnabled: enabled,
      hasMembership: hasMembership,
      gate: gate,
    );
  });

  // The membership edge (#622). `false → true` is the one that matters: it is
  // emitted the instant `POST /v1/organizations` returns 201 (the onboarding
  // form's `OrganizationController.submit` sets `AsyncData(created)`), and
  // re-applying the preconditions here is what starts sync there and then —
  // without it the session opened during onboarding would stay gate-stopped
  // until the app was reloaded. `true → false` (the #125 membership loss) is
  // the mirror image: stop probing rather than retry a session the server has
  // stopped issuing tokens for.
  //
  // `ref.listen`, not `ref.watch`, for the same reason as the toggle above —
  // a watch would tear down and reopen the whole PowerSyncDatabase on every
  // membership transition, which is precisely the churn this issue is about.
  // The composed reaction itself lives in [membershipChangeHandler] (same
  // rationale as [rearmGateOnDisconnect]'s extraction: this wiring is what
  // decides whether an onboarded user syncs at all, so it is unit-tested
  // rather than inlined here).
  final onMembershipChanged = membershipChangeHandler(
    rememberMembership: (value) => hasMembership = value,
    autoSyncEnabled: () => ref.read(autoSyncEnabledProvider),
    gate: gate,
  );
  final membershipSub = ref.listen<bool>(
    hasOrganizationProvider,
    (_, has) => onMembershipChanged(has),
  );

  // Synchronous by construction — Riverpod's `ref.onDispose` is a
  // `void Function()` and never awaits a Future a callback returns (HIGH
  // finding). [TeardownGuard.registerTeardown] starts the teardown
  // immediately but doesn't await it either; it's stashed so the *next*
  // [powerSyncProvider] instance can await it before opening a new database.
  ref.onDispose(() {
    autoSyncSub.close();
    membershipSub.close();
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

/// Applies the two preconditions of an *automatic* sync attempt to [gate].
/// Both must hold to (re-)arm the probe loop — [SyncGate.rearm] is safe to
/// call whether the gate is freshly constructed, already running, or
/// previously stopped by this same function — and either failing stops it,
/// canceling any pending backoff timer so no further automatic connect
/// attempt is made:
///
/// - [autoSyncEnabled] — the user's own auto-sync setting
///   (`features/settings/sync_settings_repository.dart`, FR-ST-1/#81);
/// - [hasMembership] — whether the caller belongs to an organization at all
///   (`hasOrganizationProvider`, FR-ONB-2/D-3). Until they do there is nothing
///   to replicate and nothing that could authenticate: the sync token is
///   org-scoped, so every connect attempt burned a `GET /v1/sync/token` the
///   server answers `403` by design (#622 — ~8 consecutive console errors on
///   the create-organization step). Probing the link for a session that
///   cannot connect is exactly the churn FR-OF-3's gate exists to avoid.
///
/// This is the sole place those two answers are translated into gate calls,
/// so all four wiring points above ([powerSyncProvider]'s initial setup, its
/// auto-sync listener, its membership listener, and `rearmGateOnDisconnect`'s
/// callback) share one tested decision.
///
/// Never disconnects an already-connected engine (`PowerSyncDatabase.connect`
/// is not [gate]'s to tear down, and an in-flight atomic push must not be
/// interrupted — FR-OF-2): a failing precondition only prevents *future*
/// automatic (re)connect attempts, matching FR-OF-3's framing of the gate as
/// an optimization over *when* to attempt a sync, never a hard block on an
/// active one. The membership dimension keeps that shape deliberately — the
/// authoritative membership check is the server's, on every request; this only
/// spares the client a request that cannot succeed.
///
/// `@visibleForTesting` — production only calls this from
/// [powerSyncProvider].
@visibleForTesting
void applySyncPreconditions({
  required bool autoSyncEnabled,
  required bool hasMembership,
  required SyncGate gate,
}) {
  if (autoSyncEnabled && hasMembership) {
    gate.rearm();
  } else {
    gate.stop();
  }
}

/// The decision [SyncGate]'s `onGatePassed` callback makes: connect, or don't.
/// [connect] runs only when the engine is not [alreadyConnected] **and**
/// [hasMembership] holds.
///
/// - [alreadyConnected] guards against the gate's own probe loop and a
///   concurrent manual "sync now" ([SyncGate.requestSync]) both resolving to a
///   connect around the same time; `PowerSyncDatabase.connect` is not
///   something to stack on a live engine.
/// - [hasMembership] is the last word before connecting (#622). It is not
///   redundant with [applySyncPreconditions]: [SyncGate.requestSync] invokes
///   this callback **directly**, bypassing the probe loop and therefore the
///   generation check that retires a stopped loop — so a `gate.stop()` from
///   the membership listener cannot reach a request already in flight through
///   that path. Connecting without a membership is not harmless: the connector
///   answers `fetchCredentials` with `null`, which parks PowerSync in a
///   `CredentialsException` retry loop (powersync_core's
///   `streaming_sync.dart`) rather than leaving it cleanly disconnected.
///
/// Awaits [connect] so the gate's callback doesn't resolve before the engine
/// has actually been asked.
///
/// `@visibleForTesting` and free of PowerSync/Riverpod types — production only
/// calls it from [powerSyncProvider]'s `onGatePassed` (same extraction
/// rationale as [rearmGateOnDisconnect]).
@visibleForTesting
Future<void> connectIfAllowed({
  required bool alreadyConnected,
  required bool hasMembership,
  required Future<void> Function() connect,
}) async {
  if (alreadyConnected) return;
  if (!hasMembership) return;
  await connect();
}

/// Builds the callback [powerSyncProvider] hands to
/// `ref.listen(hasOrganizationProvider, ...)` — the membership edge (#622) as
/// one testable decision instead of a closure inlined in the provider body.
///
/// On every membership change it does two things, in this order:
///
/// 1. [rememberMembership] — updates the provider's local, which the
///    connector's synchronous `hasMembership` closure and
///    [connectIfAllowed] both read. First, so those two never observe a
///    staler answer than [gate] does;
/// 2. [applySyncPreconditions] — re-applies both preconditions, which is what
///    starts the probe loop on the `false → true` edge (`POST
///    /v1/organizations` returning 201: sync begins there and then, with no
///    reload) and stops it on `true → false` (the #125 membership loss).
///
/// [autoSyncEnabled] is a closure, not a bool: the listener is wired once per
/// session and must read the user's *current* setting on each change, not the
/// one that happened to be in effect when the session opened.
///
/// `@visibleForTesting` — production only calls this from [powerSyncProvider].
@visibleForTesting
void Function(bool) membershipChangeHandler({
  required void Function(bool) rememberMembership,
  required bool Function() autoSyncEnabled,
  required SyncGate gate,
}) {
  return (hasMembership) {
    rememberMembership(hasMembership);
    applySyncPreconditions(
      autoSyncEnabled: autoSyncEnabled(),
      hasMembership: hasMembership,
      gate: gate,
    );
  };
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
