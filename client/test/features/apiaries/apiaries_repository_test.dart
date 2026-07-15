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
///
/// Models the two local tables the repository touches since #256: `apiaries`
/// ([rows]) and `apiary_counters` ([counterRows]) — the hive count reads
/// resolve through the counters list exactly like the real correlated
/// subquery (newest row per (apiary_id, counter_type), 0 when none).
class FakeLocalStore implements LocalStoreEngine {
  final List<Map<String, Object?>> rows = [];
  final List<Map<String, Object?>> counterRows = [];
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
    if (normalized.startsWith('INSERT INTO APIARY_COUNTERS')) {
      // (id, apiary_id, counter_type, value, created_at, updated_at)
      counterRows.add({
        'id': args[0],
        'apiary_id': args[1],
        'counter_type': args[2],
        'value': args[3],
        'created_at': args[4],
        'updated_at': args[5],
      });
    } else if (normalized.startsWith('INSERT INTO APIARIES')) {
      // (id, name, notes, place_label, location_lon, location_lat,
      // created_at, updated_at) — hive_count is no longer an apiaries
      // column (#256); place_label/location_lon/location_lat are new (#252).
      rows.add({
        'id': args[0],
        'name': args[1],
        'notes': args[2],
        'place_label': args[3],
        'location_lon': args[4],
        'location_lat': args[5],
        'created_at': args[6],
        'updated_at': args[7],
      });
    } else if (normalized.startsWith('UPDATE APIARY_COUNTERS')) {
      // SET value = ?, updated_at = ? WHERE id = ?
      final id = args[2];
      final row = counterRows.firstWhere((r) => r['id'] == id);
      row['value'] = args[0];
      row['updated_at'] = args[1];
    } else if (normalized.startsWith('UPDATE APIARIES')) {
      // SET name = ?, notes = ?, place_label = ?, location_lon = ?,
      // location_lat = ?, updated_at = ? WHERE id = ? (#252 adds
      // place_label/location_lon/location_lat to the pre-existing
      // name/notes/updated_at set).
      final id = args[6];
      final row = rows.firstWhere((r) => r['id'] == id);
      row['name'] = args[0];
      row['notes'] = args[1];
      row['place_label'] = args[2];
      row['location_lon'] = args[3];
      row['location_lat'] = args[4];
      row['updated_at'] = args[5];
    } else if (normalized.startsWith('DELETE FROM APIARIES')) {
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
    counterRows.clear();
    cleared = true;
    _notify();
  }

