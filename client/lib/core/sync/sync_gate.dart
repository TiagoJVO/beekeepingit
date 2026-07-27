import 'dart:async';

import 'connectivity_probe.dart';

/// What the gate is doing right now — surfaced additively through
/// [SyncStatus] (`shell/sync_status.dart`) so the header pill / account
/// screen can show a "waiting for better signal" state without any change to
/// their existing online/offline/syncing vocabulary.
enum SyncGateState {
  /// A probe is in flight, or about to run immediately (first attempt / after
  /// [SyncGate.rearm]).
  probing,

  /// The last probe passed and the connect callback has been invoked — the
  /// engine now owns its own connection lifecycle until it goes offline
  /// again (see [SyncGate.rearm]).
  passed,

  /// The last probe failed; waiting out an exponential backoff before the
  /// next attempt (sync.md §7.1: "failed probes... back off exponentially,
  /// so marginal-signal windows don't churn the radio and battery").
  waitingForSignal,
}

/// The connection-quality sync gate (FR-OF-3, sync.md §7.1): "only connect/
/// flush when a quality probe passes (~usable 3G), with exponential
/// backoff." Sits **outside** the sync-publication contract (§5) and purely
/// in front of the engine's connect lifecycle, so it survives an engine swap
/// unchanged (NFR-ARC-2) — it depends only on [ConnectivityProbe] and a
/// plain `Future<void> Function()` connect callback, never on PowerSync
/// types.
///
/// The gate is an **optimization, never a correctness mechanism** (§7.1): an
/// interrupted push is already safe (atomic per push, idempotent
/// forward-retry), so the gate exists only to make attempting one *rare*
/// under marginal signal — it never blocks the manual override
/// ([requestSync]) and never blocks local reads/writes, which always go
/// through the local store regardless of connectivity (FR-OF-1).
class SyncGate {
  SyncGate({
    required ConnectivityProbe probe,
    required Future<void> Function() onGatePassed,
    this.initialBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(minutes: 2),
    this.backoffMultiplier = 2,
  }) : _probe = probe,
       _onGatePassed = onGatePassed;

  final ConnectivityProbe _probe;
  final Future<void> Function() _onGatePassed;

  /// Backoff tuning (sync.md §7.1: "thresholds are configurable... with
  /// defaults tuned in EPIC-06 field testing, not hard-coded guesses"). These
  /// are the starting defaults; field testing may adjust them without an
  /// interface change.
  final Duration initialBackoff;
  final Duration maxBackoff;
  final num backoffMultiplier;

  final _stateController = StreamController<SyncGateState>.broadcast();
  Stream<SyncGateState> get stateStream => _stateController.stream;

  SyncGateState _state = SyncGateState.probing;
  SyncGateState get state => _state;

  Duration _currentBackoff = Duration.zero;
  Timer? _timer;
  bool _disposed = false;
  bool _running = false;

  /// Starts the probe → backoff → probe loop. Safe to call once; a no-op if
  /// already running or disposed. Stops itself once a probe passes and the
  /// connect callback has been invoked — call [rearm] when the engine later
  /// observes it has gone offline again, so the next connect attempt is
  /// gated too.
  void start() {
    if (_running || _disposed) return;
    _running = true;
    _currentBackoff = initialBackoff;
    _loop();
  }

  /// Stops the loop (e.g. on logout / provider disposal) without emitting
  /// further state changes.
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// Re-arms the probe loop after the engine observes it has gone offline
  /// again (e.g. `PowerSyncDatabase.statusStream` reporting `connected ==
  /// false` after having been connected) — so the next connect attempt is
  /// gated again rather than left to the engine's own unconditional retry.
  /// A no-op while a loop is already running (e.g. still backing off).
  void rearm() {
    if (_disposed || _running) return;
    start();
  }

  /// The user-triggered "sync now" override (sync.md §7.1: "a user-triggered
  /// 'sync now' always attempts once, gate or no gate"). Bypasses the probe
  /// and backoff entirely and calls the connect callback directly — it does
  /// **not** change the gate's own state or cancel a pending backoff timer,
  /// so a failed manual attempt doesn't disturb the gate's independent
  /// schedule.
  Future<void> requestSync() => _onGatePassed();

  Future<void> _loop() async {
    while (_running && !_disposed) {
      _setState(SyncGateState.probing);
      final ok = await _probe.check();
      if (!_running || _disposed) return;

      if (!ok) {
        _setState(SyncGateState.waitingForSignal);
        await _wait(_currentBackoff);
        _currentBackoff = _nextBackoff(_currentBackoff);
        continue;
      }

      _setState(SyncGateState.passed);
      _running = false; // hand off to the engine; rearm() restarts us later
      try {
        await _onGatePassed();
      } catch (_) {
        // A connect failure after a passing probe is the engine's own
        // reconnect/backoff concern from here (sync.md §7.1's "engine
        // placement" note) — the gate's job was just to permit the attempt.
      }
      return;
    }
  }

  Duration _nextBackoff(Duration current) {
    final next = Duration(
      milliseconds: (current.inMilliseconds * backoffMultiplier).round(),
    );
    return next > maxBackoff ? maxBackoff : next;
  }

  Future<void> _wait(Duration d) {
    final completer = Completer<void>();
    _timer = Timer(d, () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  void _setState(SyncGateState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void dispose() {
    _disposed = true;
    stop();
    _stateController.close();
  }
}
