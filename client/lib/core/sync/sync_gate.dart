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
  /// so marginal-signal windows don't churn the radio and battery"). Cut
  /// short when the device reports connectivity has returned, so a reconnect
  /// re-probes promptly instead of sitting out the backoff (#240 — see
  /// [SyncGate]'s `onConnectivityRestored`).
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
  /// [onConnectivityRestored] carries the device's own "connectivity came
  /// back" events (the browser `online` event on web — see
  /// `connectivity_signal.dart`). Optional: with no stream the gate behaves
  /// exactly as before, which is what most unit tests want.
  SyncGate({
    required this._probe,
    required this._onGatePassed,
    Stream<void>? onConnectivityRestored,
    this.initialBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(minutes: 2),
    this.backoffMultiplier = 2,
  }) {
    _restoredSub = onConnectivityRestored?.listen(
      (_) => _handleConnectivityRestored(),
      // The hint is best-effort by construction (a platform that can't
      // report connectivity returns simply never emits), so a stream that
      // errors must cost promptness, not crash the app: swallow it and fall
      // back to the gate's own probe/backoff schedule.
      onError: (Object _) {},
    );
  }

  final ConnectivityProbe _probe;
  final Future<void> Function() _onGatePassed;
  StreamSubscription<void>? _restoredSub;

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

  /// Completes the in-flight backoff wait — either because its timer elapsed
  /// or because something cut it short ([_handleConnectivityRestored],
  /// [stop]).
  Completer<void>? _backoffCompleter;

  /// Set by *every* connectivity return while the loop runs, and cleared by
  /// [_loop] immediately before each probe — so at its single read site (the
  /// failure branch) it means exactly "a return landed while this probe was
  /// in flight", i.e. the probe measured the *pre-reconnect* link and its
  /// verdict shouldn't impose a long backoff (#240). Keep the clear adjacent
  /// to the probe: widening that window is what would break the invariant.
  bool _restoredDuringProbe = false;

  /// Bumped by every [start]/[stop], and captured by [_loop] at entry: an
  /// `await` inside the loop can return *after* the gate was stopped and
  /// restarted (a stop/start inside a probe's ~3s window — e.g. toggling
  /// auto-sync off and on), and a plain `_running` re-check would see the
  /// new `true` and let the stale loop run on alongside the new one, two
  /// loops then fighting over [_timer]/[_backoffCompleter]. Comparing the
  /// captured generation instead retires the stale loop at its next check.
  int _generation = 0;

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
    _generation++;
    _currentBackoff = initialBackoff;
    _loop();
  }

  /// Stops the loop (e.g. on logout / provider disposal) without emitting
  /// further state changes.
  void stop() {
    _running = false;
    _generation++;
    // Release a pending backoff wait too, so [_loop] actually returns
    // instead of parking forever on a Future nothing will ever complete.
    _endWait();
  }

  /// Re-arms the probe loop after the engine observes it has gone offline
  /// again (e.g. `PowerSyncDatabase.statusStream` reporting `connected ==
  /// false` after having been connected) — so the next connect attempt is
  /// gated again rather than left to the engine's own unconditional retry.
  /// A no-op while a loop is already running (e.g. still backing off) — a
  /// running loop's pending backoff is instead cut short by the
  /// `onConnectivityRestored` stream (#240).
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

  /// Cuts a pending backoff short so the next probe happens now, because the
  /// device just reported that connectivity came back (#240, FR-OF-3).
  /// Without this the gate would sit out a backoff of up to [maxBackoff]
  /// (~2 min) after a reconnect, leaving a queued offline write unflushed
  /// until it elapsed or the user tapped "sync now" — sync.md §7.1's gate is
  /// meant to make weak signal cheap, not to delay a link that has genuinely
  /// returned.
  ///
  /// It **shortens one wait; it does not reset the schedule.** A marginal
  /// link that flaps `offline → online` repeatedly is precisely the case the
  /// exponential backoff exists for, so restarting the schedule on every
  /// `online` event would pin the gate at [initialBackoff] and produce the
  /// radio/battery churn §7.1 set out to avoid. Each event buys one prompt
  /// attempt; the delay between attempts keeps growing while probes keep
  /// failing.
  ///
  /// Deliberately a **no-op while the loop isn't running**: a stopped gate is
  /// either auto-sync-off (FR-ST-1 — the user's choice, not ours to undo) or
  /// already `passed`, where the engine owns its connection lifecycle and
  /// `rearm()` (driven by `statusStream`) is what brings the gate back.
  void _handleConnectivityRestored() {
    if (_disposed || !_running) return;
    // Only meaningful if a probe is in flight right now; [_loop] clears it
    // before every probe.
    _restoredDuringProbe = true;
    _endWait();
  }

  Future<void> _loop() async {
    final generation = _generation;
    while (generation == _generation && !_disposed) {
      _restoredDuringProbe = false;
      _setState(SyncGateState.probing);
      final ok = await _probe.check();
      if (generation != _generation || _disposed) return;

      if (!ok) {
        _setState(SyncGateState.waitingForSignal);
        // Connectivity returned while this probe was in flight, so its
        // verdict describes the link *before* the reconnect (#240): retry
        // after a short [initialBackoff] instead of the grown delay that
        // stale verdict would otherwise earn. Still a delay, not an instant
        // retry — an `online` burst must not spin the probe.
        final backoff = _restoredDuringProbe ? initialBackoff : _currentBackoff;
        await _wait(backoff);
        if (generation != _generation || _disposed) return;
        // Growth is unconditional: every failed probe makes the next wait
        // longer, whether or not a connectivity return shortened this one.
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

  /// Waits out [d] — or until [_endWait] cuts the wait short (a connectivity
  /// return, or [stop]/[dispose] retiring the loop).
  Future<void> _wait(Duration d) {
    final completer = Completer<void>();
    _backoffCompleter = completer;
    _timer = Timer(d, _endWait);
    return completer.future;
  }

  void _endWait() {
    _timer?.cancel();
    _timer = null;
    final pending = _backoffCompleter;
    _backoffCompleter = null;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  void _setState(SyncGateState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  void dispose() {
    _disposed = true;
    stop();
    _restoredSub?.cancel();
    _restoredSub = null;
    _stateController.close();
  }
}