  List<Map<String, Object?>> _select(String sql, List<Object?> args) {
    final normalized = sql.toUpperCase();

    // The repository's counter reads: watchCountersFor's list (WHERE
    // apiary_id = ?) and _upsertCounter's existence probe (WHERE apiary_id =
    // ? AND counter_type = ?), both newest-first by updated_at.
    if (normalized.contains('FROM APIARY_COUNTERS') &&
        !normalized.contains('FROM APIARIES A')) {
      var results = List<Map<String, Object?>>.from(counterRows)
        ..sort(
          (a, b) =>
              (b['updated_at'] as String).compareTo(a['updated_at'] as String),
        );
      results = results.where((r) => r['apiary_id'] == args[0]).toList();
      if (normalized.contains('AND COUNTER_TYPE = ?')) {
        results = results.where((r) => r['counter_type'] == args[1]).toList();
      }
      return results;
    }

    // The apiaries reads (watchAll/getById): one row per apiary, hive_count
    // resolved through the newest matching counter row — the fake's
    // equivalent of the real correlated subquery + COALESCE 0.
    var results = [
      for (final r in rows) {...r, 'hive_count': _hiveCountFor(r['id'])},
    ];
    if (normalized.contains('WHERE A.ID = ?')) {
      results = results.where((r) => r['id'] == args[0]).toList();
    }
    if (normalized.contains('ORDER BY A.CREATED_AT DESC, A.NAME')) {
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

  int _hiveCountFor(Object? apiaryId) {
    final matches =
        counterRows
            .where(
              (r) => r['apiary_id'] == apiaryId && r['counter_type'] == 'hive',
            )
            .toList()
          ..sort(
            (a, b) => (b['updated_at'] as String).compareTo(
              a['updated_at'] as String,
            ),
          );
    return matches.isEmpty ? 0 : matches.first['value'] as int;
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

    group('watchById() (#HIGH-1 narrow per-id watch)', () {
      test(
        'emits the single matching row and re-emits after a write to it',
        () async {
          final id = await repo.create(name: 'Serra Norte', hiveCount: 2);
          final names = <String?>[];
          final sub = repo.watchById(id).listen((a) => names.add(a?.name));
          addTearDown(sub.cancel);

          await pumpEventQueue();
          expect(names.last, 'Serra Norte');

          await repo.update(id, name: 'Serra Norte Renomeada');
          await pumpEventQueue();

          expect(names.last, 'Serra Norte Renomeada');
        },
      );

      test('emits null for an id that does not exist', () async {
        final apiary = await repo.watchById('missing').first;
        expect(apiary, isNull);
      });

      test('is unaffected by a write to a DIFFERENT apiary (the whole point of '
          'the narrow watch vs. watchAll())', () async {
        final id = await repo.create(name: 'Serra Norte', hiveCount: 2);
        final other = await repo.create(name: 'Vale Sul', hiveCount: 1);
        final names = <String?>[];
        final sub = repo.watchById(id).listen((a) => names.add(a?.name));
        addTearDown(sub.cancel);

        await pumpEventQueue();
        expect(names, ['Serra Norte']);

        await repo.update(other, name: 'Vale Sul Renomeado');
        await pumpEventQueue();

        // The fake's watch() re-runs the query on every write regardless
        // of table (it has no per-row change filtering, mirroring the
        // real engine's watch semantics of "re-run on any relevant
        // write") — what matters is the RESULT stays the same apiary,
        // unaffected by the other row's change.
        expect(names.every((n) => n == 'Serra Norte'), isTrue);
      });
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

        // The initial empty emission, then at least one re-emission showing
        // the created apiary. create() now issues two local writes (the
        // apiary row + its hive counter row, #256), so the fake's change
        // notifier fires more than once — assert the invariant (starts at 0,
        // converges to exactly one apiary) rather than a brittle exact
        // emission count that's an artifact of how many writes create() does.
        // The real PowerSync engine coalesces watch emissions per
        // transaction; this fake notifies per execute().
        expect(emissions.first, 0);
        expect(emissions.last, 1);
        expect(emissions.every((n) => n == 0 || n == 1), isTrue);
      },
    );
  });

  group('ApiariesRepository location + place_label (#252)', () {
    test(
      'create() writes location_lon/location_lat/place_label together',
      () async {
        final id = await repo.create(
          name: 'Encosta',
          hiveCount: 1,
          placeLabel: 'Montargil',
          locationLon: -8.611,
          locationLat: 41.148,
        );

        final apiary = await repo.getById(id);
        expect(apiary!.locationLon, -8.611);
        expect(apiary.locationLat, 41.148);
        expect(apiary.placeLabel, 'Montargil');
        expect(apiary.hasLocation, isTrue);
      },
    );

    test('create() without location leaves both columns null', () async {
      final id = await repo.create(name: 'Sem Local', hiveCount: 0);

      final apiary = await repo.getById(id);
      expect(apiary!.locationLon, isNull);
      expect(apiary.locationLat, isNull);
      expect(apiary.hasLocation, isFalse);
      expect(apiary.placeLabel, isNull);
    });

    test(
      'update() with locationProvided sets a previously-unset location',
      () async {
        final id = await repo.create(name: 'Encosta', hiveCount: 0);

        await repo.update(
          id,
          locationLon: -9.0,
          locationLat: 41.5,
          locationProvided: true,
        );

        final apiary = await repo.getById(id);
        expect(apiary!.locationLon, -9.0);
        expect(apiary.locationLat, 41.5);
        expect(apiary.hasLocation, isTrue);
      },
    );

    test('update() with locationProvided and null lon/lat clears the location '
        '(#252 AC: the location is editable and clearable)', () async {
      final id = await repo.create(
        name: 'Encosta',
        hiveCount: 0,
        locationLon: -9.0,
        locationLat: 41.5,
      );

      await repo.update(id, locationProvided: true);

      final apiary = await repo.getById(id);
      expect(apiary!.locationLon, isNull);
      expect(apiary.locationLat, isNull);
      expect(apiary.hasLocation, isFalse);
    });

    test(
      'update() without locationProvided leaves an existing location untouched',
      () async {
        final id = await repo.create(
          name: 'Encosta',
          hiveCount: 0,
          locationLon: -9.0,
          locationLat: 41.5,
        );

        await repo.update(id, name: 'Encosta Norte');

        final apiary = await repo.getById(id);
        expect(apiary!.name, 'Encosta Norte');
        expect(apiary.locationLon, -9.0);
        expect(apiary.locationLat, 41.5);
      },
    );

    test(
      'update() with placeLabelProvided sets/clears place_label independently '
      'of location',
      () async {
        final id = await repo.create(
          name: 'Encosta',
          hiveCount: 0,
          locationLon: -9.0,
          locationLat: 41.5,
        );

        await repo.update(
          id,
          placeLabel: 'São Domingos',
          placeLabelProvided: true,
        );

        var apiary = await repo.getById(id);
        expect(apiary!.placeLabel, 'São Domingos');
        expect(apiary.locationLon, -9.0, reason: 'location untouched');

        await repo.update(id, placeLabelProvided: true);

        apiary = await repo.getById(id);
        expect(apiary!.placeLabel, isNull);
      },
    );

    test(
      'a location-only update does not write an unrelated field change',
      () async {
        final id = await repo.create(name: 'Encosta', hiveCount: 0);

        await repo.update(
          id,
          locationLon: -9.0,
          locationLat: 41.5,
          locationProvided: true,
        );

        final apiary = await repo.getById(id);
        expect(apiary!.name, 'Encosta');
        expect(apiary.notes, isNull);
      },
    );
  });

  group('ApiariesRepository counters (#256)', () {
    test('create() writes the hive count as a counter row, not an apiaries '
        'column', () async {
      final id = await repo.create(name: 'Serra Norte', hiveCount: 4);

      expect(store.counterRows, hasLength(1));
      final counter = store.counterRows.single;
      expect(counter['apiary_id'], id);
      expect(counter['counter_type'], 'hive');
      expect(counter['value'], 4);
      // The apiaries row itself carries no hive_count (#256: column retired;
      // reads resolve it through the counter).
      expect(store.rows.single.containsKey('hive_count'), isFalse);
    });

    test('hive count reads 0 when no counter row exists (#256 AC: hives '
        'always displays, 0 default)', () async {
      // Seed an apiary row directly with NO counter row — the shape of a
      // pre-counter row or a hive-less create replicated from the server.
      store.rows.add({
        'id': 'a1',
        'name': 'Sem Contador',
        'notes': null,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
        'location_lon': null,
        'location_lat': null,
      });

      final apiary = await repo.getById('a1');
      expect(apiary, isNotNull);
      expect(apiary!.hiveCount, 0);
    });

    test('update() with a changed hiveCount upserts the one counter row '
        '(never a second row for the same type)', () async {
      final id = await repo.create(name: 'Encosta', hiveCount: 2);

      await repo.update(id, hiveCount: 7);
      await repo.update(id, hiveCount: 12);

      expect(
        store.counterRows.where((r) => r['apiary_id'] == id),
        hasLength(1),
        reason: 'one row per (apiary, counter_type) — upsert, not insert',
      );
      expect(store.counterRows.single['value'], 12);
      expect((await repo.getById(id))!.hiveCount, 12);
    });

    test(
      'a hive-only update never touches the apiaries row (decoupled '
      'records: no LWW/audit churn on the apiary for a counter edit)',
      () async {
        final id = await repo.create(name: 'Encosta', hiveCount: 2);
        final apiaryUpdatedAt = store.rows.single['updated_at'];

        await repo.update(id, hiveCount: 9);

        expect(store.rows.single['updated_at'], apiaryUpdatedAt);
        expect(store.counterRows.single['value'], 9);
      },
    );

    test('a name-only update never touches the counter row (whose LWW stamp '
        'must not supersede another device\'s pending hive edit)', () async {
      final id = await repo.create(name: 'Encosta', hiveCount: 2);
      final counterUpdatedAt = store.counterRows.single['updated_at'];

      await repo.update(id, name: 'Encosta Norte');

      expect(store.counterRows.single['updated_at'], counterUpdatedAt);
      expect(store.rows.single['name'], 'Encosta Norte');
    });

    test('an update passing the unchanged hive value writes nothing', () async {
      final id = await repo.create(name: 'Encosta', hiveCount: 2);
      final counterUpdatedAt = store.counterRows.single['updated_at'];

      await repo.update(id, hiveCount: 2);

      expect(store.counterRows.single['updated_at'], counterUpdatedAt);
    });

    test(
      'delete() leaves counter rows in place (counters have no delete op '
      '— the server rejects one; orphans are unreachable via reads)',
      () async {
        final id = await repo.create(name: 'Temp', hiveCount: 3);

        await repo.delete(id);

        expect(await repo.getById(id), isNull);
        expect(
          store.counterRows.where((r) => r['apiary_id'] == id),
          hasLength(1),
          reason: 'no counter DELETE may ever be queued',
        );
      },
    );

    test('watchCountersFor() emits typed rows, newest-per-type, known types '
        'first', () async {
      final id = await repo.create(name: 'Encosta', hiveCount: 2);
      // An unknown, newer-server counter type replicated down — must come
      // through (after the known types) so a future client can render it,
      // and so the detail screen's label-less skip logic (not this
      // repository) is what decides visibility.
      store.counterRows.add({
        'id': 'c-nucs',
        'apiary_id': id,
        'counter_type': 'nucs',
        'value': 3,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      });
      // A stale duplicate hive row (the transient optimistic window —
      // repository doc comment): the newest one must win.
      store.counterRows.add({
        'id': 'c-stale',
        'apiary_id': id,
        'counter_type': 'hive',
        'value': 99,
        'created_at': '2020-01-01T00:00:00Z',
        'updated_at': '2020-01-01T00:00:00Z',
      });

      final counters = await repo.watchCountersFor(id).first;

      expect(counters, hasLength(2));
      expect(counters[0].counterType, 'hive');
      expect(
        counters[0].value,
        2,
        reason: 'newest hive row wins, not the stale 99',
      );
      expect(counters[1].counterType, 'nucs');
      expect(counters[1].value, 3);
    });
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
        expect(store.counterRows, isNotEmpty);

        await store.clear();

        expect(store.rows, isEmpty);
        expect(store.counterRows, isEmpty);
        expect(store.cleared, isTrue);
      },
    );
  });
}
