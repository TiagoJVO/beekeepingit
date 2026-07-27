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
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final rows = await _db.getAll(sql, args);
    return _rowsToMaps(rows);
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) {
    return _db.execute(sql, args);
  }

  /// Delegates to [ps.PowerSyncDatabase.disconnectAndClear] — disconnects
  /// the sync stream and wipes every locally-replicated row plus the upload
  /// queue. `clearLocal: true` (the default) is correct here and is relied on:
  /// BeekeepingIT's one local-only table, `sync_rejected_ops` (the rejected-op
  /// dead-letter, powersync_schema.dart), holds org data that must **not**
  /// outlive the session on a shared/lost/re-assigned device (§3.5, NFR-SEC-1),
  /// so it must be wiped too — and only the default `clearLocal: true` clears
  /// local-only tables ("to preserve data in local-only tables, set clearLocal
  /// to false"). A full clear is exactly what "log out on a shared device"
  /// (auth_controller.dart's `logout()`) and the #125 membership-loss purge
  /// both need; the dead-letter has no reason to survive either.
  @override
  Future<void> clear() => _db.disconnectAndClear();

  List<Map<String, Object?>> _rowsToMaps(ResultSet rs) =>
      rs.map(_rowToMap).toList();

  Map<String, Object?> _rowToMap(Row r) => Map<String, Object?>.from(r);
}
