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

    test('re-probes after a connectivity return that lands while a probe is '
        'already in flight (#240)', () async {
      final probe = GatedConnectivityProbe();
      final restored = StreamController<void>.broadcast();
      addTearDown(restored.close);
      var connectCalls = 0;
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async => connectCalls++,
        onConnectivityRestored: restored.stream,
        initialBackoff: const Duration(seconds: 30),
        maxBackoff: const Duration(minutes: 2),
      );
      addTearDown(gate.dispose);

      gate.start();
      await pumpEventQueue();
      expect(probe.callCount, 1);

      // Connectivity returns while the first probe is still in flight, so
      // that probe's (failing) verdict describes the pre-reconnect link.
      restored.add(null);
      await pumpEventQueue();
      probe.completeNext(result: false);
      await pumpEventQueue();

      // The stale verdict must not sentence the queue to a 30s backoff.
      expect(probe.callCount, 2);
      expect(gate.state, SyncGateState.probing);

      probe.completeNext(result: true);
      await pumpEventQueue();
      expect(connectCalls, 1);
    });

    test('resets the backoff to initialBackoff after a connectivity-return '
        're-probe, rather than resuming the grown one (#240)', () async {
      final probe = FakeConnectivityProbe([false]); // never passes
      final restored = StreamController<void>.broadcast();
      addTearDown(restored.close);
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        onConnectivityRestored: restored.stream,
        initialBackoff: const Duration(milliseconds: 20),
        maxBackoff: const Duration(seconds: 5),
        backoffMultiplier: 50, // 20ms → 1s after a single failure
      );
      addTearDown(gate.dispose);

      gate.start();
      // First probe fails, the 20ms backoff elapses, the second probe fails →
      // the gate is now sitting on a 1s backoff.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(probe.callCount, 2);

      restored.add(null);
      // The interrupt re-probes at once; because the backoff was reset to
      // 20ms (not left at 1s), further probes keep coming quickly.
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(
        probe.callCount,
        greaterThanOrEqualTo(4),
        reason:
            'a reset backoff should have allowed several more probes; a '
            'resumed 1s backoff would have allowed only the interrupt one',
      );
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
