import 'package:beekeepingit_client/core/sync/connectivity_signal.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConnectivitySignal (VM/non-web stub)', () {
    // The web implementation (browser `online` event) can't run under the VM
    // test target, so what's asserted here is the *stub's* contract: it must
    // degrade to "never emits" rather than throwing, so `powerSyncProvider`
    // can wire it unconditionally and `SyncGate` simply falls back to its own
    // probe/backoff schedule (#240).
    test('is constructible and yields a stream that never emits', () async {
      final signal = createConnectivitySignal();

      await expectLater(signal.onRestored, emitsDone);
    });

    test('is broadcast, as the interface promises', () {
      // `SyncGate` is one listener today, but the contract is documented as
      // broadcast so a second consumer doesn't silently fail at runtime.
      expect(createConnectivitySignal().onRestored.isBroadcast, isTrue);
    });
  });
}
