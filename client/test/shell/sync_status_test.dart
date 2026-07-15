import 'dart:async';

import 'package:beekeepingit_client/shell/sync_status.dart';
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
    test('emits an initial status right away, before either stream emits', (
      () async {
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

    test('re-emits with the new connectivity when engineStatus changes', (
      () async {
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

        engine.add(_connectedIdle);
        await pumpEventQueue();

        expect(statuses.last.isOnline, isTrue);
      }),
    );

    test('re-emits with the new gate state when gateState changes', (
      () async {
        final gate = StreamController<SyncGateState>();
        addTearDown(gate.close);

        final statuses = <SyncStatus>[];
        final sub = combineSyncStatus(
          engineStatus: const Stream.empty(),
          initialEngineStatus: _connectedIdle,
          gateState: gate.stream,
          initialGateState: SyncGateState.waitingForSignal,
          pendingCount: () async => 0,
        ).listen(statuses.add);
        addTearDown(sub.cancel);

        gate.add(SyncGateState.backoff);
        await pumpEventQueue();

        expect(statuses.last.gateState, SyncGateState.backoff);
      }),
    );

    test('cancelling the subscription detaches from both source streams', (
      () async {
        final engine = StreamController<EngineConnectivity>();
        addTearDown(engine.close);
        final gate = StreamController<SyncGateState>();
        addTearDown(gate.close);

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
}
