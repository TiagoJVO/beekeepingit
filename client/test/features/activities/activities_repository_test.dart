import 'dart:async';
import 'dart:convert';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/sync/powersync_connector.dart';
import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalStoreEngine] fake purpose-built to interpret the exact
/// SQL shapes [ActivitiesRepository] issues — mirrors apiaries_repository_
/// test.dart's own `FakeLocalStore` convention (NFR-ARC-2's seam: testable
/// against a plain Dart fake, no PowerSync/platform channel involved).
class FakeLocalStore implements LocalStoreEngine {
  final List<Map<String, Object?>> rows = [];
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
    if (normalized.startsWith('INSERT INTO ACTIVITIES')) {
      // (id, apiary_id, journey_id, type, occurred_at, attributes,
      // created_at, updated_at) — create() never sets performed_by/
      // organization_id (activities_repository.dart's own doc: both are
      // server-derived, populated only once the write round-trips through
      // sync). journey_id (#46/D-21) IS set locally now, optionally.
      rows.add({
        'id': args[0],
        'apiary_id': args[1],
        'journey_id': args[2],
        'performed_by': null,
        'organization_id': null,
        'type': args[3],
        'occurred_at': args[4],
        'attributes': args[5],
        'created_at': args[6],
        'updated_at': args[7],
      });
    } else if (normalized.startsWith('UPDATE ACTIVITIES')) {
      // update()'s SET type = ?, occurred_at = ?, attributes = ?,
      // updated_at = ? WHERE id = ?
      executeCalls++;
      final id = args[4];
      final i = rows.indexWhere((r) => r['id'] == id);
      if (i != -1) {
        rows[i] = {
          ...rows[i],
          'type': args[0],
          'occurred_at': args[1],
          'attributes': args[2],
          'updated_at': args[3],
        };
      }
    } else {
      throw UnsupportedError('FakeLocalStore.execute: unhandled SQL: $sql');
    }
    _notify();
  }

  /// Count of [execute] calls that actually reached an UPDATE ACTIVITIES
  /// branch — used to assert a no-op update() genuinely performs no write
  /// (#378), not just that the row's own fields happen to be unchanged.
  int executeCalls = 0;

  @override
  Future<void> clear() async {
    rows.clear();
    _notify();
  }

  List<Map<String, Object?>> _select(String sql, List<Object?> args) {
    final normalized = sql.toUpperCase();
    var results = List<Map<String, Object?>>.from(rows);

    if (normalized.contains('WHERE ID = ?')) {
      results = results.where((r) => r['id'] == args[0]).toList();
    } else if (normalized.contains('WHERE APIARY_ID = ?')) {
      results = results.where((r) => r['apiary_id'] == args[0]).toList();
    } else if (normalized.contains('WHERE JOURNEY_ID = ?')) {
      results = results.where((r) => r['journey_id'] == args[0]).toList();
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

    results.sort((a, b) {
      final byDate = (b['occurred_at'] as String).compareTo(
        a['occurred_at'] as String,
      );
      return byDate != 0
          ? byDate
          : (b['created_at'] as String).compareTo(a['created_at'] as String);
    });
    return results;
  }

  void dispose() => _watchController.close();
}

