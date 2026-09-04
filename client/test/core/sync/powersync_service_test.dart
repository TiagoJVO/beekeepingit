import 'dart:async';

import 'package:beekeepingit_client/core/sync/connectivity_probe.dart';
import 'package:beekeepingit_client/core/sync/powersync_service.dart';
import 'package:beekeepingit_client/core/sync/sync_gate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';

/// A scripted [ConnectivityProbe] — always resolves immediately with a fixed
/// result and counts invocations, so tests can tell whether [SyncGate]'s
/// probe loop is actually running without a real network call. Mirrors
/// `sync_gate_test.dart`'s own fakes (a fake, not a mock, per the project's
/// Dart testing conventions).
class _FakeProbe implements ConnectivityProbe {
  _FakeProbe({this.result = true});

  final bool result;
  int checkCalls = 0;

  @override
  Future<bool> check() async {
    checkCalls++;
    return result;
  }

  @override
  void dispose() {}
}

void main() {
  group(
    'debugOpenPowerSyncDatabase (#286 — "Multiple instances" test noise)',
    () {
      test('the suite-wide test config installs the stub, so no test opens a '
          'real on-device database', () {
        // Set by test/flutter_test_config.dart, which `flutter test` runs for
        // every file under test/. If this ever goes null, widget tests start
        // leaking un-closable PowerSyncDatabase handles again and PowerSync
        // floods the run with "Multiple instances for the same database".
        expect(debugOpenPowerSyncDatabase, isNotNull);
      });

      test('powerSyncProvider opens through the seam rather than constructing '
          'a PowerSyncDatabase directly', () async {
        final previous = debugOpenPowerSyncDatabase;
        addTearDown(() => debugOpenPowerSyncDatabase = previous);
        var opens = 0;
        debugOpenPowerSyncDatabase = () {
          opens++;
          // Never completes — mirroring what a *widget* test observes, and
          // what test/flutter_test_config.dart installs suite-wide. A plain
          // `test()` like this one is the opposite case: here the real open
          // would actually succeed and leave a `beekeepingit.db` behind,
          // which is exactly why what's asserted is that the provider goes
          // through the seam at all.
          return Completer<PowerSyncDatabase>().future;
        };

        final container = ProviderContainer();
        addTearDown(container.dispose);
        container.read(powerSyncProvider);
        await pumpEventQueue();

        expect(opens, 1);
      });
    },
  );

  group('TeardownGuard (HIGH #2 — async ref.onDispose is fire-and-forget)', () {
    test('waitForPrior resolves immediately when nothing is pending', () async {
      final guard = TeardownGuard();

      // Would hang (and fail the test on timeout) if this incorrectly
      // waited on something.
      await guard.waitForPrior().timeout(const Duration(milliseconds: 200));
    });

    test('waitForPrior waits for a registered teardown to actually finish '
        'before returning — the fix for the dispose race: without this, the '
        "next powerSyncProvider open could race the previous instance's "
        'db.close() and trigger PowerSync\'s own "Multiple instances" '
        'warning', () async {
      final guard = TeardownGuard();
      var teardownFinished = false;

      guard.registerTeardown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        teardownFinished = true;
      });

      // Immediately after registering — matches production, where the
      // *next* provider read happens right after `ref.onDispose` fires.
      expect(
        teardownFinished,
        isFalse,
        reason: 'sanity check: the teardown really is still in flight',
      );

      await guard.waitForPrior();

      expect(
        teardownFinished,
        isTrue,
        reason:
            'waitForPrior must not return until the registered teardown '
            'actually completed',
      );
    });

    test('registerTeardown is fire-and-forget — it does not block the caller '
        '(mirrors ref.onDispose being a void Function())', () {
      final guard = TeardownGuard();
      var teardownFinished = false;

      guard.registerTeardown(() async {
        await Future<void>.delayed(const Duration(seconds: 10));
        teardownFinished = true;
      });

      // registerTeardown returned synchronously without waiting for the
      // (10-second) teardown to finish.
      expect(teardownFinished, isFalse);
    });

    test('a second waitForPrior call after the first resolved does not wait '
        'again (no stale/leaked pending future)', () async {
      final guard = TeardownGuard();
      guard.registerTeardown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });

      await guard.waitForPrior();

      // The first teardown is done; a second call must resolve
      // immediately rather than somehow re-waiting on it.
      await guard.waitForPrior().timeout(const Duration(milliseconds: 50));
    });

    test('each new registerTeardown supersedes the previous one for the '
        'purposes of the next waitForPrior call', () async {
      final guard = TeardownGuard();
      final order = <String>[];

      guard.registerTeardown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        order.add('first');
      });
      guard.registerTeardown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        order.add('second');
      });

      await guard.waitForPrior();

      expect(order, contains('second'));
    });
  });

  group('rearmGateOnDisconnect (HIGH #3 — zero test coverage on sync-engine '
      'wiring logic)', () {
    test(
      're-arms exactly once on a connected → disconnected transition',
      () async {
        final controller = StreamController<bool>();
        var rearmCalls = 0;

        final sub = rearmGateOnDisconnect(
          connectedStream: controller.stream,
          rearm: () => rearmCalls++,
          onConnectedChanged: (_) {},
        );
        addTearDown(sub.cancel);

        controller.add(true); // connected
        await pumpEventQueue();
        controller.add(false); // → disconnected: should rearm
        await pumpEventQueue();

        expect(rearmCalls, 1);
      },
    );

    test(
      'never rearms while staying connected or starting disconnected',
      (() async {
        final controller = StreamController<bool>();
        var rearmCalls = 0;

        final sub = rearmGateOnDisconnect(
          connectedStream: controller.stream,
          rearm: () => rearmCalls++,
          onConnectedChanged: (_) {},
        );
        addTearDown(sub.cancel);

        controller.add(false); // starts disconnected — not a transition
        await pumpEventQueue();
        controller.add(true);
        await pumpEventQueue();
        controller.add(true); // still connected
        await pumpEventQueue();

        expect(rearmCalls, 0);
      }),
    );

    test('rearms again on a second connected → disconnected transition '
        '(not just the first)', () async {
      final controller = StreamController<bool>();
      var rearmCalls = 0;

      final sub = rearmGateOnDisconnect(
        connectedStream: controller.stream,
        rearm: () => rearmCalls++,
        onConnectedChanged: (_) {},
      );
      addTearDown(sub.cancel);

      controller.add(true);
      controller.add(false); // rearm #1
      controller.add(true);
      controller.add(false); // rearm #2
      await pumpEventQueue();

      expect(rearmCalls, 2);
    });

    test(
      'reports every observed connectivity value via onConnectedChanged',
      () async {
        final controller = StreamController<bool>();
        final observed = <bool>[];

        final sub = rearmGateOnDisconnect(
          connectedStream: controller.stream,
          rearm: () {},
          onConnectedChanged: observed.add,
        );
        addTearDown(sub.cancel);

        controller.add(true);
        controller.add(false);
        controller.add(true);
        await pumpEventQueue();

        expect(observed, [true, false, true]);
      },
    );
  });

  group('applySyncPreconditions (#81 — the sync-settings screen honored by '
      'the EPIC-06 sync layer; #622 — the membership precondition)', () {
    test('both preconditions met starts a fresh (not-yet-started) gate — the '
        'probe loop actually runs', () async {
      final probe = _FakeProbe();
      final gate = SyncGate(probe: probe, onGatePassed: () async {});
      addTearDown(gate.dispose);

      applySyncPreconditions(
        autoSyncEnabled: true,
        hasMembership: true,
        gate: gate,
      );
      await pumpEventQueue();

      expect(probe.checkCalls, greaterThan(0));
    });

    test(
      'autoSyncEnabled: false never starts the gate\'s probe loop',
      () async {
        final probe = _FakeProbe();
        final gate = SyncGate(probe: probe, onGatePassed: () async {});
        addTearDown(gate.dispose);

        applySyncPreconditions(
          autoSyncEnabled: false,
          hasMembership: true,
          gate: gate,
        );
        await pumpEventQueue();

        expect(probe.checkCalls, 0);
      },
    );

    test('autoSyncEnabled: false stops an already-running gate — a pending '
        'backoff never fires another probe', () async {
      final probe = _FakeProbe(result: false); // keeps backing off
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        initialBackoff: const Duration(milliseconds: 20),
      );
      addTearDown(gate.dispose);
      gate.start();
      await pumpEventQueue();
      final callsWhileRunning = probe.checkCalls;
      expect(
        callsWhileRunning,
        greaterThan(0),
        reason: 'sanity check: the loop really is running',
      );

      applySyncPreconditions(
        autoSyncEnabled: false,
        hasMembership: true,
        gate: gate,
      );
      // Longer than initialBackoff — if stop() failed to cancel the
      // pending timer, another probe would fire in this window.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        probe.checkCalls,
        callsWhileRunning,
        reason: 'stop() must cancel the backoff timer',
      );
    });

    test('autoSyncEnabled: true re-arms a gate previously stopped by this '
        'same function (the toggle-back-on case)', () async {
      final probe = _FakeProbe();
      final gate = SyncGate(probe: probe, onGatePassed: () async {});
      addTearDown(gate.dispose);
      gate.start();
      await pumpEventQueue(); // passes immediately, hands off to "engine"
      applySyncPreconditions(
        autoSyncEnabled: false,
        hasMembership: true,
        gate: gate,
      );
      final callsWhileOff = probe.checkCalls;

      applySyncPreconditions(
        autoSyncEnabled: true,
        hasMembership: true,
        gate: gate,
      );
      await pumpEventQueue();

      expect(probe.checkCalls, greaterThan(callsWhileOff));
    });

    test('no membership: auto-sync on is NOT enough to start the gate — no '
        'probe, no connect churn while the user is still on the '
        'create-organization step (#622, FR-OF-3, FR-ONB-2/D-3)', () async {
      final probe = _FakeProbe();
      final gate = SyncGate(probe: probe, onGatePassed: () async {});
      addTearDown(gate.dispose);

      applySyncPreconditions(
        autoSyncEnabled: true,
        hasMembership: false,
        gate: gate,
      );
      await pumpEventQueue();

      expect(
        probe.checkCalls,
        0,
        reason: 'nothing to sync — and nothing that could authenticate — yet',
      );
    });

    test('no membership stops an already-running gate too — a pending backoff '
        'fires no further probe (the membership-lost case, #125)', () async {
      final probe = _FakeProbe(result: false); // keeps backing off
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        initialBackoff: const Duration(milliseconds: 20),
      );
      addTearDown(gate.dispose);
      gate.start();
      await pumpEventQueue();
      final callsWhileRunning = probe.checkCalls;
      expect(
        callsWhileRunning,
        greaterThan(0),
        reason: 'sanity check: the loop really is running',
      );

      applySyncPreconditions(
        autoSyncEnabled: true,
        hasMembership: false,
        gate: gate,
      );
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(
        probe.checkCalls,
        callsWhileRunning,
        reason: 'losing the membership must cancel the backoff timer too',
      );
    });

    test('membership gained: a gate stopped for lack of one starts probing AND '
        'connects — this is what makes sync begin the moment '
        'POST /v1/organizations returns 201, with no reload (#622)', () async {
      final probe = _FakeProbe();
      var connects = 0;
      final gate = SyncGate(probe: probe, onGatePassed: () async => connects++);
      addTearDown(gate.dispose);

      applySyncPreconditions(
        autoSyncEnabled: true,
        hasMembership: false,
        gate: gate,
      );
      await pumpEventQueue();
      expect(probe.checkCalls, 0, reason: 'sanity check: still onboarding');

      // The false → true edge organizationProvider emits on creation.
      applySyncPreconditions(
        autoSyncEnabled: true,
        hasMembership: true,
        gate: gate,
      );
      await pumpEventQueue();

      expect(probe.checkCalls, greaterThan(0));
      expect(
        connects,
        1,
        reason: 'the gate passed through to connect, no app restart needed',
      );
    });

    test('a membership does not override the user\'s auto-sync choice — both '
        'must hold (FR-ST-1 not regressed by the new dimension)', () async {
      final probe = _FakeProbe();
      final gate = SyncGate(probe: probe, onGatePassed: () async {});
      addTearDown(gate.dispose);

      applySyncPreconditions(
        autoSyncEnabled: false,
        hasMembership: true,
        gate: gate,
      );
      await pumpEventQueue();

      expect(probe.checkCalls, 0);
    });
  });

  group('connectIfAllowed (#622 — the last word before db.connect())', () {
    test('no membership: never connects, even though a probe just passed — '
        'this is the membership-lost-mid-probe case, the one '
        'applySyncPreconditions alone cannot cover', () async {
      var connects = 0;

      await connectIfAllowed(
        alreadyConnected: false,
        hasMembership: false,
        connect: () async => connects++,
      );

      expect(connects, 0);
    });

    test('membership and not connected: connects exactly once', () async {
      var connects = 0;

      await connectIfAllowed(
        alreadyConnected: false,
        hasMembership: true,
        connect: () async => connects++,
      );

      expect(connects, 1);
    });

    test('already connected: does not connect again — a passing probe (or a '
        'concurrent manual "sync now") must not stack a second connect on a '
        'live engine', () async {
      var connects = 0;

      await connectIfAllowed(
        alreadyConnected: true,
        hasMembership: true,
        connect: () async => connects++,
      );

      expect(connects, 0);
    });

    test('awaits the connect it issues, so the gate\'s own callback does not '
        'resolve before the engine has actually been asked', () async {
      final started = Completer<void>();
      final finish = Completer<void>();
      var done = false;

      final call = connectIfAllowed(
        alreadyConnected: false,
        hasMembership: true,
        connect: () {
          started.complete();
          return finish.future;
        },
      ).then((_) => done = true);

      await started.future;
      await pumpEventQueue();
      expect(done, isFalse, reason: 'still inside connect()');

      finish.complete();
      await call;
      expect(done, isTrue);
    });
  });

  group('membershipChangeHandler (#622 — the composed membership '
      'listener)', () {
    test('true: remembers the new value AND starts the gate\'s probe loop — '
        'the org-created edge, sync begins with no reload', () async {
      final probe = _FakeProbe();
      final gate = SyncGate(probe: probe, onGatePassed: () async {});
      addTearDown(gate.dispose);
      bool? remembered;

      final handler = membershipChangeHandler(
        rememberMembership: (has) => remembered = has,
        autoSyncEnabled: () => true,
        gate: gate,
      );
      handler(true);
      await pumpEventQueue();

      expect(remembered, isTrue);
      expect(
        probe.checkCalls,
        greaterThan(0),
        reason: 'the probe loop is what turns into a connect attempt',
      );
    });

    test('false: remembers the loss AND stops the gate — a pending backoff '
        'fires no further probe (#125 membership loss)', () async {
      final probe = _FakeProbe(result: false); // keeps backing off
      final gate = SyncGate(
        probe: probe,
        onGatePassed: () async {},
        initialBackoff: const Duration(milliseconds: 20),
      );
      addTearDown(gate.dispose);
      gate.start();
      await pumpEventQueue();
      final callsWhileRunning = probe.checkCalls;
      expect(callsWhileRunning, greaterThan(0), reason: 'sanity check');
      bool? remembered;

      final handler = membershipChangeHandler(
        rememberMembership: (has) => remembered = has,
        autoSyncEnabled: () => true,
        gate: gate,
      );
      handler(false);
      // Longer than initialBackoff — a stop that failed to cancel the pending
      // timer would fire another probe inside this window.
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(remembered, isFalse);
      expect(probe.checkCalls, callsWhileRunning);
    });

    test('auto-sync off: still remembers the membership (the connector reads '
        'it on every credential fetch) but never starts the gate', () async {
      final probe = _FakeProbe();
      final gate = SyncGate(probe: probe, onGatePassed: () async {});
      addTearDown(gate.dispose);
      bool? remembered;

      final handler = membershipChangeHandler(
        rememberMembership: (has) => remembered = has,
        autoSyncEnabled: () => false,
        gate: gate,
      );
      handler(true);
      await pumpEventQueue();

      expect(remembered, isTrue);
      expect(probe.checkCalls, 0);
    });

    test(
      'reads the auto-sync setting at call time, not at wiring time — the '
      'listener is built once per session and outlives every toggle',
      () async {
        final probe = _FakeProbe();
        final gate = SyncGate(probe: probe, onGatePassed: () async {});
        addTearDown(gate.dispose);
        var autoSync = false;

        final handler = membershipChangeHandler(
          rememberMembership: (_) {},
          autoSyncEnabled: () => autoSync,
          gate: gate,
        );
        handler(true);
        await pumpEventQueue();
        expect(
          probe.checkCalls,
          0,
          reason: 'sanity check: auto-sync still off',
        );

        autoSync = true;
        handler(true);
        await pumpEventQueue();

        expect(probe.checkCalls, greaterThan(0));
      },
    );
  });
}
