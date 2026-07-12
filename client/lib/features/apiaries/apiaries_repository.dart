import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';
import 'package:powersync/sqlite3_common.dart';
import 'package:uuid/uuid.dart';

import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';

/// A local apiary row (name + hive count + optional free-text notes,
/// FR-AP-8/#196).
class Apiary {
  const Apiary({
    required this.id,
    required this.name,
    required this.hiveCount,
    this.notes,
  });

  final String id;
  final String name;
  final int hiveCount;
  final String? notes;
}

/// Reads and writes apiaries against the local PowerSync SQLite. Every write
/// is local-first and queued for the write-back seam (walking-skeleton.md
/// §4.4); the client never calls the apiaries REST write API directly. The
/// server derives `organization_id` from the token, so writes here omit it.
class ApiariesRepository {
  ApiariesRepository(this._db);

  final PowerSyncDatabase _db;
  static const _uuid = Uuid();

  Stream<List<Apiary>> watchAll() {
    return _db
        .watch(
          'SELECT id, name, hive_count, notes FROM $apiariesTable '
          'ORDER BY created_at DESC, name',
        )
        .map((rs) => rs.map(_fromRow).toList());
  }

  Future<Apiary?> getById(String id) async {
    final row = await _db.getOptional(
      'SELECT id, name, hive_count, notes FROM $apiariesTable WHERE id = ?',
      [id],
    );
    return row == null ? null : _fromRow(row);
  }

  Future<String> create({
    required String name,
    required int hiveCount,
    String? notes,
  }) async {
    final id = _uuid.v4();
    final now = _nowIso();
    await _db.execute(
      'INSERT INTO $apiariesTable (id, name, hive_count, notes, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [id, name, hiveCount, notes, now, now],
    );
    return id;
  }

  /// Updates the given fields of an existing apiary. `notes` uses a
  /// present-vs-absent sentinel via [notesProvided] (rather than treating
  /// null as "leave unchanged") so a caller can explicitly clear notes back
  /// to empty — mirroring the server's PATCH semantics (write.go's
  /// `notesSet`/`fields["notes"]` presence check).
  Future<void> update(
    String id, {
    String? name,
    int? hiveCount,
    String? notes,
    bool notesProvided = false,
  }) async {
    final current = await getById(id);
    if (current == null) return;
    await _db.execute(
      'UPDATE $apiariesTable SET name = ?, hive_count = ?, notes = ?, updated_at = ? WHERE id = ?',
      [
        name ?? current.name,
        hiveCount ?? current.hiveCount,
        notesProvided ? notes : current.notes,
        _nowIso(),
        id,
      ],
    );
  }

  Future<void> delete(String id) =>
      _db.execute('DELETE FROM $apiariesTable WHERE id = ?', [id]);

  Apiary _fromRow(Row r) => Apiary(
    id: r['id'] as String,
    name: r['name'] as String,
    hiveCount: (r['hive_count'] as int?) ?? 0,
    notes: r['notes'] as String?,
  );

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

final apiariesRepositoryProvider = FutureProvider<ApiariesRepository>((
  ref,
) async {
  final session = await ref.watch(powerSyncProvider.future);
  return ApiariesRepository(session.db);
});

/// Live list of the org's apiaries, straight from local SQLite (offline-first).
final apiariesStreamProvider = StreamProvider<List<Apiary>>((ref) async* {
  final repo = await ref.watch(apiariesRepositoryProvider.future);
  yield* repo.watchAll();
});
