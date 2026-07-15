import 'package:beekeepingit_client/shell/sync_status.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
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
