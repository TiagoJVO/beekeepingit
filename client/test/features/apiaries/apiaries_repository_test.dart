import 'dart:async';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalStoreEngine] fake, purpose-built to interpret the exact
/// SQL shapes [ApiariesRepository] issues — not a general SQL engine. This is
/// what NFR-ARC-2's seam buys: the repository is testable against a plain
/// Dart fake, with no PowerSync database, no `powersync` package, no
/// platform channel — the whole point of depending on [LocalStoreEngine]
/// rather than a concrete `PowerSyncDatabase`.
class FakeLocalStore implements LocalStoreEngine {
  final List<Map<String, Object?>> rows = [];
  final _watchController = StreamController<void>.broadcast();
  bool cleared = false;

  void _notify() => _watchController.add(null);

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) async* {
    yield _select(sql, args);
    yield* _watchController.stream.map((_) => _select(sql, args));
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final results = _select(sql, args);
    return results.isEmpty ? null : results.first;
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    final normalized = sql.trim().toUpperCase();
    if (normalized.startsWith('INSERT')) {
      rows.add({
        'id': args[0],
        'name': args[1],
        'hive_count': args[2],
        'notes': args[3],
        'created_at': args[4],
        'updated_at': args[5],
        'location_lon': null,
        'location_lat': null,
      });
    } else if (normalized.startsWith('UPDATE')) {
      // UPDATE apiaries SET name=?, hive_count=?, notes=?, updated_at=? WHERE id=?
      final id = args[4];
      final row = rows.firstWhere((r) => r['id'] == id);
      row['name'] = args[0];
      row['hive_count'] = args[1];
      row['notes'] = args[2];
      row['updated_at'] = args[3];
    } else if (normalized.startsWith('DELETE')) {
      final id = args[0];
      rows.removeWhere((r) => r['id'] == id);
    } else {
      throw UnsupportedError('FakeLocalStore.execute: unhandled SQL: $sql');
    }
    _notify();
  }

  @override
  Future<void> clear() async {
    rows.clear();
    cleared = true;
    _notify();
  }

  List<Map<String, Object?>> _select(String sql, List<Object?> args) {
    final normalized = sql.toUpperCase();
    var results = List<Map<String, Object?>>.from(rows);
    if (normalized.contains('WHERE ID = ?')) {
      results = results.where((r) => r['id'] == args[0]).toList();
    }
    if (normalized.contains('ORDER BY CREATED_AT DESC, NAME')) {
      results.sort((a, b) {
        final byCreated = (b['created_at'] as String).compareTo(
          a['created_at'] as String,
        );
        return byCreated != 0
            ? byCreated
            : (a['name'] as String).compareTo(b['name'] as String);
      });
    }
    return results;
  }

  void dispose() => _watchController.close();
}

void main() {
  late FakeLocalStore store;
  late ApiariesRepository repo;

  setUp(() {
    store = FakeLocalStore();
    repo = ApiariesRepository(store);
  });

  tearDown(() => store.dispose());

  group('ApiariesRepository', () {
    test('create() inserts a local row and returns its generated id', () async {
      final id = await repo.create(name: 'Serra Norte', hiveCount: 4);

      expect(id, isNotEmpty);
      final apiary = await repo.getById(id);
      expect(apiary, isNotNull);
      expect(apiary!.name, 'Serra Norte');
      expect(apiary.hiveCount, 4);
      expect(apiary.notes, isNull);
    });

    test('getById() returns null for an unknown id', () async {
      expect(await repo.getById('missing'), isNull);
    });

    test('update() changes only the given fields, keeping the rest', () async {
      final id = await repo.create(
        name: 'Encosta Norte',
        hiveCount: 2,
        notes: 'original notes',
      );

      await repo.update(id, hiveCount: 5);

      final apiary = await repo.getById(id);
      expect(apiary!.name, 'Encosta Norte'); // unchanged
      expect(apiary.hiveCount, 5); // updated
      expect(apiary.notes, 'original notes'); // unchanged
    });

    test(
      'update() clears notes when notesProvided is true with a null value',
      () async {
        final id = await repo.create(
          name: 'Vale',
          hiveCount: 1,
          notes: 'to be cleared',
        );

        await repo.update(id, notesProvided: true);

        final apiary = await repo.getById(id);
        expect(apiary!.notes, isNull);
      },
    );

    test('update() on an unknown id is a no-op', () async {
      await repo.update('missing', name: 'x');
      expect(store.rows, isEmpty);
    });

    test('delete() removes the row', () async {
      final id = await repo.create(name: 'Temp', hiveCount: 0);
      await repo.delete(id);

      expect(await repo.getById(id), isNull);
    });

    test(
      'watchAll() emits the current set and re-emits after a write',
      () async {
        final emissions = <int>[];
        final sub = repo.watchAll().listen(
          (rows) => emissions.add(rows.length),
        );
        addTearDown(sub.cancel);

        await pumpEventQueue();
        expect(emissions, [0]);

        await repo.create(name: 'A', hiveCount: 1);
        await pumpEventQueue();

        expect(emissions, [0, 1]);
      },
    );
  });

  group('LocalStoreEngine.clear()', () {
    // Not called by ApiariesRepository today — #55 exposes it on the
    // interface for #125's planned logout data-wipe to wire up later
    // (local_store.dart's doc comment). Exercised directly here so the
    // seam itself is covered, independent of that future caller.
    test(
      'wipes every locally-replicated row via the engine directly',
      () async {
        await repo.create(name: 'To be wiped', hiveCount: 1);
        expect(store.rows, isNotEmpty);

        await store.clear();

        expect(store.rows, isEmpty);
        expect(store.cleared, isTrue);
      },
    );
  });
}
