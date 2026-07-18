import 'dart:async';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalStoreEngine] fake purpose-built to interpret the exact
/// SQL shapes [JourneysRepository] issues — mirrors
/// activities_repository_test.dart's/apiaries_repository_test.dart's own
/// `FakeLocalStore` convention (NFR-ARC-2's seam: testable against a plain
/// Dart fake, no PowerSync/platform channel involved). Models the TWO local
/// tables the repository touches: `journeys` ([rows]) and
/// `journey_plan_items` ([planRows]).
class FakeLocalStore implements LocalStoreEngine {
  final List<Map<String, Object?>> rows = [];
  final List<Map<String, Object?>> planRows = [];
  final _watchController = StreamController<void>.broadcast();

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
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => _select(sql, args);

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    final normalized = sql.trim().toUpperCase();
    if (normalized.startsWith('INSERT INTO $journeysTable'.toUpperCase())) {
      // (id, name, main_activity_type, status, created_at, updated_at)
      rows.add({
        'id': args[0],
        'organization_id': null,
        'name': args[1],
        'main_activity_type': args[2],
        'status': args[3],
        'created_at': args[4],
        'updated_at': args[5],
      });
    } else if (normalized.startsWith(
      'INSERT INTO $journeyPlanItemsTable'.toUpperCase(),
    )) {
      // (id, journey_id, apiary_id, created_at)
      planRows.add({
        'id': args[0],
        'journey_id': args[1],
        'apiary_id': args[2],
        'created_at': args[3],
      });
    } else if (normalized.startsWith('UPDATE $journeysTable'.toUpperCase())) {
      // SET name = ?, main_activity_type = ?, status = ?, updated_at = ?
      // WHERE id = ?
      final id = args[4];
      final row = rows.firstWhere((r) => r['id'] == id);
      row['name'] = args[0];
      row['main_activity_type'] = args[1];
      row['status'] = args[2];
      row['updated_at'] = args[3];
    } else if (normalized.startsWith(
      'DELETE FROM $journeyPlanItemsTable'.toUpperCase(),
    )) {
      final id = args[0];
      planRows.removeWhere((r) => r['id'] == id);
    } else if (normalized.startsWith(
      'DELETE FROM $journeysTable'.toUpperCase(),
    )) {
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
    planRows.clear();
    _notify();
  }

  List<Map<String, Object?>> _select(String sql, List<Object?> args) {
    final normalized = sql.toUpperCase();
    if (normalized.contains(journeyPlanItemsTable.toUpperCase())) {
      var results = List<Map<String, Object?>>.from(planRows);
      if (normalized.contains('WHERE JOURNEY_ID = ?')) {
        results = results.where((r) => r['journey_id'] == args[0]).toList();
      }
      results.sort(
        (a, b) =>
            (a['created_at'] as String).compareTo(b['created_at'] as String),
      );
      return results;
    }

    var results = List<Map<String, Object?>>.from(rows);
    if (normalized.contains('WHERE ID = ?')) {
      results = results.where((r) => r['id'] == args[0]).toList();
    } else if (normalized.contains(
      'ORGANIZATION_ID = ? OR ORGANIZATION_ID IS NULL',
    )) {
      final orgId = args[0];
      results = results
          .where(
            (r) =>
                r['organization_id'] == orgId || r['organization_id'] == null,
          )
          .toList();
    }
    results.sort(
      (a, b) =>
          (b['created_at'] as String).compareTo(a['created_at'] as String),
    );
    return results;
  }

  void dispose() => _watchController.close();
}

