import 'dart:async';

import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/shell/sync_status.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _connectedIdle = (
  connected: true,
  uploading: false,
  downloading: false,
  anyError: null,
);

const _offlineIdle = (
  connected: false,
  uploading: false,
  downloading: false,
  anyError: null,
);

// Builds a non-const instance from a runtime value each time, so two
// "equal" instances are genuinely distinct objects (not the same
// const-canonicalized instance) — otherwise a test using `const SyncStatus`
// literals would pass even without a custom `operator==`, since identical
// const expressions are canonicalized to the same object by the compiler.
SyncStatus _status({
  required int pendingCount,
  SyncConnectivity connectivity = SyncConnectivity.offline,
  bool syncing = true,
  bool hasError = false,
  SyncGateState gateState = SyncGateState.waitingForSignal,
}) => SyncStatus(
  connectivity: connectivity,
  pendingCount: pendingCount,
  syncing: syncing,
  hasError: hasError,
  gateState: gateState,
);

/// Unit tests for [combineSyncStatus] — the stream-combine step split out of
/// `_syncStatusStreamProvider` (HIGH #3: this provider body had zero test
/// coverage) so it's driven here with fake `Stream`s and a fake pending-count
/// supplier, independent of a real `PowerSyncDatabase`/`SyncGate` (mirrors
/// `powersync_connector.dart`'s `handleUploadResponse` extraction pattern).
void main() {
  group('combineSyncStatus', () {
    test(
      'emits an initial status right away, before either stream emits',
      (() async {
        final stream = combineSyncStatus(
          engineStatus: const Stream.empty(),
          initialEngineStatus: _connectedIdle,
          gateState: const Stream.empty(),
          initialGateState: SyncGateState.passed,
          pendingCount: () async => 3,
        );

        final status = await stream.first;

        expect(status.isOnline, isTrue);
        expect(status.pendingCount, 3);
        expect(status.gateState, SyncGateState.passed);
      }),
    );

    test(
      're-emits with the new connectivity when engineStatus changes',
      (() async {
        final engine = StreamController<EngineConnectivity>();
        addTearDown(engine.close);

        final statuses = <SyncStatus>[];
        final sub = combineSyncStatus(
          engineStatus: engine.stream,
          initialEngineStatus: _offlineIdle,
          gateState: const Stream.empty(),
          initialGateState: SyncGateState.passed,
          pendingCount: () async => 0,
        ).listen(statuses.add);
        addTearDown(sub.cancel);

        await pumpEventQueue();
        engine.add(_connectedIdle);
        await pumpEventQueue();

        expect(statuses.first.isOnline, isFalse);
        expect(statuses.last.isOnline, isTrue);
      }),
    );

    test(
      're-emits when gateState changes independently of engine status',
      (() async {
        final gate = StreamController<SyncGateState>();
        addTearDown(gate.close);

        final statuses = <SyncStatus>[];
        final sub = combineSyncStatus(
          engineStatus: const Stream.empty(),
          initialEngineStatus: _connectedIdle,
          gateState: gate.stream,
          initialGateState: SyncGateState.probing,
          pendingCount: () async => 0,
        ).listen(statuses.add);
        addTearDown(sub.cancel);

        await pumpEventQueue();
        gate.add(SyncGateState.waitingForSignal);
        await pumpEventQueue();

        expect(statuses.first.gateState, SyncGateState.probing);
        expect(statuses.last.gateState, SyncGateState.waitingForSignal);
        expect(statuses.last.isWaitingForSignal, isTrue);
      }),
    );

    test('syncing reflects uploading OR downloading', () async {
      final stream = combineSyncStatus(
        engineStatus: const Stream.empty(),
        initialEngineStatus: (
          connected: true,
          uploading: true,
          downloading: false,
          anyError: null,
        ),
        gateState: const Stream.empty(),
        initialGateState: SyncGateState.passed,
        pendingCount: () async => 0,
      );

      expect((await stream.first).syncing, isTrue);
    });

    test('hasError reflects a non-null anyError', () async {
      final stream = combineSyncStatus(
        engineStatus: const Stream.empty(),
        initialEngineStatus: (
          connected: true,
          uploading: false,
          downloading: false,
          anyError: Exception('boom'),
        ),
        gateState: const Stream.empty(),
        initialGateState: SyncGateState.passed,
        pendingCount: () async => 0,
      );

      expect((await stream.first).hasError, isTrue);
    });

    test(
      're-reads pendingCount on every re-emit, not just the first',
      () async {
        final engine = StreamController<EngineConnectivity>();
        addTearDown(engine.close);
        var callCount = 0;

        final statuses = <SyncStatus>[];
        final sub = combineSyncStatus(
          engineStatus: engine.stream,
          initialEngineStatus: _connectedIdle,
          gateState: const Stream.empty(),
          initialGateState: SyncGateState.passed,
          pendingCount: () async => ++callCount,
        ).listen(statuses.add);
        addTearDown(sub.cancel);

        await pumpEventQueue();
        engine.add(_connectedIdle);
        await pumpEventQueue();

        expect(statuses.map((s) => s.pendingCount), [1, 2]);
      },
    );

    test(
      'cancelling the combined stream cancels both source subscriptions',
      (() async {
        final engine = StreamController<EngineConnectivity>();
        final gate = StreamController<SyncGateState>();
        addTearDown(() {
          engine.close();
          gate.close();
        });

        final sub = combineSyncStatus(
          engineStatus: engine.stream,
          initialEngineStatus: _connectedIdle,
          gateState: gate.stream,
          initialGateState: SyncGateState.passed,
          pendingCount: () async => 0,
        ).listen((_) {});

        await pumpEventQueue();
        expect(engine.hasListener, isTrue);
        expect(gate.hasListener, isTrue);

        await sub.cancel();
        await pumpEventQueue();

        expect(engine.hasListener, isFalse);
        expect(gate.hasListener, isFalse);
      }),
    );
  });

  group('SyncStatus value equality (MEDIUM-2)', () {
    test('two distinct instances with the same fields are ==', () {
      final a = _status(pendingCount: 2);
      final b = _status(pendingCount: 2);

      expect(identical(a, b), isFalse, reason: 'test setup sanity check');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('instances differing in any field are not ==', () {
      final base = _status(pendingCount: 0, syncing: false);

      expect(
        base,
        isNot(
          equals(
            _status(
              pendingCount: 0,
              syncing: false,
              connectivity: SyncConnectivity.online,
            ),
          ),
        ),
      );
      expect(base, isNot(equals(_status(pendingCount: 1, syncing: false))));
      expect(base, isNot(equals(_status(pendingCount: 0, syncing: true))));
      expect(
        base,
        isNot(equals(_status(pendingCount: 0, syncing: false, hasError: true))),
      );
      expect(
        base,
        isNot(
          equals(
            _status(
              pendingCount: 0,
              syncing: false,
              gateState: SyncGateState.passed,
            ),
          ),
        ),
      );
    });
  });

  group('syncNowProvider — membership precondition (#622)', () {
    test('with no membership: declines immediately, without ever reaching for '
        'the sync session — a manual sync must not disconnect an engine the '
        'connect precondition would then refuse to reconnect', () {
      // `powerSyncProvider` never completes in this suite
      // (test/flutter_test_config.dart stubs the database open with a
      // never-completing future), so *completing at all* IS the assertion:
      // a "sync now" that read the session would hang here — and in
      // production would have run `db.disconnect()` first.
      //
      // Fake time (#705): "it completed inside a real 2-second window" is a
      // lower bound a starved isolate can miss while the code is perfectly
      // correct — the very shape #697/PR #704 removed from
      // `sync_gate_test.dart`. Under fake time the claim gets exact:
      // the decline lands at *zero elapsed time*.
      fakeAsync((async) {
        final container = ProviderContainer(
          overrides: [hasOrganizationProvider.overrideWithValue(false)],
        );
        addTearDown(container.dispose);

        var declined = false;
        unawaited(
          container.read(syncNowProvider)().then((_) => declined = true),
        );
        async.flushMicrotasks();

        expect(
          declined,
          isTrue,
          reason:
              'the membership precondition must be answered without ever '
              'awaiting the sync session',
        );
      });
    });

    test('with a membership: the same call does await the sync session — the '
        'guard above is about the missing membership, not about skipping the '
        'disconnect/connect cycle', () async {
      final container = ProviderContainer(
        overrides: [hasOrganizationProvider.overrideWithValue(true)],
      );
      addTearDown(container.dispose);

      // Mirror image of the test above: with the precondition met the call
      // parks on the (never-completing, stubbed) session open, so the timeout
      // firing is what proves the early return is membership-driven rather
      // than unconditional.
      //
      // This window stays on the real clock deliberately (#705): it is an
      // *upper* bound — "nothing completes in here" — so a starved isolate
      // makes it slower, never wrong, unlike the lower-bound window above.
      await expectLater(
        container
            .read(syncNowProvider)()
            .timeout(const Duration(milliseconds: 200)),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
