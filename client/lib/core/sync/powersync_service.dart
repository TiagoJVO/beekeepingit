import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';

import '../auth/auth_controller.dart';
import 'powersync_connector.dart';
import 'powersync_schema.dart';

const _dbFilename = 'beekeepingit.db';

/// Opens the on-device PowerSync database (local SQLite over OPFS/IndexedDB on
/// web) and connects it to the backend via [BeekeepingitConnector]. Read after
/// login, so `fetchCredentials` has a valid access token to mint a sync token.
final powerSyncProvider = FutureProvider<PowerSyncDatabase>((ref) async {
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
  });
  return db;
});
