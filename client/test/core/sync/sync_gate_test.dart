import 'dart:async';

import 'package:beekeepingit_client/core/sync/connectivity_probe.dart';
import 'package:beekeepingit_client/core/sync/sync_gate.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

// [SyncGate]'s whole job is a *schedule* (FR-OF-3, sync.md §7.1: probe →
// exponential backoff → probe), so every test in this file runs inside
// `fakeAsync` and advances time by hand with `async.elapse`.
//
// That is not a style preference — it is the fix for #697. Driven by real
// `Timer`s, an assertion like "by now the 5 + 10 + 20ms of backoff has
// elapsed and a 4th probe has run" is only a *lower bound* on wall clock,
// and the generous `Future.delayed` window that used to stand in for it is a
// race the runner can lose on a loaded machine or on Windows' ~15ms timer
// granularity. That is exactly what #697 observed: a *different* test in this
// file failing on each of two runs, then a clean third run.
//
// Under fake time the schedule is exact, so the assertions get **stronger**,
// not weaker: instead of "something had happened by 200ms", a test that cares
// about a deadline elapses to one millisecond short of it, asserts nothing
// fired, then crosses it and asserts exactly one probe did.
//
// `async.flushMicrotasks()` is the fake-time stand-in for the old
// `pumpEventQueue()`: it drains the probe / `onGatePassed` futures and the
// state-stream deliveries **without advancing the clock**, so a test that
// asserts the gate acted "immediately" now asserts it acted at zero elapsed
// time rather than "soon enough".
//
// One ordering rule the teardowns depend on: `addTearDown` runs in **reverse**
// registration order, so registering `restored.close` before `gate.dispose`
// is what makes dispose cancel the gate's subscription before the controller
// closes. Keep that order. Teardown itself runs after `fakeAsync` has
// returned, so the completer `dispose()` completes lands on a dead microtask
// queue and the probe loop is never actually unwound — harmless, because the
// loop only ever held fake timers, and nothing of it can leak into the next
// test.

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
    test('connects immediately when the first probe passes', () {
      fakeAsync((async) {
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
        // No `elapse`: "immediately" means at zero elapsed time, not "within
        // some window".
        async.flushMicrotasks();

        expect(connectCalls, 1);
        expect(gate.state, SyncGateState.passed);
        expect(probe.callCount, 1);
      });
    });

    test(
      'backs off exponentially on repeated probe failures before passing',
      () {
        fakeAsync((async) {
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
          async.flushMicrotasks();
          expect(probe.callCount, 1);
          expect(gate.state, SyncGateState.waitingForSignal);

          // Each failed probe waits out its own backoff — and the wait doubles
          // every time. Elapsing to one millisecond short of each deadline and
          // then across it pins the schedule at 5 → 10 → 20ms exactly, rather
          // than inferring it from "four probes happened eventually".
          async.elapse(const Duration(milliseconds: 4));
          expect(probe.callCount, 1, reason: 'still inside the 5ms backoff');
          async.elapse(const Duration(milliseconds: 1));
          expect(probe.callCount, 2);

          async.elapse(const Duration(milliseconds: 9));
          expect(
            probe.callCount,
            2,
            reason: 'the second wait is 10ms, not 5ms',
          );
          async.elapse(const Duration(milliseconds: 1));
          expect(probe.callCount, 3);

          async.elapse(const Duration(milliseconds: 19));
          expect(
            probe.callCount,
            3,
            reason: 'the third wait is 20ms, not 10ms',
          );
          async.elapse(const Duration(milliseconds: 1));
          expect(probe.callCount, 4);

          expect(connectCalls, 1);
          expect(gate.state, SyncGateState.passed);
          expect(states, contains(SyncGateState.waitingForSignal));
          expect(states, contains(SyncGateState.probing));
          expect(states.last, SyncGateState.passed);
        });
      },
    );

    test('caps backoff at maxBackoff rather than growing unbounded', () {
      fakeAsync((async) {
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
        async.flushMicrotasks();
        expect(probe.callCount, 1);

        async.elapse(const Duration(milliseconds: 5)); // the initial backoff
        expect(probe.callCount, 2);

        // ×10 would put the next wait at 50ms; the cap holds it at 15ms, so
        // probe #3 lands at 15ms and not a moment later.
        async.elapse(const Duration(milliseconds: 14));
        expect(probe.callCount, 2);
        async.elapse(const Duration(milliseconds: 1));
        expect(
          probe.callCount,
          3,
          reason: 'the 50ms growth must be clamped to the 15ms maxBackoff',
        );

        // ...and it stays clamped rather than growing again on later failures.
        async.elapse(const Duration(milliseconds: 15));
        expect(probe.callCount, 4);
        async.elapse(const Duration(milliseconds: 15));
        expect(probe.callCount, 5);

        expect(gate.state, SyncGateState.passed);
      });
    });

    test('requestSync (manual "sync now") bypasses the gate entirely, even '
        'while backing off', () {
      fakeAsync((async) {
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
        async.flushMicrotasks(); // let the first (failing) probe run

        expect(gate.state, SyncGateState.waitingForSignal);
        expect(connectCalls, 0);

        // Manual override: connects immediately, without waiting on backoff
        // or re-probing (sync.md §7.1: "a user-triggered sync now always
        // attempts once, gate or no gate").
        unawaited(gate.requestSync());
        async.flushMicrotasks();

        expect(connectCalls, 1);
        // The gate's own state/backoff schedule is untouched by the override.
        expect(gate.state, SyncGateState.waitingForSignal);
        expect(probe.callCount, 1, reason: 'the override does not re-probe');
      });
    });

    test('rearm restarts probing after the gate had already passed', () {
      fakeAsync((async) {
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
        async.flushMicrotasks();
        expect(gate.state, SyncGateState.passed);
        expect(connectCalls, 1);

        // Simulate the engine observing it went offline again (statusStream
        // transitioning connected → disconnected in powersync_service.dart).
        gate.rearm();
        async.flushMicrotasks();

        expect(connectCalls, 2);
        expect(probe.callCount, 2);
      });
    });

    test('stop() halts the loop without further state changes', () {
      fakeAsync((async) {
        final probe = FakeConnectivityProbe([false]);
        final gate = SyncGate(
          probe: probe,
          onGatePassed: () async {},
          initialBackoff: const Duration(milliseconds: 5),
          maxBackoff: const Duration(milliseconds: 10),
        );
        addTearDown(gate.dispose);

        gate.start();
        async.flushMicrotasks();
        gate.stop();
        final callsAtStop = probe.callCount;

        // Twenty times the 10ms maxBackoff: a loop that survived `stop()`
        // could not stay this quiet.
        async.elapse(const Duration(milliseconds: 200));

        expect(probe.callCount, callsAtStop);
      });
    });

    test('auto-sync toggled off and back on during a long backoff re-probes '
        'at once, rather than waiting the old timer out', () {
      fakeAsync((async) {
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
        async.flushMicrotasks();
        expect(gate.state, SyncGateState.waitingForSignal);
        expect(probe.callCount, 1);

        // `applySyncPreconditions(autoSyncEnabled: false)` then `true` (#81),
        // landing mid-backoff — the user's toggle shouldn't inherit the old
        // schedule.
        gate.stop();
        gate.start();
        async.flushMicrotasks();

        // At zero elapsed time: the restart probed, the 30s timer did not.
        expect(probe.callCount, 2);
      });
    });

    test('re-probes immediately when connectivity returns mid-backoff, '
        'instead of waiting out the pending backoff (#240)', () {
      fakeAsync((async) {
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
        async.flushMicrotasks();
        expect(gate.state, SyncGateState.waitingForSignal);
        expect(connectCalls, 0);

        // The browser reports connectivity is back (the `online` event).
        restored.add(null);
        async.flushMicrotasks();

        expect(probe.callCount, 2);
        expect(gate.state, SyncGateState.passed);
        expect(connectCalls, 1);
      });
    });

    test('falls back to initialBackoff — not the grown one — when the '
        'connectivity return lands while a probe is in flight (#240)', () {
      fakeAsync((async) {
        final probe = GatedConnectivityProbe();
        final restored = StreamController<void>.broadcast();
        addTearDown(restored.close);
        // The two backoffs are kept two orders of magnitude apart (200ms vs
        // 20s) so that "the short one, not the grown one" is unmistakable
        // in the elapsed-time assertions below.
        final gate = SyncGate(
          probe: probe,
          onGatePassed: () async {},
          onConnectivityRestored: restored.stream,
          initialBackoff: const Duration(milliseconds: 200),
          maxBackoff: const Duration(seconds: 60),
          backoffMultiplier: 100, // 200ms → 20s after a single failure
        );
        addTearDown(gate.dispose);

        // Grow the schedule first: probe #1 fails, the 200ms backoff
        // elapses, probe #2 starts — with the next backoff now at 20s.
        gate.start();
        async.flushMicrotasks();
        expect(probe.callCount, 1);
        probe.completeNext(result: false);
        async.elapse(const Duration(milliseconds: 200));
        expect(probe.callCount, 2);

        // Connectivity returns while probe #2 is still in flight, so its
        // (failing) verdict describes the pre-reconnect link.
        restored.add(null);
        async.flushMicrotasks();
        probe.completeNext(result: false);
        async.flushMicrotasks();

        // Still a delay — a connectivity return buys a prompt retry, never
        // an instant one, so an `online` burst can't spin the probe.
        expect(probe.callCount, 2);

        // ...but the short delay, not the 20s the stale verdict would have
        // earned: probe #3 lands at exactly 200ms and not before.
        async.elapse(const Duration(milliseconds: 199));
        expect(probe.callCount, 2);
        async.elapse(const Duration(milliseconds: 1));
        expect(
          probe.callCount,
          3,
          reason:
              'the pre-reconnect verdict must earn initialBackoff (200ms), '
              'not the grown 20s',
        );
      });
    });

    test('shortens the pending wait without resetting the exponential '
        'schedule, so a flapping link still decays (#240)', () {
      fakeAsync((async) {
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

        // Probe #1 fails, the 100ms backoff elapses, probe #2 fails → the gate
        // is now sitting on a 10s backoff (so the count settles at 2).
        gate.start();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 100));
        expect(probe.callCount, 2);

        restored.add(null);
        async.flushMicrotasks();
        expect(probe.callCount, 3, reason: 'the return buys a prompt probe');

        // The wait that follows probe #3 is the GROWN one — 10s × 100, clamped
        // to the 60s maxBackoff — so the gate now goes quiet for a full
        // minute. Elapsing to one millisecond short of that boundary is what
        // rules out *any* reset of the schedule: had the connectivity return
        // put `_currentBackoff` back to the 100ms initialBackoff (in the
        // handler or in the loop), probe #4 would already have landed by 10s
        // at the latest, long inside this window.
        async.elapse(const Duration(milliseconds: 59999));
        expect(
          probe.callCount,
          3,
          reason:
              'the return should buy exactly one prompt probe and leave the '
              'grown schedule alone; a reset to the 100ms initialBackoff would '
              'have fired again well inside this minute',
        );

        // ...and the schedule is merely delayed, not stopped: probe #4 lands
        // exactly on the 60s boundary.
        async.elapse(const Duration(milliseconds: 1));
        expect(probe.callCount, 4);
      });
    });

    test('a stop/start during an in-flight probe leaves exactly one loop '
        'running', () {
      fakeAsync((async) {
        final probe = GatedConnectivityProbe();
        final gate = SyncGate(
          probe: probe,
          onGatePassed: () async {},
          initialBackoff: const Duration(milliseconds: 20),
          maxBackoff: const Duration(milliseconds: 40),
        );
        addTearDown(gate.dispose);

        gate.start();
        async.flushMicrotasks();
        expect(probe.callCount, 1);

        // Auto-sync toggled off and back on inside the probe's own window
        // (FR-ST-1's `applySyncPreconditions`) — the second `start()` begins a
        // fresh loop while the first is still parked on its probe.
        gate.stop();
        gate.start();
        async.flushMicrotasks();
        expect(probe.callCount, 2);

        // Resolve ONLY the retired loop's probe, then let more than a backoff
        // elapse: a retired loop must stop dead here, not back off and probe
        // again alongside the live loop (which is still awaiting its own
        // probe, so any third call could only have come from the retired one).
        probe.completeNext(result: false);
        async.elapse(const Duration(milliseconds: 400));

        expect(
          probe.callCount,
          2,
          reason:
              'the retired loop must not keep probing alongside the live '
              'one — two live loops fight over the shared backoff timer',
        );

        // The live loop is unaffected and carries on backing off/probing.
        probe.completeNext(result: false);
        async.elapse(const Duration(milliseconds: 20));
        expect(probe.callCount, 3);
      });
    });

    test('ignores a connectivity return while the gate is not running — a '
        'stopped gate (auto-sync off) stays stopped (#240)', () {
      fakeAsync((async) {
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

        // Never started (or stopped by
        // `applySyncPreconditions(autoSyncEnabled: false)`).
        restored.add(null);
        async.flushMicrotasks();
        expect(probe.callCount, 0);

        gate.start();
        async.flushMicrotasks();
        gate.stop();
        final callsAtStop = probe.callCount;

        restored.add(null);
        async.elapse(const Duration(milliseconds: 60));
        expect(probe.callCount, callsAtStop);
      });
    });

    test('ignores a connectivity return once the gate has passed — the engine '
        'owns the connection from there (#240)', () {
      fakeAsync((async) {
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
        async.flushMicrotasks();
        expect(gate.state, SyncGateState.passed);

        restored.add(null);
        async.flushMicrotasks();

        expect(connectCalls, 1);
        expect(probe.callCount, 1);
      });
    });

    test('dispose() stops listening for connectivity returns', () {
      fakeAsync((async) {
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
        async.flushMicrotasks();
        final callsAtDispose = probe.callCount;

        gate.dispose();
        restored.add(null);
        async.flushMicrotasks();

        expect(probe.callCount, callsAtDispose);
      });
    });
  });
}