void main() {
  late FakeLocalStore store;
  late ActivitiesRepository repo;

  setUp(() {
    store = FakeLocalStore();
    repo = ActivitiesRepository(store);
  });

  tearDown(() => store.dispose());

  group('ActivitiesRepository.create()', () {
    test(
      'inserts a local row with the given fields and JSON-encoded attributes',
      () async {
        final id = await repo.create(
          apiaryId: 'a1',
          type: 'harvest',
          occurredAt: '2026-06-01',
          attributes: {'honey_supers': 4},
        );

        expect(id, isNotEmpty);
        expect(store.rows, hasLength(1));
        final row = store.rows.single;
        expect(row['apiary_id'], 'a1');
        expect(row['type'], 'harvest');
        expect(row['occurred_at'], '2026-06-01');
        expect(jsonDecode(row['attributes'] as String), {'honey_supers': 4});
        // Never set locally (server-derived) — see the class doc.
        expect(row['performed_by'], isNull);
        expect(row['organization_id'], isNull);
      },
    );
  });

  group('ActivitiesRepository.update() (#378)', () {
    test('with identical type/occurredAt/attributes performs no write at all — '
        'a saved-but-unchanged edit must not queue a sync op', () async {
      final id = await repo.create(
        apiaryId: 'a1',
        type: 'harvest',
        occurredAt: '2026-06-01',
        attributes: {'honey_supers': 4},
      );
      final updatedAtBefore = store.rows.single['updated_at'];

      await repo.update(
        id,
        type: 'harvest',
        occurredAt: '2026-06-01',
        attributes: {'honey_supers': 4},
      );

      expect(store.executeCalls, 0, reason: 'no write means no sync op');
      expect(store.rows.single['updated_at'], updatedAtBefore);
    });

    test('a genuine change writes exactly once', () async {
      final id = await repo.create(
        apiaryId: 'a1',
        type: 'harvest',
        occurredAt: '2026-06-01',
        attributes: {'honey_supers': 4},
      );

      await repo.update(
        id,
        type: 'harvest',
        occurredAt: '2026-06-02', // only the date changed
        attributes: {'honey_supers': 4},
      );

      expect(store.executeCalls, 1);
      final row = store.rows.single;
      expect(row['occurred_at'], '2026-06-02');
      expect(jsonDecode(row['attributes'] as String), {'honey_supers': 4});
    });
  });

  group('Activity.journeyId (#47) — read-side exposure of the #46 column', () {
    test('getById()/watchById()/watchByApiary()/watchAll() all surface the '
        'journey_id an activity was created with', () async {
      final id = await repo.create(
        apiaryId: 'a1',
        type: 'harvest',
        occurredAt: '2026-06-01',
        attributes: const {},
        journeyId: 'j1',
      );

      expect((await repo.getById(id))!.journeyId, 'j1');
      expect((await repo.watchById(id).first)!.journeyId, 'j1');
      expect((await repo.watchByApiary('a1').first).single.journeyId, 'j1');
      final all = await repo.watchAll(organizationId: 'org-a').first;
      expect(all.single.journeyId, 'j1');
    });

    test('is null when no journey was attached at creation', () async {
      final id = await repo.create(
        apiaryId: 'a1',
        type: 'generic',
        occurredAt: '2026-06-01',
        attributes: const {},
      );

      expect((await repo.getById(id))!.journeyId, isNull);
    });
  });

  group('offline-create → wire op attributes shape (#39, FR-OF-1) — the '
      'string-vs-object mismatch that rejected every synced activity', () {
    test('the connector decodes the repository-stored JSON-string attributes '
        'back to an object, so the POST body carries a nested object', () async {
      // 1. Real local create: the repository JSON-encodes attributes into the
      //    TEXT column (there is no JSON column type on-device), so the stored
      //    value — which PowerSync then queues verbatim as the op's opData — is
      //    a String, NOT an object.
      await repo.create(
        apiaryId: 'a1',
        type: 'inspection',
        occurredAt: '2026-06-01',
        attributes: {'queen_seen': true, 'frames': 8},
      );
      final storedAttributes = store.rows.single['attributes'];
      expect(
        storedAttributes,
        isA<String>(),
        reason:
            'root cause: attributes is stored as JSON-encoded TEXT, so the '
            'queued op would upload it as a string without the connector fix',
      );

      // 2. The connector's normalization (what _toOp applies to every activities
      //    op before it goes on the wire). Feed it the exact opData shape a put
      //    carries (the full row's columns).
      final opData = {
        'apiary_id': store.rows.single['apiary_id'],
        'type': store.rows.single['type'],
        'occurred_at': store.rows.single['occurred_at'],
        'attributes': storedAttributes,
        'updated_at': store.rows.single['updated_at'],
      };
      final decoded = decodeActivityAttributes(activitiesTable, opData)!;

      // 3. The actual bytes that hit POST /v1/sync/batch (uploadData jsonEncodes
      //    the ops). Re-decoding proves attributes is a JSON object there, which
      //    is exactly what services/activities/api/sync.go's activityData
      //    expects — a JSON string would be rejected "attributes must be a JSON
      //    object".
      final body = jsonEncode({
        'ops': [decoded],
      });
      final wire = jsonDecode(body) as Map<String, dynamic>;
      final wireAttributes = (wire['ops'] as List).single['attributes'];
      expect(wireAttributes, isA<Map<String, dynamic>>());
      expect(wireAttributes, {'queen_seen': true, 'frames': 8});
    });
  });

  group('ActivitiesRepository.watchByApiary() (#42, FR-AC-5)', () {
    test(
      'emits only the given apiary\'s activities, newest occurred_at first',
      () async {
        await repo.create(
          apiaryId: 'a1',
          type: 'harvest',
          occurredAt: '2026-06-01',
          attributes: const {},
        );
        await repo.create(
          apiaryId: 'a2',
          type: 'feeding',
          occurredAt: '2026-06-05',
          attributes: const {},
        );
        await repo.create(
          apiaryId: 'a1',
          type: 'generic',
          occurredAt: '2026-06-10',
          attributes: const {},
        );

        final activities = await repo.watchByApiary('a1').first;

        expect(activities.map((a) => a.type).toList(), ['generic', 'harvest']);
        expect(activities.every((a) => a.apiaryId == 'a1'), isTrue);
      },
    );

    test('re-emits after a write to that apiary', () async {
      final emissions = <int>[];
      final sub = repo
          .watchByApiary('a1')
          .listen((a) => emissions.add(a.length));
      addTearDown(sub.cancel);

      await pumpEventQueue();
      expect(emissions, [0]);

      await repo.create(
        apiaryId: 'a1',
        type: 'generic',
        occurredAt: '2026-06-01',
        attributes: const {},
      );
      await pumpEventQueue();

      expect(emissions.last, 1);
    });
  });

  group('ActivitiesRepository.watchByJourney() (#48, FR-JO-3, D-21)', () {
    test(
      'emits only the given journey\'s activities, newest occurred_at first',
      () async {
        await repo.create(
          apiaryId: 'a1',
          type: 'harvest',
          occurredAt: '2026-06-01',
          attributes: const {},
          journeyId: 'j1',
        );
        await repo.create(
          apiaryId: 'a2',
          type: 'feeding',
          occurredAt: '2026-06-05',
          attributes: const {},
          journeyId: 'j2',
        );
        await repo.create(
          apiaryId: 'a1',
          type: 'generic',
          occurredAt: '2026-06-10',
          attributes: const {},
          journeyId: 'j1',
        );

        final activities = await repo.watchByJourney('j1').first;

        expect(activities.map((a) => a.type).toList(), ['generic', 'harvest']);
        expect(activities.every((a) => a.journeyId == 'j1'), isTrue);
      },
    );

    test(
      'excludes an activity with no journey attached (stored journey_id '
      'scoping, D-21: not a live re-match against any journey\'s plan)',
      () async {
        await repo.create(
          apiaryId: 'a1',
          type: 'generic',
          occurredAt: '2026-06-01',
          attributes: const {},
        );

        final activities = await repo.watchByJourney('j1').first;

        expect(activities, isEmpty);
      },
    );

    test(
      'returns an empty list for a journey with no attributed activities',
      () async {
        final activities = await repo.watchByJourney('unknown-journey').first;
        expect(activities, isEmpty);
      },
    );

    test('re-emits after a write attributed to that journey', () async {
      final emissions = <int>[];
      final sub = repo
          .watchByJourney('j1')
          .listen((a) => emissions.add(a.length));
      addTearDown(sub.cancel);

      await pumpEventQueue();
      expect(emissions, [0]);

      await repo.create(
        apiaryId: 'a1',
        type: 'generic',
        occurredAt: '2026-06-01',
        attributes: const {},
        journeyId: 'j1',
      );
      await pumpEventQueue();

      expect(emissions.last, 1);
    });
  });

  group('ActivitiesRepository.watchAll() org-scoping (#43, FR-AC-6/FR-TEN-2)', () {
    test(
      'returns an empty stream when the organization id is null (not yet loaded)',
      () async {
        final activities = await repo.watchAll(organizationId: null).first;
        expect(activities, isEmpty);
      },
    );

    test(
      'excludes another organization\'s activities — never leaks cross-tenant '
      'data even if it were somehow present locally (#43 AC)',
      () async {
        store.rows.addAll([
          {
            'id': 'own-1',
            'apiary_id': 'a1',
            'performed_by': 'user-1',
            'organization_id': 'org-a',
            'type': 'harvest',
            'occurred_at': '2026-06-01',
            'attributes': '{}',
            'created_at': '2026-06-01T00:00:00Z',
            'updated_at': '2026-06-01T00:00:00Z',
          },
          {
            'id': 'foreign-1',
            'apiary_id': 'a9',
            'performed_by': 'user-9',
            'organization_id': 'org-b',
            'type': 'harvest',
            'occurred_at': '2026-06-02',
            'attributes': '{}',
            'created_at': '2026-06-02T00:00:00Z',
            'updated_at': '2026-06-02T00:00:00Z',
          },
        ]);

        final activities = await repo.watchAll(organizationId: 'org-a').first;

        expect(activities.map((a) => a.id).toList(), ['own-1']);
        expect(
          activities.any((a) => a.organizationId == 'org-b'),
          isFalse,
          reason: 'org-a caller must never see org-b\'s activities',
        );
      },
    );

    test('still shows a freshly-created, not-yet-synced local row (null '
        'organization_id) — offline-first: your own just-added activity must '
        'not disappear from the list until it round-trips (FR-OF-1)', () async {
      await repo.create(
        apiaryId: 'a1',
        type: 'generic',
        occurredAt: '2026-06-01',
        attributes: const {},
      );

      final activities = await repo.watchAll(organizationId: 'org-a').first;

      expect(activities, hasLength(1));
      expect(activities.single.organizationId, isNull);
    });

    test(
      'includes only the caller\'s own org id or null, sorted newest-first',
      () async {
        store.rows.addAll([
          {
            'id': 'older',
            'apiary_id': 'a1',
            'performed_by': 'user-1',
            'organization_id': 'org-a',
            'type': 'harvest',
            'occurred_at': '2026-05-01',
            'attributes': '{}',
            'created_at': '2026-05-01T00:00:00Z',
            'updated_at': '2026-05-01T00:00:00Z',
          },
          {
            'id': 'newer',
            'apiary_id': 'a2',
            'performed_by': 'user-2',
            'organization_id': 'org-a',
            'type': 'feeding',
            'occurred_at': '2026-06-01',
            'attributes': '{}',
            'created_at': '2026-06-01T00:00:00Z',
            'updated_at': '2026-06-01T00:00:00Z',
          },
        ]);

        final activities = await repo.watchAll(organizationId: 'org-a').first;

        expect(activities.map((a) => a.id).toList(), ['newer', 'older']);
      },
    );
  });
}
