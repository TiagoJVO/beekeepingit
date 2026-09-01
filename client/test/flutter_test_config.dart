import 'dart:async';

import 'package:beekeepingit_client/core/sync/powersync_service.dart';
import 'package:powersync/powersync.dart';

/// Suite-wide test setup — `flutter test` loads this file automatically for
/// every test under `test/` (and its subdirectories) and runs `testMain`
/// through it.
///
/// It exists for one reason (#286): keep the test suite from ever opening a
/// real [PowerSyncDatabase].
///
/// Opening one registers the database path in PowerSync's process-wide
/// active-instance registry from the constructor, and only `close()`
/// deregisters it — which never runs under `testWidgets`, because
/// `PowerSyncDatabase.initialize()` stays pending there (its real
/// disk/isolate I/O doesn't progress under the widget binding's fake-async
/// clock), leaving `powerSyncProvider` suspended before it ever registers
/// its `ref.onDispose` teardown. So the second and every later open in the
/// same test process logged `[PowerSync] WARNING: Multiple instances for the
/// same database have been detected` — 281 lines in a local run of this
/// suite, 58 in the CI `build client` job the issue was filed from. None of
/// those tests were testing sync: they render a screen whose sync-status
/// pill (or a repository provider) transitively watches `powerSyncProvider`.
///
/// Stubbing the open with a future that never completes preserves what those
/// tests already observe — `powerSyncProvider` stays pending, so every
/// widget downstream of it keeps rendering its loading/default state — while
/// removing the leaked handle, the stray on-disk `beekeepingit.db`, and the
/// warning. A test that needs a *resolved* sync session overrides the
/// Riverpod providers it depends on (`syncStatusProvider`, a repository's
/// stream provider, ...), as `account_screen_test.dart` and
/// `app_shell_test.dart` already do; `await`ing `powerSyncProvider` itself
/// without an override hangs until the test times out.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugOpenPowerSyncDatabase = () => Completer<PowerSyncDatabase>().future;
  await testMain();
}
