import 'dart:io';

import 'package:beekeepingit_client/core/sync/lww_delete.dart';
import 'package:beekeepingit_client/core/sync/powersync_connector.dart';
import 'package:beekeepingit_client/core/sync/powersync_local_store.dart';
import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:powersync/powersync.dart';

/// The one test in this suite that drives a **real** [PowerSyncDatabase]
/// rather than a `LocalStoreEngine` fake (#276, FR-OF-1, D-12, sync.md §4.5).
///
/// It exists because the durable delete stamp lives in a part of the system a
/// fake cannot model: the local schema's `trackMetadata` flag and the SQLite
/// **triggers the PowerSync core extension generates from it**. A fake store
/// happily "executes" any SQL you hand it, so every unit test around this
/// change would still pass if `UPDATE <table> SET _deleted = TRUE,
/// _metadata = ?` silently stopped deleting the row, or queued a `patch`
/// instead of a `delete`, or dropped the metadata. That is precisely the
/// failure mode worth a real database:
///
/// - a plain `DELETE FROM <table>` **cannot** carry metadata, so the core
///   extension emits a second trigger, `ps_view_delete2_`, declared
///   `INSTEAD OF UPDATE ... WHEN NEW._deleted IS TRUE`, and guards the
///   ordinary update trigger with `WHEN NEW._deleted IS NOT TRUE`;
/// - so the form asserted here is the *only* one that both removes the local
///   row and queues a `delete` op carrying the captured timestamp.
///
/// Runs on the plain Dart/Flutter test VM (no device, no server, no sync
/// connection) — nothing here connects: the assertions are on what the local
/// CRUD queue contains, which is exactly what `uploadData` would drain.
void main() {
  late Directory dir;
  late PowerSyncDatabase db;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    dir = await Directory.systemTemp.createTemp('beekeepingit-lww-delete');
    db = PowerSyncDatabase(
      schema: appSchema,
      path: '${dir.path}${Platform.pathSeparator}test.db',
    );
    await db.initialize();
  });

  tearDown(() async {
    await db.close();
    // Best-effort: on Windows a SQLite file handle can outlive close() just
    // long enough to make the delete throw, and a cleanup failure must not be
    // reported as a failure of the test that just passed. The directory is
    // under the OS temp dir either way.
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Leave it for the OS to reap.
    }
  });

  /// Drains and completes the queued transaction, returning its ops — so each
  /// step below asserts only on what its own write queued.
  Future<List<CrudEntry>> drain() async {
    final tx = await db.getNextCrudTransaction();
    if (tx == null) return const [];
    final ops = tx.crud;
    await tx.complete();
    return ops;
  }

  test('deleteWithLwwStamp removes the local row AND queues a delete op '
      'carrying the captured timestamp', () async {
    await db.execute(
      'INSERT INTO $apiariesTable (id, name, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      [
        'a1',
        'Serra Norte',
        '2026-07-14T09:00:00.000Z',
        '2026-07-14T09:00:00.000Z',
      ],
    );
    await drain();

    await deleteWithLwwStamp(
      PowerSyncLocalStore(db),
      apiariesTable,
      'a1',
      now: DateTime.utc(2026, 7, 14, 10),
    );

    // The row really is gone locally — the statement is a delete, not an
    // update that leaves a ghost row behind.
    expect(await db.getAll('SELECT id FROM $apiariesTable'), isEmpty);

    final ops = await drain();
    expect(ops, hasLength(1));
    expect(ops.single.op, UpdateType.delete);
    expect(ops.single.table, apiariesTable);
    expect(ops.single.id, 'a1');
    expect(ops.single.opData, isNull, reason: 'a delete carries no payload');
    expect(ops.single.metadata, '2026-07-14T10:00:00.000Z');
  });

  test('the connector resolves that op\'s wire updated_at from the durable '
      'metadata — with an EMPTY cache, i.e. after an app restart', () async {
    await db.execute(
      'INSERT INTO $apiariesTable (id, name, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      [
        'a1',
        'Serra Norte',
        '2026-07-14T09:00:00.000Z',
        '2026-07-14T09:00:00.000Z',
      ],
    );
    await drain();
    await deleteWithLwwStamp(
      PowerSyncLocalStore(db),
      apiariesTable,
      'a1',
      now: DateTime.utc(2026, 7, 14, 10),
    );

    final entry = (await drain()).single;
    // A fresh, empty cache is exactly what a relaunched app has.
    final updatedAt = lwwTimestampFor(
      entry.id,
      entry.opData,
      <String, String>{},
      metadata: entry.metadata,
    );

    expect(updatedAt, '2026-07-14T10:00:00.000Z');
  });

  test('an ordinary edit is unaffected: still a patch, still no metadata, '
      'still its own updated_at on the wire', () async {
    await db.execute(
      'INSERT INTO $todosTable (id, title, created_at, updated_at) '
      'VALUES (?, ?, ?, ?)',
      [
        't1',
        'Feed hive 4',
        '2026-07-14T09:00:00.000Z',
        '2026-07-14T09:00:00.000Z',
      ],
    );
    await drain();

    await db.execute(
      'UPDATE $todosTable SET title = ?, updated_at = ? WHERE id = ?',
      ['Feed hive 5', '2026-07-14T11:00:00.000Z', 't1'],
    );

    final entry = (await drain()).single;
    expect(entry.op, UpdateType.patch);
    expect(entry.metadata, isNull);
    expect(
      lwwTimestampFor(
        entry.id,
        entry.opData,
        <String, String>{},
        metadata: entry.metadata,
      ),
      '2026-07-14T11:00:00.000Z',
    );
  });

  test('ApiariesRepository.delete() goes through the stamping path end to '
      'end against a real database', () async {
    final repo = ApiariesRepository(PowerSyncLocalStore(db));
    // create() writes the apiary row and its hive-counter row as two separate
    // local transactions, so drain until the queue is empty before deleting.
    final id = await repo.create(name: 'Temp', hiveCount: 1);
    while ((await drain()).isNotEmpty) {}

    await repo.delete(id);

    expect(await repo.getById(id), isNull);
    final ops = await drain();
    expect(ops.single.op, UpdateType.delete);
    expect(ops.single.id, id);
    expect(lwwTimestampFromDeleteMetadata(ops.single.metadata), isNotNull);
  });
}
