import 'dart:async';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/sync/lww_delete.dart';
import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the durable delete-time LWW stamp (#276, FR-OF-1, D-12,
/// sync.md §4.3/§4.5) — the seam every repository deletes through and the
/// connector reads back off `CrudEntry.metadata`.
///
/// The SQL shape asserted here is not cosmetic: `UPDATE <table> SET
/// _deleted = TRUE, _metadata = ? WHERE id = ?` is the **only** statement the
/// PowerSync core extension turns into a DELETE op that carries metadata
/// (powersync-sqlite-core's `ps_view_delete2_` trigger — `INSTEAD OF UPDATE
/// ... WHEN NEW._deleted IS TRUE`; a plain `DELETE FROM` cannot carry any).
/// If this shape drifts, deletes silently lose their durable timestamp — or
/// stop deleting at all — so the shape itself is the contract under test.
/// A fake store can only check the shape, never that the core extension
/// honors it: that half is covered against a real database in
/// `powersync_delete_metadata_test.dart`.
void main() {
  group('deleteWithLwwStamp — the durable delete-time capture (#276)', () {
    test(
      'issues the metadata-carrying delete form, not a plain DELETE',
      () async {
        final store = _RecordingStore();

        await deleteWithLwwStamp(store, apiariesTable, 'apiary-1');

        expect(store.statements, hasLength(1));
        expect(
          store.statements.single.sql,
          'UPDATE $apiariesTable SET _deleted = TRUE, _metadata = ? WHERE id = ?',
        );
        expect(store.statements.single.args.last, 'apiary-1');
      },
    );

    test('stamps an ISO-8601 UTC device timestamp the connector can read '
        'back', () async {
      final store = _RecordingStore();
      final before = DateTime.now().toUtc();

      await deleteWithLwwStamp(store, apiariesTable, 'apiary-1');

      final after = DateTime.now().toUtc();
      final stamp = store.statements.single.args.first as String;
      expect(stamp, endsWith('Z'), reason: 'must be UTC, not local time');
      final parsed = DateTime.parse(stamp);
      expect(parsed.isUtc, isTrue);
      // It is the DELETE moment: bracketed by the wall clock either side of
      // the call, so a stamp taken from the wrong clock (local time, or an
      // epoch default) fails rather than merely parsing.
      expect(parsed.isBefore(before), isFalse);
      expect(parsed.isAfter(after), isFalse);
      // Round-trips through the connector's own read-back seam.
      expect(lwwTimestampFromDeleteMetadata(stamp), stamp);
    });

    test(
      'an injected clock is used verbatim (deterministic capture)',
      () async {
        final store = _RecordingStore();

        await deleteWithLwwStamp(
          store,
          todosTable,
          'todo-1',
          now: DateTime.utc(2026, 7, 14, 10),
        );

        expect(store.statements.single.args.first, '2026-07-14T10:00:00.000Z');
      },
    );

    test(
      'a local-time clock is normalized to UTC before it is stamped',
      () async {
        final store = _RecordingStore();
        final local = DateTime.utc(2026, 7, 14, 10).toLocal();

        await deleteWithLwwStamp(store, todosTable, 'todo-1', now: local);

        expect(store.statements.single.args.first, '2026-07-14T10:00:00.000Z');
      },
    );
  });

  group('lwwTimestampFromDeleteMetadata — defensive read-back', () {
    test('a null metadata (an op queued before #276, or any put/patch) '
        'yields null so the caller falls back', () {
      expect(lwwTimestampFromDeleteMetadata(null), isNull);
    });

    test('a non-timestamp metadata string is rejected rather than sent as '
        'the LWW comparator', () {
      expect(lwwTimestampFromDeleteMetadata(''), isNull);
      expect(lwwTimestampFromDeleteMetadata('not-a-timestamp'), isNull);
      expect(lwwTimestampFromDeleteMetadata('{"reason":"user"}'), isNull);
    });

    test('a valid ISO-8601 timestamp passes through verbatim — the exact '
        'bytes the server compares', () {
      expect(
        lwwTimestampFromDeleteMetadata('2026-07-14T10:00:00.000Z'),
        '2026-07-14T10:00:00.000Z',
      );
    });

    test('it rejects, it does not normalize — an accepted value is never '
        'rewritten (a zone-less string would be shifted by the device offset '
        'if it were)', () {
      expect(
        lwwTimestampFromDeleteMetadata('2026-07-14T10:00:00'),
        '2026-07-14T10:00:00',
      );
    });
  });
}

/// A [LocalStoreEngine] that records the statements it is handed — enough to
/// assert the exact SQL shape [deleteWithLwwStamp] must emit, with no
/// PowerSync database (the same NFR-ARC-2 seam every repository test uses).
class _RecordingStore implements LocalStoreEngine {
  final List<({String sql, List<Object?> args})> statements = [];

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    statements.add((sql: sql, args: args));
  }

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) => const Stream.empty();

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async => null;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => const [];

  @override
  Future<void> clear() async {}
}
