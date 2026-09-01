import 'dart:async';

import 'package:beekeepingit_client/core/sync/connectivity_probe.dart';
import 'package:beekeepingit_client/core/sync/sync_gate.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scripted [ConnectivityProbe]: returns each entry of [results] in order
/// (repeating the last one once exhausted), and records how many times it
/// was called — so tests can assert both the gate's *behavior* (state
/// transitions, when the connect callback fires) and its *call pattern*
/// (does it actually back off rather than hammering the probe).
class FakeConnectivityProbe implements ConnectivityProbe {
  FakeConnectivityProbe(this.results);

  final List<bool> results;
  int callCount = 0;

  @override
  Future<bool> check() async {
    final result = callCount < results.length
        ? results[callCount]
        : results.last;
    callCount++;
    return result;
  }

  @override
  void dispose() {}
}

/// Polls until [condition] holds, giving up after [timeout].
///
/// The gate is driven by real `Timer`s, so a test that asserts "by now the
/// backoff has elapsed and another probe has run" is a **lower bound** — and
/// a fixed `Future.delayed` turns that into a race the CI runner can lose on
/// a cold or loaded machine (observed: a 20ms backoff missing a 400ms
/// window). Waiting for the condition instead keeps the assertion's meaning
/// while removing the race. Upper-bound assertions ("nothing further must
/// happen") deliberately keep a fixed, generous window — that IS the test.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A [ConnectivityProbe] whose in-flight check the test completes by hand —
/// so a test can land a connectivity-return event *while a probe is already
/// running*, i.e. the reconnect that happens mid-probe, whose result
/// therefore measured the pre-reconnect link.
class GatedConnectivityProbe implements ConnectivityProbe {
  final List<Completer<bool>> pending = [];
  int callCount = 0;

  @override
  Future<bool> check() {
    callCount++;
    final completer = Completer<bool>();
    pending.add(completer);
    return completer.future;
  }

  /// Resolves the oldest still-unresolved check with [result].
  void completeNext({required bool result}) =>
      pending.firstWhere((c) => !c.isCompleted).complete(result);

  @override
  void dispose() {}
}

