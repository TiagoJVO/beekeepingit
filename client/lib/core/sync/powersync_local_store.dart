import 'package:powersync/powersync.dart' as ps;
import 'package:powersync/sqlite3_common.dart';

import 'local_store.dart';

/// The (only, today) [LocalStoreEngine] implementation, wrapping a
/// [ps.PowerSyncDatabase] (NFR-ARC-2, #55). This is the one file that is
/// allowed to know PowerSync's concrete types outside `core/sync/`; feature
/// repositories depend on [LocalStoreEngine] instead.
class PowerSyncLocalStore implements LocalStoreEngine {
  PowerSyncLocalStore(this._db);

  final ps.PowerSyncDatabase _db;

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) {
    return _db.watch(sql, parameters: args).map(_rowsToMaps);
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final row = await _db.getOptional(sql, args);
    return row == null ? null : _rowToMap(row);
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) {
    return _db.execute(sql, args);
  }

  /// Delegates to [ps.PowerSyncDatabase.disconnectAndClear] — disconnects
  /// the sync stream and wipes every locally-replicated row plus the upload
  /// queue. `clearLocal: true` (the default) is correct here: BeekeepingIT
  /// has no local-only tables the way PowerSync's own docs use that flag for
  /// (e.g. draft-only tables kept across logout), so a full clear is what
  /// "log out on a shared device" (auth_controller.dart's `logout()`) and
  /// #125's planned `disconnectAndClear` both need.
  @override
  Future<void> clear() => _db.disconnectAndClear();

  List<Map<String, Object?>> _rowsToMaps(ResultSet rs) =>
      rs.map(_rowToMap).toList();

  Map<String, Object?> _rowToMap(Row r) => r.toMap();
}
