import 'dart:async';

import 'package:beekeepingit_client/core/sync/powersync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group(
    'TeardownGuard (HIGH #2 — async ref.onDispose is fire-and-forget)',
    () {
      test('waitForPrior resolves immediately when nothing is pending', () async {
        final guard = TeardownGuard();

        // Would hang (and fail the test on timeout) if this incorrectly
        // waited on something.
        await guard.waitForPrior().timeout(const Duration(milliseconds: 200));
      });

      test(
        'waitForPrior waits for a registered teardown to actually finish '
        'before returning — the fix for the dispose race: without this, the '
        "next powerSyncProvider open could race the previous instance's "
        'db.close() and trigger PowerSync\'s own "Multiple instances" '
        'warning',
        () async {
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
        },
      );

      test(
        'registerTeardown is fire-and-forget — it does not block the caller '
        '(mirrors ref.onDispose being a void Function())',
        () {
          final guard = TeardownGuard();
          var teardownFinished = false;

          guard.registerTeardown(() async {
            await Future<void>.delayed(const Duration(seconds: 10));
            teardownFinished = true;
          });

          // registerTeardown returned synchronously without waiting for the
          // (10-second) teardown to finish.
          expect(teardownFinished, isFalse);
        },
      );

      test(
        'a second waitForPrior call after the first resolved does not wait '
        'again (no stale/leaked pending future)',
        () async {
          final guard = TeardownGuard();
          guard.registerTeardown(() async {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          });

          await guard.waitForPrior();

          // The first teardown is done; a second call must resolve
          // immediately rather than somehow re-waiting on it.
          await guard.waitForPrior().timeout(const Duration(milliseconds: 50));
        },
      );

      test(
        'each new registerTeardown supersedes the previous one for the '
        'purposes of the next waitForPrior call',
        () async {
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
        },
      );
    },
  );

  group(
    'rearmGateOnDisconnect (HIGH #3 — zero test coverage on sync-engine '
    'wiring logic)',
    () {
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

      test('never rearms while staying connected or starting disconnected', (
        () async {
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

      test(
        'rearms again on a second connected → disconnected transition '
        '(not just the first)',
        () async {
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
        },
      );

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
    },
  );
}