void main() {
  group('SyncGate', () {
    test('connects immediately when the first probe passes', () async {
      final probe = FakeConnectivityProbe([true]);
      var connectCalls = 0;
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async => connectCalls++,
        initialBackoff: const Duration(milliseconds: 5),
        maxBackoff: const Duration(milliseconds: 40),
      );
      addTearDown(gate.dispose);

      gate.start();
      await pumpEventQueue();

      expect(connectCalls, 1);
      expect(gate.state, SyncGateState.passed);
      expect(probe.callCount, 1);
    });

    test(
      'backs off exponentially on repeated probe failures before passing',
      () async {
        // Fails 3 times, then passes.
        final probe = FakeConnectivityProbe([false, false, false, true]);
        var connectCalls = 0;
        final gate = SyncGate(
          probe: probe,
          onGatePassed: () async => connectCalls++,
          initialBackoff: const Duration(milliseconds: 5),
          maxBackoff: const Duration(milliseconds: 100),
          backoffMultiplier: 2,
        );
        addTearDown(gate.dispose);

        final states = <SyncGateState>[];
        gate.stateStream.listen(states.add);

        gate.start();
        // Wait comfortably longer than 5 + 10 + 20ms of backoff.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        expect(connectCalls, 1);
        expect(gate.state, SyncGateState.passed);
        expect(probe.callCount, 4);
        expect(states, contains(SyncGateState.waitingForSignal));
        expect(states, contains(SyncGateState.probing));
        expect(states.last, SyncGateState.passed);
      },
    );

    test('caps backoff at maxBackoff rather than growing unbounded', () async {
      final probe = FakeConnectivityProbe([false, false, false, false, true]);
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        initialBackoff: const Duration(milliseconds: 5),
        maxBackoff: const Duration(milliseconds: 15),
        backoffMultiplier: 10, // would blow past max after one failure
      );
      addTearDown(gate.dispose);

      gate.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(gate.state, SyncGateState.passed);
      expect(probe.callCount, 5);
    });

    test('requestSync (manual "sync now") bypasses the gate entirely, even '
        'while backing off', () async {
      final probe = FakeConnectivityProbe([false]); // never passes on its own
      var connectCalls = 0;
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async => connectCalls++,
        initialBackoff: const Duration(seconds: 30), // long backoff
        maxBackoff: const Duration(seconds: 60),
      );
      addTearDown(gate.dispose);

      gate.start();
      await pumpEventQueue(); // let the first (failing) probe run

      expect(gate.state, SyncGateState.waitingForSignal);
      expect(connectCalls, 0);

      // Manual override: connects immediately, without waiting on backoff
      // or re-probing (sync.md §7.1: "a user-triggered sync now always
      // attempts once, gate or no gate").
      await gate.requestSync();

      expect(connectCalls, 1);
      // The gate's own state/backoff schedule is untouched by the override.
      expect(gate.state, SyncGateState.waitingForSignal);
    });

    test('rearm restarts probing after the gate had already passed', () async {
      final probe = FakeConnectivityProbe([true, true]);
      var connectCalls = 0;
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async => connectCalls++,
        initialBackoff: const Duration(milliseconds: 5),
        maxBackoff: const Duration(milliseconds: 40),
      );
      addTearDown(gate.dispose);

      gate.start();
      await pumpEventQueue();
      expect(gate.state, SyncGateState.passed);
      expect(connectCalls, 1);

      // Simulate the engine observing it went offline again (statusStream
      // transitioning connected → disconnected in powersync_service.dart).
      gate.rearm();
      await pumpEventQueue();

      expect(connectCalls, 2);
      expect(probe.callCount, 2);
    });

    test('stop() halts the loop without further state changes', () async {
      final probe = FakeConnectivityProbe([false]);
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        initialBackoff: const Duration(milliseconds: 5),
        maxBackoff: const Duration(milliseconds: 10),
      );
      addTearDown(gate.dispose);

      gate.start();
      await pumpEventQueue();
      gate.stop();
      final callsAtStop = probe.callCount;

      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(probe.callCount, callsAtStop);
    });

    test('auto-sync toggled off and back on during a long backoff re-probes '
        'at once, rather than waiting the old timer out', () async {
      final probe = FakeConnectivityProbe([false]);
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        // Long enough that "at once" can only mean the restart, never the
        // pending timer elapsing (which the 5ms `stop()` test above allows).
        initialBackoff: const Duration(seconds: 30),
        maxBackoff: const Duration(minutes: 2),
      );
      addTearDown(gate.dispose);

      gate.start();
      await pumpEventQueue();
      expect(gate.state, SyncGateState.waitingForSignal);
      expect(probe.callCount, 1);

      // `applyAutoSyncSetting(enabled: false)` then `true` (#81), landing
      // mid-backoff — the user's toggle shouldn't inherit the old schedule.
      gate.stop();
      gate.start();
      await pumpEventQueue();

      expect(probe.callCount, 2);
    });

    test('re-probes immediately when connectivity returns mid-backoff, '
        'instead of waiting out the pending backoff (#240)', () async {
      // Fails once (so the gate is mid-backoff), then passes.
      final probe = FakeConnectivityProbe([false, true]);
      final restored = StreamController<void>.broadcast();
      addTearDown(restored.close);
      var connectCalls = 0;
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async => connectCalls++,
        onConnectivityRestored: restored.stream,
        // Long enough that a test that merely waits could never pass.
        initialBackoff: const Duration(seconds: 30),
        maxBackoff: const Duration(minutes: 2),
      );
      addTearDown(gate.dispose);

      gate.start();
      await pumpEventQueue();
      expect(gate.state, SyncGateState.waitingForSignal);
      expect(connectCalls, 0);

      // The browser reports connectivity is back (the `online` event).
      restored.add(null);
      await pumpEventQueue();

      expect(probe.callCount, 2);
      expect(gate.state, SyncGateState.passed);
      expect(connectCalls, 1);
    });

    test(
      'falls back to initialBackoff — not the grown one — when the '
      'connectivity return lands while a probe is in flight (#240)',
      () async {
        final probe = GatedConnectivityProbe();
        final restored = StreamController<void>.broadcast();
        addTearDown(restored.close);
        // The two backoffs are kept two orders of magnitude apart in wall
        // clock (200ms vs 20s): the assertions below are only sound while
        // the short one has NOT yet elapsed, and a 20ms tolerance is not
        // enough headroom for a cold/loaded CI runner.
        final gate = SyncGate(
          probe: probe,
          onGatePassed: () async {},
          onConnectivityRestored: restored.stream,
          initialBackoff: const Duration(milliseconds: 200),
          maxBackoff: const Duration(seconds: 60),
          backoffMultiplier: 100, // 200ms → 20s after a single failure
        );
        addTearDown(gate.dispose);

        // Grow the schedule first: probe #1 fails, the 200ms backoff elapses,
        // probe #2 starts — with the next backoff now standing at 20s.
        gate.start();
        await pumpEventQueue();
        probe.completeNext(result: false);
        await waitUntil(() => probe.callCount >= 2);
        expect(probe.callCount, 2);

        // Connectivity returns while probe #2 is still in flight, so its
        // (failing) verdict describes the pre-reconnect link.
        restored.add(null);
        probe.completeNext(result: false);
        await pumpEventQueue();

        // Still a delay — a connectivity return buys a prompt retry, never an
        // instant one, so an `online` burst can't spin the probe.
        expect(probe.callCount, 2);

        // ...but the short one, not the 20s the stale verdict would have
        // earned: this resolves in ~200ms, and could not resolve at all
        // within the poll's deadline if the grown backoff had been used.
        await waitUntil(() => probe.callCount >= 3);
        expect(probe.callCount, 3);
      },
    );

    test('shortens the pending wait without resetting the exponential '
        'schedule, so a flapping link still decays (#240)', () async {
      final probe = FakeConnectivityProbe([false]); // never passes
      final restored = StreamController<void>.broadcast();
      addTearDown(restored.close);
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        onConnectivityRestored: restored.stream,
        initialBackoff: const Duration(milliseconds: 100),
        maxBackoff: const Duration(seconds: 60),
        backoffMultiplier: 100, // 100ms → 10s after a single failure
      );
      addTearDown(gate.dispose);

      gate.start();
      // Probe #1 fails, the 100ms backoff elapses, probe #2 fails → the gate
      // is now sitting on a 10s backoff (so the count settles at 2).
      await waitUntil(() => probe.callCount >= 2);
      expect(probe.callCount, 2);

      restored.add(null);
      await waitUntil(() => probe.callCount >= 3);
      // Then hold still well past a fresh initialBackoff: if the return had
      // reset the schedule to 100ms, a 4th and 5th probe would land here.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        probe.callCount,
        3,
        reason:
            'the return should buy exactly one prompt probe; a schedule reset '
            'to the 100ms initialBackoff would have fired several more',
      );
    });

    test('a stop/start during an in-flight probe leaves exactly one loop '
        'running', () async {
      final probe = GatedConnectivityProbe();
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        initialBackoff: const Duration(milliseconds: 20),
        maxBackoff: const Duration(milliseconds: 40),
      );
      addTearDown(gate.dispose);

      gate.start();
      await pumpEventQueue();
      expect(probe.callCount, 1);

      // Auto-sync toggled off and back on inside the probe's own window
      // (FR-ST-1's `applyAutoSyncSetting`) — the second `start()` begins a
      // fresh loop while the first is still parked on its probe.
      gate.stop();
      gate.start();
      await pumpEventQueue();
      expect(probe.callCount, 2);

      // Resolve ONLY the retired loop's probe, then let more than a backoff
      // elapse: a retired loop must stop dead here, not back off and probe
      // again alongside the live loop (which is still awaiting its own
      // probe, so any third call could only have come from the retired one).
      probe.completeNext(result: false);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        probe.callCount,
        2,
        reason:
            'the retired loop must not keep probing alongside the live '
            'one — two live loops fight over the shared backoff timer',
      );

      // The live loop is unaffected and carries on backing off/probing.
      // (Probe #3 is left gated open, so this can never overshoot to a 4th
      // call however slow the runner is.)
      probe.completeNext(result: false);
      await waitUntil(() => probe.callCount >= 3);
      expect(probe.callCount, 3);
    });

    test('ignores a connectivity return while the gate is not running — a '
        'stopped gate (auto-sync off) stays stopped (#240)', () async {
      final probe = FakeConnectivityProbe([false]);
      final restored = StreamController<void>.broadcast();
      addTearDown(restored.close);
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        onConnectivityRestored: restored.stream,
        initialBackoff: const Duration(milliseconds: 5),
        maxBackoff: const Duration(milliseconds: 20),
      );
      addTearDown(gate.dispose);

      // Never started (or stopped by `applyAutoSyncSetting(enabled: false)`).
      restored.add(null);
      await pumpEventQueue();
      expect(probe.callCount, 0);

      gate.start();
      await pumpEventQueue();
      gate.stop();
      final callsAtStop = probe.callCount;

      restored.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(probe.callCount, callsAtStop);
    });

    test('ignores a connectivity return once the gate has passed — the engine '
        'owns the connection from there (#240)', () async {
      final probe = FakeConnectivityProbe([true]);
      final restored = StreamController<void>.broadcast();
      addTearDown(restored.close);
      var connectCalls = 0;
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async => connectCalls++,
        onConnectivityRestored: restored.stream,
        initialBackoff: const Duration(milliseconds: 5),
        maxBackoff: const Duration(milliseconds: 20),
      );
      addTearDown(gate.dispose);

      gate.start();
      await pumpEventQueue();
      expect(gate.state, SyncGateState.passed);

      restored.add(null);
      await pumpEventQueue();

      expect(connectCalls, 1);
      expect(probe.callCount, 1);
    });

    test('dispose() stops listening for connectivity returns', () async {
      final probe = FakeConnectivityProbe([false]);
      final restored = StreamController<void>.broadcast();
      addTearDown(restored.close);
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        onConnectivityRestored: restored.stream,
        initialBackoff: const Duration(seconds: 30),
        maxBackoff: const Duration(minutes: 2),
      );

      gate.start();
      await pumpEventQueue();
      final callsAtDispose = probe.callCount;

      gate.dispose();
      restored.add(null);
      await pumpEventQueue();

      expect(probe.callCount, callsAtDispose);
    });
  });
}
