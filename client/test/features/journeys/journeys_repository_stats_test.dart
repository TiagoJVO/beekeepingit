import 'dart:async';
import 'dart:convert';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/journeys/journey_stats.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal in-memory [LocalStoreEngine] fake purpose-built for
/// [JourneysRepository.getStats]/[JourneysRepository.watchStats] (#49,
/// FR-JO-1, D-2, D-21) — kept SEPARATE from journeys_repository_test.dart's
/// own `FakeLocalStore` (which models `journeys`/`journey_plan_items` for
/// #45/#46's CRUD + matching queries) rather than extending that shared
/// fixture, since #47 (journeys list + filters, running in parallel) may
/// also be editing that file's fake for its own filtering queries — this
/// file only ever needs [planRows]/[activityRows], seeded directly (mirrors
/// the existing fake's own convention of seeding `store.rows`/
/// `store.planRows` directly in `watchAll`/`watchMatching` tests rather than
/// going through [execute]).
class _FakeStatsStore implements LocalStoreEngine {
  final List<Map<String, Object?>> planRows = [];
  final List<Map<String, Object?>> activityRows = [];

  /// Mirrors `apiaries.apiary_counters` rows (#391) — seeded directly like
  /// [planRows]/[activityRows]. Multiple rows for the same apiary_id +
  /// counter_type model the brief optimistic-sync window
  /// apiaries_repository.dart's own `_hiveCountSubquery` handles via
  /// `ORDER BY updated_at DESC LIMIT 1`; [_select] applies the same
  /// newest-wins rule when resolving the `hive_count` branch.
  final List<Map<String, Object?>> counterRows = [];
  final _watchController = StreamController<void>.broadcast();

  void notifyChanged() => _watchController.add(null);

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
    throw UnsupportedError(
      'This fake only supports the read side (getStats/watchStats) — seed '
      'planRows/activityRows directly instead of going through execute().',
    );
  }

  @override
  Future<void> clear() async {
    planRows.clear();
    activityRows.clear();
    counterRows.clear();
    notifyChanged();
  }

  /// Interprets exactly [JourneysRepository]'s `_statsSql` UNION shape: the
  /// `journey_id` filter is args[0] for the plan branch, args[1] for the
  /// activity branch, args[2] for the hive_count branch (all three always
  /// equal in practice, matching the repository's own
  /// `[journeyId, journeyId, journeyId]` call).
  List<Map<String, Object?>> _select(String sql, List<Object?> args) {
    final normalized = sql.toUpperCase();
    if (!normalized.contains('UNION ALL')) {
      throw UnsupportedError(
        'This fake only understands the stats UNION query: $sql',
      );
    }
    final journeyId = args[0];
    final planMatches = planRows
        .where((r) => r['journey_id'] == journeyId)
        .toList();
    final activityMatches = activityRows.where(
      (r) => r['journey_id'] == journeyId,
    );
    return [
      for (final r in planMatches)
        {
          'source': 'plan',
          'apiary_id': r['apiary_id'],
          'type': null,
          'attributes': null,
          'value': null,
        },
      for (final r in activityMatches)
        {
          'source': 'activity',
          'apiary_id': r['apiary_id'],
          'type': r['type'],
          'attributes': r['attributes'],
          'value': null,
        },
      for (final r in planMatches)
        {
          'source': 'hive_count',
          'apiary_id': r['apiary_id'],
          'type': null,
          'attributes': null,
          'value': _newestCounterValue(r['apiary_id']),
        },
    ];
  }

  /// Newest-row-wins resolution for one apiary's `hive` counter (mirrors
  /// apiaries_repository.dart's own `_hiveCountSubquery` — the real SQL
  /// correlated subquery this fake stands in for) — null when the apiary has
  /// no counter row at all, matching the real subquery's NULL result.
  Object? _newestCounterValue(Object? apiaryId) {
    final matches = counterRows.where(
      (r) => r['apiary_id'] == apiaryId && r['counter_type'] == 'hive',
    );
    if (matches.isEmpty) return null;
    final newest = matches.reduce(
      (a, b) =>
          (a['updated_at'] as String).compareTo(b['updated_at'] as String) >= 0
          ? a
          : b,
    );
    return newest['value'];
  }

  void dispose() => _watchController.close();
}

