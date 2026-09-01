import 'dart:async';
import 'dart:convert';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/dgav/stock_declarations_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalStoreEngine] fake that interprets the exact SQL shapes
/// [StockDeclarationsRepository] issues — not a general SQL engine, matching
/// the same approach apiaries_repository_test.dart takes. This is what
/// NFR-ARC-2's seam buys: the repository is testable with no PowerSync
/// database, no platform channel, no network.
class FakeLocalStore implements LocalStoreEngine {
  final List<Map<String, Object?>> rows = [];
  final _watchController = StreamController<void>.broadcast();

  void _notify() => _watchController.add(null);

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) async* {
    yield _select();
    yield* _watchController.stream.map((_) => _select());
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final results = _select();
    return results.isEmpty ? null : results.first;
  }

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => _select();

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    final normalized = sql.trim().toUpperCase();
    if (normalized.startsWith('INSERT INTO STOCK_DECLARATIONS')) {
      // (id, dgav_registration_number, declared_on, total_hive_count,
      //  breakdown, notes, created_at, updated_at)
      rows.add({
        'id': args[0],
        'dgav_registration_number': args[1],
        'declared_on': args[2],
        'total_hive_count': args[3],
        'breakdown': args[4],
        'notes': args[5],
        'created_at': args[6],
        'updated_at': args[7],
      });
    } else if (normalized.startsWith('DELETE FROM STOCK_DECLARATIONS')) {
      rows.removeWhere((r) => r['id'] == args[0]);
    } else {
      throw UnsupportedError('FakeLocalStore.execute: unhandled SQL: $sql');
    }
    _notify();
  }

  @override
  Future<void> clear() async {
    rows.clear();
    _notify();
  }

  /// The repository's only read: everything, ordered by declared_on then
  /// created_at, both descending.
  List<Map<String, Object?>> _select() {
    final results = List<Map<String, Object?>>.from(rows);
    results.sort((a, b) {
      final byDate = (b['declared_on'] as String).compareTo(
        a['declared_on'] as String,
      );
      if (byDate != 0) return byDate;
      return (b['created_at'] as String).compareTo(a['created_at'] as String);
    });
    return results;
  }

  void dispose() => _watchController.close();
}

