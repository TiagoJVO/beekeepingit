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
  });
}