void main() {
  late _FakeStatsStore store;
  late JourneysRepository repo;

  setUp(() {
    store = _FakeStatsStore();
    repo = JourneysRepository(store);
  });

  tearDown(() => store.dispose());

  void seedPlanItem(String journeyId, String apiaryId) {
    store.planRows.add({
      'id': 'plan-$journeyId-$apiaryId',
      'journey_id': journeyId,
      'apiary_id': apiaryId,
      'created_at': '2026-06-01T00:00:00Z',
    });
  }

  void seedActivity({
    required String journeyId,
    required String apiaryId,
    required String type,
    Map<String, dynamic>? attributes,
    String id = 'auto',
  }) {
    store.activityRows.add({
      'id': id == 'auto' ? 'act-${store.activityRows.length}' : id,
      'journey_id': journeyId,
      'apiary_id': apiaryId,
      'type': type,
      'attributes': attributes == null ? null : jsonEncode(attributes),
    });
  }

  void seedCounter({
    required String apiaryId,
    required int value,
    String updatedAt = '2026-06-01T00:00:00Z',
  }) {
    store.counterRows.add({
      'id': 'counter-${store.counterRows.length}',
      'apiary_id': apiaryId,
      'counter_type': 'hive',
      'value': value,
      'updated_at': updatedAt,
    });
  }

  group('JourneysRepository.getStats() (#49, FR-JO-1, D-2, D-21)', () {
    test('an empty journey (no plan, no activities) is all zeros', () async {
      final stats = await repo.getStats('j-empty');
      expect(stats, JourneyStats.empty);
    });

    test(
      'counts an apiary as visited only when it has a matching stored '
      'journey_id AND is still in the current plan (partial completion)',
      () async {
        seedPlanItem('j1', 'a1');
        seedPlanItem('j1', 'a2');
        seedPlanItem('j1', 'a3');
        seedActivity(
          journeyId: 'j1',
          apiaryId: 'a1',
          type: 'harvest',
          attributes: {'honey_supers': 4, 'hives_involved': 2, 'honey_kg': 8},
        );

        final stats = await repo.getStats('j1');

        expect(stats.apiariesPlanned, 3);
        expect(stats.apiariesVisited, 1);
        expect(stats.apiariesMissing, 2);
      },
    );

    test(
      'full completion: every planned apiary has a matching activity',
      () async {
        seedPlanItem('j1', 'a1');
        seedPlanItem('j1', 'a2');
        seedActivity(journeyId: 'j1', apiaryId: 'a1', type: 'harvest');
        seedActivity(journeyId: 'j1', apiaryId: 'a2', type: 'feeding');

        final stats = await repo.getStats('j1');

        expect(stats.apiariesPlanned, 2);
        expect(stats.apiariesVisited, 2);
        expect(stats.apiariesMissing, 0);
      },
    );

    test('a non-harvest activity attributed to the journey counts as "visited" '
        'but contributes nothing to the hive/honey/supers sums', () async {
      seedPlanItem('j1', 'a1');
      seedActivity(
        journeyId: 'j1',
        apiaryId: 'a1',
        type: 'feeding',
        attributes: {'feed_type': 'Xarope 1:1', 'feed_amount': 2},
      );

      final stats = await repo.getStats('j1');

      expect(stats.apiariesVisited, 1);
      expect(stats.hivesHarvested, 0);
      expect(stats.honeyCollectedKg, 0);
      expect(stats.averageSupersPerHive, isNull);
    });

    test('sums hives_involved/honey_kg/honey_supers across MULTIPLE harvest '
        'activities attributed to the journey (D-2)', () async {
      seedPlanItem('j1', 'a1');
      seedPlanItem('j1', 'a2');
      seedActivity(
        journeyId: 'j1',
        apiaryId: 'a1',
        type: 'harvest',
        attributes: {'honey_supers': 20, 'hives_involved': 10, 'honey_kg': 30},
      );
      seedActivity(
        journeyId: 'j1',
        apiaryId: 'a2',
        type: 'harvest',
        attributes: {'honey_supers': 14, 'hives_involved': 10, 'honey_kg': 18},
      );

      final stats = await repo.getStats('j1');

      expect(stats.hivesHarvested, 20);
      expect(stats.honeyCollectedKg, 48);
      // média alças/colmeia: Σ supers ÷ Σ hives = 34/20
      expect(stats.averageSupersPerHive, closeTo(34 / 20, 1e-9));
    });

    test('an activity with no attributes (still-syncing row) contributes 0, '
        'not a decode error', () async {
      seedPlanItem('j1', 'a1');
      seedActivity(journeyId: 'j1', apiaryId: 'a1', type: 'harvest');

      final stats = await repo.getStats('j1');

      expect(stats.hivesHarvested, 0);
      expect(stats.honeyCollectedKg, 0);
    });

    test('excludes another journey\'s activities and plan (stored journey_id '
        'scoping, D-21)', () async {
      seedPlanItem('j1', 'a1');
      seedPlanItem('other-journey', 'a2');
      seedActivity(journeyId: 'j1', apiaryId: 'a1', type: 'harvest');
      seedActivity(
        journeyId: 'other-journey',
        apiaryId: 'a2',
        type: 'harvest',
        attributes: {'honey_supers': 99, 'hives_involved': 33, 'honey_kg': 999},
      );

      final stats = await repo.getStats('j1');

      expect(stats.apiariesPlanned, 1);
      expect(stats.hivesHarvested, 0);
      expect(stats.honeyCollectedKg, 0);
    });

    test(
      'an activity with no journey_id (never attached) is excluded entirely',
      () async {
        seedPlanItem('j1', 'a1');
        seedActivity(journeyId: 'j1', apiaryId: 'a1', type: 'harvest');
        // Simulates an activity whose journey_id is null — never matches any
        // journeyId filter, so it simply never appears for any journey's
        // stats (nothing further to assert beyond j1's own count staying 1).
        store.activityRows.add({
          'id': 'unattached',
          'journey_id': null,
          'apiary_id': 'a9',
          'type': 'harvest',
          'attributes': jsonEncode({'honey_supers': 1, 'hives_involved': 1}),
        });

        final stats = await repo.getStats('j1');

        expect(stats.apiariesVisited, 1);
        expect(stats.hivesHarvested, 0);
      },
    );

    test('stability against unrelated activity edits (D-21: not a live '
        're-match) — editing/removing another journey\'s activity never '
        'changes this journey\'s already-computed stats', () async {
      seedPlanItem('j1', 'a1');
      seedActivity(
        journeyId: 'j1',
        apiaryId: 'a1',
        type: 'harvest',
        attributes: {'honey_supers': 6, 'hives_involved': 3, 'honey_kg': 9},
        id: 'j1-activity',
      );
      seedActivity(
        journeyId: 'j2',
        apiaryId: 'a2',
        type: 'harvest',
        attributes: {'honey_supers': 40, 'hives_involved': 20, 'honey_kg': 60},
        id: 'j2-activity',
      );

      final before = await repo.getStats('j1');

      // Edit an unrelated journey's activity (j2) — must not affect j1.
      store.activityRows.removeWhere((r) => r['id'] == 'j2-activity');
      seedActivity(
        journeyId: 'j2',
        apiaryId: 'a2',
        type: 'harvest',
        attributes: {'honey_supers': 1, 'hives_involved': 1, 'honey_kg': 1},
        id: 'j2-activity',
      );

      final after = await repo.getStats('j1');

      expect(after, before);
      expect(after.hivesHarvested, 3);
      expect(after.honeyCollectedKg, 9);
    });

    test('re-attributing an activity to a different journey (#387: editing '
        'journey_id) moves it out of the old journey\'s stats and into the '
        'new one\'s — attribution is by the STORED journey_id, D-21', () async {
      seedPlanItem('j1', 'a1');
      seedPlanItem('j2', 'a2');
      seedActivity(
        journeyId: 'j1',
        apiaryId: 'a1',
        type: 'harvest',
        attributes: {'honey_supers': 6, 'hives_involved': 3, 'honey_kg': 9},
        id: 'moved-activity',
      );

      final j1Before = await repo.getStats('j1');
      final j2Before = await repo.getStats('j2');
      expect(j1Before.hivesHarvested, 3);
      expect(j2Before.hivesHarvested, 0);

      // Simulate the #387 re-link: the SAME activity id, now stored under
      // journey_id j2 (apiary_id/attributes carried over unchanged, only
      // journey_id moved — mirrors ActivitiesRepository.update's own
      // journey_id-only-change shape).
      store.activityRows.removeWhere((r) => r['id'] == 'moved-activity');
      seedActivity(
        journeyId: 'j2',
        apiaryId: 'a1',
        type: 'harvest',
        attributes: {'honey_supers': 6, 'hives_involved': 3, 'honey_kg': 9},
        id: 'moved-activity',
      );

      final j1After = await repo.getStats('j1');
      final j2After = await repo.getStats('j2');
      expect(j1After.hivesHarvested, 0);
      expect(j2After.hivesHarvested, 3);
      expect(j2After.honeyCollectedKg, 9);
    });
  });

  group('JourneysRepository.watchStats() (#49) live recompute', () {
    test('emits the current stats immediately', () async {
      seedPlanItem('j1', 'a1');

      final stats = await repo.watchStats('j1').first;

      expect(stats.apiariesPlanned, 1);
      expect(stats.apiariesVisited, 0);
    });

    test('recomputes when a new activity is added (a plain write to the '
        'activities table re-triggers the watch)', () async {
      seedPlanItem('j1', 'a1');
      seedPlanItem('j1', 'a2');

      final emissions = <JourneyStats>[];
      final sub = repo.watchStats('j1').listen(emissions.add);
      await Future<void>.delayed(Duration.zero);

      seedActivity(
        journeyId: 'j1',
        apiaryId: 'a1',
        type: 'harvest',
        attributes: {'honey_supers': 4, 'hives_involved': 2, 'honey_kg': 6},
      );
      store.notifyChanged();
      await Future<void>.delayed(Duration.zero);

      await sub.cancel();

      expect(emissions.first.apiariesVisited, 0);
      expect(emissions.last.apiariesVisited, 1);
      expect(emissions.last.hivesHarvested, 2);
    });

    test(
      'recomputes when a plan item is added (a write to journey_plan_items '
      'also re-triggers the SAME watch, per its single combined query)',
      () async {
        seedPlanItem('j1', 'a1');
        seedActivity(journeyId: 'j1', apiaryId: 'a1', type: 'harvest');

        final emissions = <JourneyStats>[];
        final sub = repo.watchStats('j1').listen(emissions.add);
        await Future<void>.delayed(Duration.zero);

        seedPlanItem('j1', 'a2');
        store.notifyChanged();
        await Future<void>.delayed(Duration.zero);

        await sub.cancel();

        expect(emissions.first.apiariesPlanned, 1);
        expect(emissions.last.apiariesPlanned, 2);
        expect(emissions.last.apiariesMissing, 1);
      },
    );
  });

  group('JourneysRepository — hive-level completion (#391)', () {
    test('the extended UNION picks up hive counters for the planned '
        'apiaries', () async {
      seedPlanItem('j1', 'a1');
      seedPlanItem('j1', 'a2');
      seedCounter(apiaryId: 'a1', value: 10);
      seedCounter(apiaryId: 'a2', value: 6);

      final stats = await repo.getStats('j1');

      expect(stats.hivesPlanned, 16);
    });

    test('hivesWorked sums hives_involved across every activity type '
        'attributed to the journey, not just harvest', () async {
      seedPlanItem('j1', 'a1');
      seedActivity(
        journeyId: 'j1',
        apiaryId: 'a1',
        type: 'harvest',
        attributes: {'honey_supers': 4, 'hives_involved': 2, 'honey_kg': 8},
      );
      seedActivity(
        journeyId: 'j1',
        apiaryId: 'a1',
        type: 'feeding',
        attributes: {'feed_type': 'Xarope 1:1', 'hives_involved': 3},
      );
      seedActivity(
        journeyId: 'j1',
        apiaryId: 'a1',
        type: 'treatment',
        attributes: {'treatment_context': 'preventive', 'hives_involved': 5},
      );

      final stats = await repo.getStats('j1');

      expect(stats.hivesWorked, 10);
      // hivesHarvested stays harvest-only (D-2), unchanged by #391.
      expect(stats.hivesHarvested, 2);
    });

    test('hivesPlanned is null when the journey has planned apiaries but '
        'none has a hive counter row yet', () async {
      seedPlanItem('j1', 'a1');

      final stats = await repo.getStats('j1');

      expect(stats.hivesPlanned, isNull);
    });

    test('the newest counter row wins when an apiary has more than one '
        '(the brief optimistic-sync window, mirrors '
        'apiaries_repository.dart\'s own hive-count resolution)', () async {
      seedPlanItem('j1', 'a1');
      seedCounter(apiaryId: 'a1', value: 3, updatedAt: '2026-06-01T00:00:00Z');
      seedCounter(apiaryId: 'a1', value: 9, updatedAt: '2026-06-02T00:00:00Z');

      final stats = await repo.getStats('j1');

      expect(stats.hivesPlanned, 9);
    });

    test('a counter for an apiary no longer in the plan does not count '
        'toward hivesPlanned', () async {
      seedPlanItem('j1', 'a1');
      seedCounter(apiaryId: 'a1', value: 4);
      seedCounter(apiaryId: 'a-not-planned', value: 100);

      final stats = await repo.getStats('j1');

      expect(stats.hivesPlanned, 4);
    });

    test('a counter edit re-fires watchStats (the SAME single combined '
        'query invalidates on a write to apiary_counters too)', () async {
      seedPlanItem('j1', 'a1');
      seedCounter(apiaryId: 'a1', value: 4);

      final emissions = <JourneyStats>[];
      final sub = repo.watchStats('j1').listen(emissions.add);
      await Future<void>.delayed(Duration.zero);

      seedCounter(apiaryId: 'a1', value: 12, updatedAt: '2026-06-05T00:00:00Z');
      store.notifyChanged();
      await Future<void>.delayed(Duration.zero);

      await sub.cancel();

      expect(emissions.first.hivesPlanned, 4);
      expect(emissions.last.hivesPlanned, 12);
    });
  });
}