void main() {
  late FakeLocalStore store;
  late StockDeclarationsRepository repo;

  setUp(() {
    store = FakeLocalStore();
    repo = StockDeclarationsRepository(store);
  });

  tearDown(() => store.dispose());

  group('StockDeclarationsRepository (FR-AP-10, #298)', () {
    test(
      'create() records the declared date, total and registration number',
      () async {
        await repo.create(
          dgavRegistrationNumber: 'PT-123456',
          declaredOn: DateTime(2026, 9, 12),
          totalHiveCount: 42,
        );

        final declaration = (await repo.watchAll().first).single;
        expect(declaration.dgavRegistrationNumber, 'PT-123456');
        expect(declaration.declaredOn, DateTime(2026, 9, 12));
        expect(declaration.totalHiveCount, 42);
      },
    );

    test('create() stores declared_on as a plain YYYY-MM-DD calendar date, not '
        'a timezone-bearing instant — the September window must not depend on '
        "the reader's zone", () async {
      await repo.create(
        dgavRegistrationNumber: 'PT-123456',
        declaredOn: DateTime(2026, 9, 12, 23, 45),
        totalHiveCount: 42,
      );
      expect(store.rows.single['declared_on'], '2026-09-12');
    });

    test('create() round-trips the per-apiary breakdown snapshot', () async {
      await repo.create(
        dgavRegistrationNumber: 'PT-123456',
        declaredOn: DateTime(2026, 9, 12),
        totalHiveCount: 30,
        breakdown: const [
          StockDeclarationApiary(
            apiaryId: 'a1',
            name: 'Serra Norte',
            hiveCount: 18,
          ),
          StockDeclarationApiary(
            apiaryId: 'a2',
            name: 'Monte Alto',
            hiveCount: 12,
          ),
        ],
      );

      final declaration = (await repo.watchAll().first).single;
      expect(declaration.breakdown, hasLength(2));
      expect(declaration.breakdown.first.name, 'Serra Norte');
      expect(declaration.breakdown.first.hiveCount, 18);
      expect(declaration.breakdown.last.apiaryId, 'a2');
    });

    test(
      'the breakdown is stored as JSON-encoded TEXT — PowerSync has no local '
      'JSON column type, and the connector decodes it back on upload',
      () async {
        await repo.create(
          dgavRegistrationNumber: 'PT-123456',
          declaredOn: DateTime(2026, 9, 12),
          totalHiveCount: 18,
          breakdown: const [
            StockDeclarationApiary(
              apiaryId: 'a1',
              name: 'Serra Norte',
              hiveCount: 18,
            ),
          ],
        );

        final stored = store.rows.single['breakdown'] as String;
        expect(jsonDecode(stored), isA<List<dynamic>>());
      },
    );

    test('create() defaults to an empty breakdown', () async {
      await repo.create(
        dgavRegistrationNumber: 'PT-123456',
        declaredOn: DateTime(2026, 9, 12),
        totalHiveCount: 0,
      );
      expect((await repo.watchAll().first).single.breakdown, isEmpty);
    });

    test('a malformed breakdown yields an empty one rather than making the '
        'whole declaration unreadable — the declared date and total are the '
        'record, the breakdown is supporting detail', () async {
      await repo.create(
        dgavRegistrationNumber: 'PT-123456',
        declaredOn: DateTime(2026, 9, 12),
        totalHiveCount: 42,
      );
      store.rows.single['breakdown'] = 'not json at all';

      final declaration = (await repo.watchAll().first).single;
      expect(declaration.breakdown, isEmpty);
      expect(declaration.totalHiveCount, 42);
    });

    test('watchAll() returns newest declaration date first', () async {
      await repo.create(
        dgavRegistrationNumber: 'PT-123456',
        declaredOn: DateTime(2024, 9, 10),
        totalHiveCount: 10,
      );
      await repo.create(
        dgavRegistrationNumber: 'PT-123456',
        declaredOn: DateTime(2026, 9, 10),
        totalHiveCount: 30,
      );
      await repo.create(
        dgavRegistrationNumber: 'PT-123456',
        declaredOn: DateTime(2025, 9, 10),
        totalHiveCount: 20,
      );

      final dates = (await repo.watchAll().first)
          .map((d) => d.declaredOn.year)
          .toList();
      expect(dates, [2026, 2025, 2024]);
    });

    test('watchAll() spans every registration number, so an organization '
        'covering several beekeepers can group them', () async {
      await repo.create(
        dgavRegistrationNumber: 'PT-111',
        declaredOn: DateTime(2026, 9, 10),
        totalHiveCount: 10,
      );
      await repo.create(
        dgavRegistrationNumber: 'PT-222',
        declaredOn: DateTime(2026, 9, 11),
        totalHiveCount: 20,
      );

      final numbers = (await repo.watchAll().first)
          .map((d) => d.dgavRegistrationNumber)
          .toSet();
      expect(numbers, {'PT-111', 'PT-222'});
    });

    test('delete() removes a mis-entered declaration — unlike a counter, a '
        'declaration has its own lifecycle', () async {
      final id = await repo.create(
        dgavRegistrationNumber: 'PT-123456',
        declaredOn: DateTime(2026, 9, 12),
        totalHiveCount: 42,
      );
      await repo.delete(id);
      expect(await repo.watchAll().first, isEmpty);
    });

    test('notes are optional and round-trip when set', () async {
      await repo.create(
        dgavRegistrationNumber: 'PT-123456',
        declaredOn: DateTime(2026, 9, 12),
        totalHiveCount: 42,
        notes: 'Submetida via portal do IFAP.',
      );
      expect(
        (await repo.watchAll().first).single.notes,
        'Submetida via portal do IFAP.',
      );
    });
  });

  group('formatDeclaredOn / parseDeclaredOn', () {
    test('round-trip a calendar date', () {
      expect(formatDeclaredOn(DateTime(2026, 9, 4)), '2026-09-04');
      expect(parseDeclaredOn('2026-09-04'), DateTime(2026, 9, 4));
    });

    test('pad single-digit months and days', () {
      expect(formatDeclaredOn(DateTime(2026, 1, 2)), '2026-01-02');
    });

    test('a null or unparseable value falls back to the epoch rather than '
        'throwing, so one bad row cannot take the whole log with it', () {
      expect(parseDeclaredOn(null), DateTime.fromMillisecondsSinceEpoch(0));
      expect(
        parseDeclaredOn('nonsense'),
        DateTime.fromMillisecondsSinceEpoch(0),
      );
    });
  });
}
