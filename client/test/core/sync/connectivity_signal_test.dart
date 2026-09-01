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

    test('can be listened to more than once (broadcast contract)', () async {
      final signal = createConnectivitySignal();
      final stream = signal.onRestored;

      await expectLater(stream, emitsDone);
      await expectLater(stream, emitsDone);
    });
  });
}