void main() {
  late FakeLocalStore store;
  late JourneysRepository repo;

  setUp(() {
    store = FakeLocalStore();
    repo = JourneysRepository(store);
  });

  tearDown(() => store.dispose());

  group('JourneysRepository.create()', () {
    test(
      'inserts a local journeys row that always starts open (D-21)',
      () async {
        final id = await repo.create(
          name: 'Colheita de Primavera',
          mainActivityType: 'harvest',
          apiaryIds: const ['a1', 'a2'],
        );

        expect(id, isNotEmpty);
        expect(store.rows, hasLength(1));
        final row = store.rows.single;
        expect(row['name'], 'Colheita de Primavera');
        expect(row['main_activity_type'], 'harvest');
        expect(row['status'], journeyStatusOpen);
        // Never set locally (server-derived) — see the class doc.
        expect(row['organization_id'], isNull);
      },
    );

    test('inserts one plan item per apiary id', () async {
      final id = await repo.create(
        name: 'Journey',
        mainActivityType: 'harvest',
        apiaryIds: const ['a1', 'a2', 'a3'],
      );

      expect(store.planRows, hasLength(3));
      expect(store.planRows.map((r) => r['apiary_id']).toSet(), {
        'a1',
        'a2',
        'a3',
      });
      expect(store.planRows.every((r) => r['journey_id'] == id), isTrue);
    });

    test('an empty apiary_ids list is valid — no plan items required at '
        'create time', () async {
      await repo.create(
        name: 'Journey',
        mainActivityType: 'generic',
        apiaryIds: const [],
      );
      expect(store.planRows, isEmpty);
    });
  });

  group('JourneysRepository.getById()', () {
    test('returns null for an unknown id', () async {
      expect(await repo.getById('missing'), isNull);
    });

    test('returns the journey with its plan apiary ids', () async {
      final id = await repo.create(
        name: 'Journey',
        mainActivityType: 'feeding',
        apiaryIds: const ['a1', 'a2'],
      );

      final journey = await repo.getById(id);

      expect(journey, isNotNull);
      expect(journey!.name, 'Journey');
      expect(journey.mainActivityType, 'feeding');
      expect(journey.status, journeyStatusOpen);
      expect(journey.isOpen, isTrue);
      expect(journey.apiaryIds.toSet(), {'a1', 'a2'});
    });
  });

  group('JourneysRepository.update() plan diffing (#45, FR-JO-4)', () {
    test('removes an apiary no longer in the requested set', () async {
      final id = await repo.create(
        name: 'Journey',
        mainActivityType: 'harvest',
        apiaryIds: const ['a1', 'a2'],
      );

      await repo.update(
        id,
        name: 'Journey',
        mainActivityType: 'harvest',
        status: journeyStatusOpen,
        apiaryIds: const ['a1'],
      );

      final journey = await repo.getById(id);
      expect(journey!.apiaryIds, ['a1']);
    });

    test('adds a newly-requested apiary', () async {
      final id = await repo.create(
        name: 'Journey',
        mainActivityType: 'harvest',
        apiaryIds: const ['a1'],
      );

      await repo.update(
        id,
        name: 'Journey',
        mainActivityType: 'harvest',
        status: journeyStatusOpen,
        apiaryIds: const ['a1', 'a2'],
      );

      final journey = await repo.getById(id);
      expect(journey!.apiaryIds.toSet(), {'a1', 'a2'});
    });

    test('leaves an unaffected apiary\'s plan-item row untouched (same '
        'local id, not deleted-and-reinserted)', () async {
      final id = await repo.create(
        name: 'Journey',
        mainActivityType: 'harvest',
        apiaryIds: const ['a1', 'a2'],
      );
      final originalRowId = store.planRows.firstWhere(
        (r) => r['apiary_id'] == 'a1',
      )['id'];

      await repo.update(
        id,
        name: 'Journey',
        mainActivityType: 'harvest',
        status: journeyStatusOpen,
        apiaryIds: const ['a1', 'a3'], // a2 removed, a3 added, a1 unchanged
      );

      final a1Row = store.planRows.firstWhere((r) => r['apiary_id'] == 'a1');
      expect(a1Row['id'], originalRowId);
    });

    test('updates name/main_activity_type/status', () async {
      final id = await repo.create(
        name: 'Old name',
        mainActivityType: 'harvest',
        apiaryIds: const [],
      );

      await repo.update(
        id,
        name: 'New name',
        mainActivityType: 'feeding',
        status: journeyStatusOpen,
        apiaryIds: const [],
      );

      final journey = await repo.getById(id);
      expect(journey!.name, 'New name');
      expect(journey.mainActivityType, 'feeding');
    });
  });

  group('JourneysRepository.close() (#45, D-21)', () {
    test('sets status to closed, keeping name/type/plan unchanged', () async {
      final id = await repo.create(
        name: 'Journey',
        mainActivityType: 'harvest',
        apiaryIds: const ['a1'],
      );

      await repo.close(id);

      final journey = await repo.getById(id);
      expect(journey!.status, journeyStatusClosed);
      expect(journey.isOpen, isFalse);
      expect(journey.name, 'Journey');
      expect(journey.apiaryIds, ['a1']);
    });

    test('is a no-op for an unknown id', () async {
      await repo.close('missing'); // must not throw
      expect(store.rows, isEmpty);
    });
  });

  group('JourneysRepository.delete()', () {
    test(
      'removes the journey row but leaves plan items in place (mirrors '
      'apiaries_repository.dart\'s own apiary+counter delete convention)',
      () async {
        final id = await repo.create(
          name: 'Journey',
          mainActivityType: 'harvest',
          apiaryIds: const ['a1'],
        );

        await repo.delete(id);

        expect(await repo.getById(id), isNull);
        expect(store.planRows, hasLength(1));
      },
    );
  });

  group('JourneysRepository.watchAll() org-scoping (FR-TEN-2)', () {
    test('returns an empty stream when the organization id is null', () async {
      final journeys = await repo.watchAll(organizationId: null).first;
      expect(journeys, isEmpty);
    });

    test('excludes another organization\'s journeys', () async {
      store.rows.addAll([
        {
          'id': 'own-1',
          'organization_id': 'org-a',
          'name': 'Own journey',
          'main_activity_type': 'harvest',
          'status': journeyStatusOpen,
          'created_at': '2026-06-01T00:00:00Z',
          'updated_at': '2026-06-01T00:00:00Z',
        },
        {
          'id': 'foreign-1',
          'organization_id': 'org-b',
          'name': 'Foreign journey',
          'main_activity_type': 'harvest',
          'status': journeyStatusOpen,
          'created_at': '2026-06-02T00:00:00Z',
          'updated_at': '2026-06-02T00:00:00Z',
        },
      ]);

      final journeys = await repo.watchAll(organizationId: 'org-a').first;

      expect(journeys.map((j) => j.id).toList(), ['own-1']);
    });

    test('still shows a freshly-created, not-yet-synced local row (null '
        'organization_id)', () async {
      await repo.create(
        name: 'Journey',
        mainActivityType: 'harvest',
        apiaryIds: const [],
      );

      final journeys = await repo.watchAll(organizationId: 'org-a').first;

      expect(journeys, hasLength(1));
      expect(journeys.single.organizationId, isNull);
    });
  });
}
