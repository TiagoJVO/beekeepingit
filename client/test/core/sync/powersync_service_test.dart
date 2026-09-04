import 'dart:async';

import 'package:beekeepingit_client/core/auth/auth_controller.dart';
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
  int disposeCalls = 0;

  @override
  Future<bool> check() async {
    checkCalls++;
    return result;
  }

  @override
  void dispose() => disposeCalls++;
}

/// A minimal [AuthController] stand-in returning a fixed token — mirrors
/// `test/features/organization/organization_repository_test.dart`'s own fake,
/// so the #675 composition test can exercise a *real* `Ref` (and a real
/// disposal) without any OIDC discovery or network.
class _FakeAuthController extends AuthController {
  @override
  Future<AuthSession?> build() async => null;

  @override
  Future<String?> accessToken() async => 'tok';
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

    test('waitForPrior awaits EVERY teardown still in flight, not just the '
        'most recently registered one', () async {
      // The previous shape of this test only asserted that the *second*
      // teardown had run, which the old overwriting `_pending = teardown()`
      // satisfied while silently dropping the first from the wait. Two
      // disposals in quick succession are real here (logout into a fresh
      // login; #125's purge landing on top of one), and a dropped teardown
      // means the next session can open the database while the previous
      // `close()` is still holding the file. The slow-then-fast ordering is
      // what makes the bug observable: with the old code `waitForPrior`
      // returned as soon as the *fast* one finished.
      final guard = TeardownGuard();
      final done = <String>[];

      guard.registerTeardown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        done.add('slow-first');
      });
      guard.registerTeardown(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        done.add('fast-second');
      });

      await guard.waitForPrior();

      expect(
        done,
        containsAll(<String>['slow-first', 'fast-second']),
        reason:
            'waitForPrior returned while an earlier teardown was still '
            'in flight — the next PowerSyncDatabase could open against a '
            'file the previous close() still holds',
      );
    });
  });

  group('sessionScopedAccessToken (#675 — the connector outlives the provider '
      'that built it, so its token read must be session-scoped; FR-OF-1, '
      'NFR-MNT-1)', () {
    test('reads the current token on every call — nothing is cached or '
        'captured, because an access token expires and the session that owns '
        'it is the only thing that can mint a fresh one', () async {
      var token = 'first';
      var reads = 0;

      final getAccessToken = sessionScopedAccessToken(
        sessionAlive: () => true,
        readAccessToken: () async {
          reads++;
          return token;
        },
      );

      expect(await getAccessToken(), 'first');
      expect(reads, 1);

      token = 'second';

      expect(
        await getAccessToken(),
        'second',
        reason:
            'a closure that captured the value would keep handing PowerSync '
            'an expired token forever',
      );
      expect(reads, 2);
    });

    test('once the session is gone the token resolves to null AND the reader '
        'is never called — that is what keeps a later refactor from reaching '
        'into a disposed notifier (#675)', () async {
      var alive = true;
      var reads = 0;

      final getAccessToken = sessionScopedAccessToken(
        sessionAlive: () => alive,
        readAccessToken: () async {
          reads++;
          return 'tok';
        },
      );

      expect(await getAccessToken(), 'tok');
      final readsWhileAlive = reads;

      alive = false;

      expect(
        await getAccessToken(),
        isNull,
        reason:
            'null is BeekeepingitConnector.fetchCredentials\' own "no '
            'credentials — stay disconnected" answer',
      );
      expect(
        reads,
        readsWhileAlive,
        reason:
            'the whole point: after disposal the read must not happen at all, '
            'not merely have its result discarded',
      );
    });

    test('the liveness check and the read land in the same synchronous turn — '
        'a call issued while the session was alive still resolves with the '
        'token even though the session died before it was awaited (pins the '
        'deliberately non-async shape, #675)', () async {
      var alive = true;
      final pendingRead = Completer<String?>();

      final getAccessToken = sessionScopedAccessToken(
        sessionAlive: () => alive,
        readAccessToken: () => pendingRead.future,
      );

      // Issued while alive; awaited only after the session is gone.
      final inFlight = getAccessToken();
      alive = false;
      pendingRead.complete('tok');

      expect(
        await inFlight,
        'tok',
        reason:
            'an implementation that re-checked liveness after an await would '
            'drop a perfectly valid in-flight credential fetch',
      );
    });

    test('composed with a real Ref: after the container is disposed the '
        'guarded closure answers null where a bare ref.read throws — the '
        'regression #675 is about, pinned end to end', () async {
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(_FakeAuthController.new),
        ],
      );
      // A throwaway stand-in for powerSyncProvider's own body: it builds the
      // two closures from the same `ref`, so what is compared is exactly the
      // wiring, not two different lifecycles.
      final closures =
          Provider<
            ({
              Future<String?> Function() guarded,
              Future<String?> Function() unguarded,
            })
          >((ref) {
            return (
              guarded: sessionScopedAccessToken(
                sessionAlive: () => ref.mounted,
                readAccessToken: () =>
                    ref.read(authControllerProvider.notifier).accessToken(),
              ),
              unguarded: () =>
                  ref.read(authControllerProvider.notifier).accessToken(),
            );
          });
      final (:guarded, :unguarded) = container.read(closures);

      // Sanity check: both work while the session is alive.
      expect(await guarded(), 'tok');
      expect(await unguarded(), 'tok');

      container.dispose();

      expect(
        await guarded(),
        isNull,
        reason:
            'PowerSync asking for credentials during the fire-and-forget '
            'teardown must get "stay disconnected", not an exception',
      );

      // Control assertion, not a behavioural requirement: this documents the
      // hazard #675 exists for. Matched on the message rather than the type
      // because riverpod 3.4.1 marks UnmountedRefException `@internal`, so
      // naming it here would trip `invalid_use_of_internal_member`.
      expect(
        unguarded,
        throwsA(
          predicate<Object>(
            (e) => e.toString().contains('after it has been disposed'),
          ),
        ),
      );
    });
  });

  // Read this before trusting the two subscription tests below as evidence for
  // #675. `statusSub.cancel()` was ALREADY synchronous before that change:
  // [TeardownGuard.registerTeardown] invokes its callback immediately, and a
  // Dart async body runs synchronously up to its first await, so in
  // `await statusSub.cancel()` the call itself was always evaluated in the
  // dispose turn. Both tests therefore pass against the pre-#675 code and are
  // FORWARD-looking guards — they fail if someone later moves the cancel below
  // an await — not proof that #675 fixed them. The test that actually
  // discriminates is the gate/probe one: those two genuinely moved out of the
  // async half.
  group('sessionTeardown (#675 — what a stream or listener can reach is '
      'detached in the SYNCHRONOUS half of ref.onDispose; FR-OF-1, '
      'NFR-MNT-1)', () {
    test('cancels the status subscription synchronously, with no await in '
        'between — a forward-looking guard: this fails if cancel() is ever '
        'moved below an await, where the rearm callback it feeds could still '
        'read a disposed ref (it was already synchronous before #675)', () {
      final controller = StreamController<bool>();
      addTearDown(controller.close);
      final probe = _FakeProbe();
      final gate = SyncGate(probe: probe, onGatePassed: () async {});
      final statusSub = rearmGateOnDisconnect(
        connectedStream: controller.stream,
        rearm: () {},
        onConnectedChanged: (_) {},
      );

      final disposeSession = sessionTeardown(
        statusSub: statusSub,
        gate: gate,
        probe: probe,
        disconnect: () async {},
        close: () async {},
        disposeConnector: () {},
        // A local guard, never the process-wide one: this test must not
        // leave a pending teardown behind for an unrelated test to await.
        guard: TeardownGuard(),
      );
      disposeSession();

      expect(controller.hasListener, isFalse);
    });

    test('(also pre-#675 behaviour, kept as a guard) after disposal no further '
        'status event can reach the rearm callback '
        '— the callback that reads autoSyncEnabledProvider off the very ref '
        'being disposed (#675)', () async {
      final controller = StreamController<bool>();
      addTearDown(controller.close);
      final probe = _FakeProbe();
      final gate = SyncGate(probe: probe, onGatePassed: () async {});
      var rearms = 0;
      final statusSub = rearmGateOnDisconnect(
        connectedStream: controller.stream,
        rearm: () => rearms++,
        onConnectedChanged: (_) {},
      );

      final disposeSession = sessionTeardown(
        statusSub: statusSub,
        gate: gate,
        probe: probe,
        disconnect: () async {},
        close: () async {},
        disposeConnector: () {},
        guard: TeardownGuard(),
      );
      disposeSession();

      // The exact shape production sees: the engine reports one last
      // connected → disconnected transition while it is being shut down.
      controller.add(true);
      controller.add(false);
      await pumpEventQueue();

      expect(rearms, 0);
    });

    test('THE discriminating guard for #675: disposes the gate and the probe '
        'synchronously, where they previously went a microtask late — so a '
        'probe passing mid-teardown can no longer call connect() while '
        'disconnect()/close() are already in flight', () async {
      final controller = StreamController<bool>();
      addTearDown(controller.close);
      final probe = _FakeProbe();
      final gate = SyncGate(probe: probe, onGatePassed: () async {});
      final statusSub = rearmGateOnDisconnect(
        connectedStream: controller.stream,
        rearm: () {},
        onConnectedChanged: (_) {},
      );

      final disposeSession = sessionTeardown(
        statusSub: statusSub,
        gate: gate,
        probe: probe,
        disconnect: () async {},
        close: () async {},
        disposeConnector: () {},
        guard: TeardownGuard(),
      );
      disposeSession();

      expect(probe.disposeCalls, 1);

      // A disposed gate ignores rearm(), so the probe loop never restarts.
      gate.rearm();
      await pumpEventQueue();

      expect(probe.checkCalls, 0);
    });

    test('the async remainder still runs disconnect → close → disposeConnector '
        'in that order, and waitForPrior does not resolve until it has '
        'finished (the TeardownGuard contract is unchanged)', () async {
      final controller = StreamController<bool>();
      addTearDown(controller.close);
      final probe = _FakeProbe();
      final gate = SyncGate(probe: probe, onGatePassed: () async {});
      final statusSub = rearmGateOnDisconnect(
        connectedStream: controller.stream,
        rearm: () {},
        onConnectedChanged: (_) {},
      );
      final guard = TeardownGuard();
      final order = <String>[];

      final disposeSession = sessionTeardown(
        statusSub: statusSub,
        gate: gate,
        probe: probe,
        disconnect: () async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          order.add('disconnect');
        },
        close: () async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          order.add('close');
        },
        disposeConnector: () => order.add('disposeConnector'),
        guard: guard,
      );
      disposeSession();

      expect(
        order,
        isEmpty,
        reason:
            'sanity check: dispose returned without awaiting the async '
            'remainder, mirroring ref.onDispose being a void Function()',
      );

      await guard.waitForPrior();

      expect(order, ['disconnect', 'close', 'disposeConnector']);
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
