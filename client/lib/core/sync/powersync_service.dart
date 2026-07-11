import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';

import '../auth/auth_controller.dart';
import 'powersync_connector.dart';
import 'powersync_schema.dart';

const _dbFilename = 'beekeepingit.db';

/// Opens the on-device PowerSync database (local SQLite over OPFS/IndexedDB on
/// web) and connects it to the backend via [BeekeepingitConnector]. Read after
/// login, so `fetchCredentials` has a valid access token to mint a sync token.
///
/// Exposes the live [BeekeepingitConnector] instance too (not just the db):
/// #58's manual "sync now" needs to `disconnect()`/`connect()` the *same*
/// connector — re-creating one would drop its request-level state for no
/// reason and diverge from how `connect()` is normally called once at
/// startup.
final powerSyncProvider = FutureProvider<PowerSyncSession>((ref) async {
  final db = PowerSyncDatabase(schema: appSchema, path: _dbFilename);
  await db.initialize();

  final connector = BeekeepingitConnector(
    getAccessToken: () =>
        ref.read(authControllerProvider.notifier).accessToken(),
  );
  await db.connect(connector: connector);

  ref.onDispose(() async {
    await db.disconnect();
    await db.close();
    connector.dispose();
  });
  return PowerSyncSession(db: db, connector: connector);
});

/// The open database plus the connector it was connected with (see
/// [powerSyncProvider]'s doc comment for why both are needed).
class PowerSyncSession {
  const PowerSyncSession({required this.db, required this.connector});

  final PowerSyncDatabase db;
  final BeekeepingitConnector connector;
}
