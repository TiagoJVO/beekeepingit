import 'package:beekeepingit_client/features/journeys/journey_stats.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the pure #49 aggregation (FR-JO-1, D-2, D-21,
/// NFR-TST-1) — every case NFR-TST-1 explicitly calls for: empty journey,
/// partial completion, full completion, the hive-count summation across
/// multiple harvest activities, and the média alças/colmeia calculation
/// (including its no-divide-by-zero guard) — plus #391's hive-level
/// completion (`hivesWorked`/`hivesPlanned`) and its `computePerApiaryJourneyStats`
/// per-apiary breakdown. Repository-level wiring (querying by stored
/// `journey_id`, live recompute, stability against unrelated activity
/// edits) is covered separately in journeys_repository_stats_test.dart —
/// this file only exercises the arithmetic over already-scoped plain data,
/// mirroring journey_matching_test.dart's own split.
void main() {
  group('computeJourneyStats() — empty journey', () {
    test('an empty journey (no plan, no activities) is all zeros with no '
        'divide-by-zero on média alças/colmeia', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const [],
        visitedApiaryIds: const {},
        harvestTotals: const [],
        activityHivesInvolved: const [],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats, JourneyStats.empty);
      expect(stats.apiariesPlanned, 0);
      expect(stats.apiariesVisited, 0);
      expect(stats.apiariesMissing, 0);
      expect(stats.hivesHarvested, 0);
      expect(stats.honeyCollectedKg, 0);
      expect(stats.averageSupersPerHive, isNull);
      expect(stats.hivesWorked, 0);
      expect(stats.hivesPlanned, isNull);
    });

    test('a planned-but-not-yet-started journey (plan set, zero activities) '
        'has every planned apiary missing and no hive data yet', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1', 'a2', 'a3'],
        visitedApiaryIds: const {},
        harvestTotals: const [],
        activityHivesInvolved: const [],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats.apiariesPlanned, 3);
      expect(stats.apiariesVisited, 0);
      expect(stats.apiariesMissing, 3);
      expect(stats.hivesHarvested, 0);
      expect(stats.honeyCollectedKg, 0);
      expect(stats.averageSupersPerHive, isNull);
      expect(stats.hivesWorked, 0);
      expect(stats.hivesPlanned, isNull);
    });
  });

  group('computeJourneyStats() — partial completion', () {
    test('counts only planned apiaries that have a matching visit, and the '
        'remainder as missing (FR-JO-1)', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1', 'a2', 'a3', 'a4'],
        visitedApiaryIds: const {'a1', 'a3'},
        harvestTotals: const [
          HarvestActivityTotals(hivesInvolved: 5, honeyKg: 20, honeySupers: 8),
        ],
        activityHivesInvolved: const [5],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats.apiariesPlanned, 4);
      expect(stats.apiariesVisited, 2);
      expect(stats.apiariesMissing, 2);
    });

    test('a visited apiary that is NOT in the current plan does not inflate '
        'progress past the plan size (and never makes missing negative)', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1', 'a2'],
        visitedApiaryIds: const {'a1', 'a-not-planned'},
        harvestTotals: const [],
        activityHivesInvolved: const [],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats.apiariesPlanned, 2);
      expect(stats.apiariesVisited, 1);
      expect(stats.apiariesMissing, 1);
    });

    test('de-duplicates a planned-apiary-id list with repeats', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1', 'a1', 'a2'],
        visitedApiaryIds: const {'a1'},
        harvestTotals: const [],
        activityHivesInvolved: const [],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats.apiariesPlanned, 2);
      expect(stats.apiariesVisited, 1);
      expect(stats.apiariesMissing, 1);
    });
  });

  group('computeJourneyStats() — full completion', () {
    test('every planned apiary visited leaves nothing missing', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1', 'a2'],
        visitedApiaryIds: const {'a1', 'a2'},
        harvestTotals: const [
          HarvestActivityTotals(
            hivesInvolved: 10,
            honeyKg: 40,
            honeySupers: 18,
          ),
          HarvestActivityTotals(
            hivesInvolved: 6,
            honeyKg: 22.5,
            honeySupers: 10,
          ),
        ],
        activityHivesInvolved: const [10, 6],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats.apiariesPlanned, 2);
      expect(stats.apiariesVisited, 2);
      expect(stats.apiariesMissing, 0);
      expect(stats.hivesHarvested, 16);
      expect(stats.honeyCollectedKg, 62.5);
      expect(stats.averageSupersPerHive, closeTo(28 / 16, 1e-9));
    });
  });

  group('computeJourneyStats() — hive-count summation (D-2)', () {
    test('sums hives_involved across multiple harvest activities, treating '
        'a null value as 0 rather than throwing', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1', 'a2', 'a3'],
        visitedApiaryIds: const {'a1', 'a2', 'a3'},
        harvestTotals: const [
          HarvestActivityTotals(
            hivesInvolved: 12,
            honeyKg: 30,
            honeySupers: 20,
          ),
          HarvestActivityTotals(hivesInvolved: 8, honeyKg: 15, honeySupers: 14),
          // hives_involved is optional on the harvest schema itself
          // (activity_attributes.dart) — a harvest activity that never
          // recorded one must contribute 0, not null-propagate the sum.
          HarvestActivityTotals(honeyKg: 5, honeySupers: 4),
        ],
        activityHivesInvolved: const [12, 8, null],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats.hivesHarvested, 20);
      expect(stats.honeyCollectedKg, 50);
    });

    test('sums honey_kg as num, preserving fractional kg', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1'],
        visitedApiaryIds: const {'a1'},
        harvestTotals: const [
          HarvestActivityTotals(
            hivesInvolved: 4,
            honeyKg: 12.4,
            honeySupers: 6,
          ),
          HarvestActivityTotals(hivesInvolved: 4, honeyKg: 8.1, honeySupers: 6),
        ],
        activityHivesInvolved: const [4, 4],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats.honeyCollectedKg, closeTo(20.5, 1e-9));
    });
  });

  group(
    'computeJourneyStats() — média alças/colmeia (average supers/hive)',
    () {
      test('divides Σ honey_supers by Σ hives_involved across harvest '
          'activities', () {
        final stats = computeJourneyStats(
          plannedApiaryIds: const ['a1', 'a2'],
          visitedApiaryIds: const {'a1', 'a2'},
          harvestTotals: const [
            HarvestActivityTotals(
              hivesInvolved: 20,
              honeyKg: 40,
              honeySupers: 36,
            ),
            HarvestActivityTotals(
              hivesInvolved: 10,
              honeyKg: 18,
              honeySupers: 14,
            ),
          ],
          activityHivesInvolved: const [20, 10],
          plannedApiaryHiveCounts: const {},
        );

        // Σ supers = 50, Σ hives = 30 → 1.666...
        expect(stats.averageSupersPerHive, closeTo(50 / 30, 1e-9));
      });

      test('is null (not zero, not a divide-by-zero throw) when every harvest '
          'activity has a null/zero hives_involved', () {
        final stats = computeJourneyStats(
          plannedApiaryIds: const ['a1'],
          visitedApiaryIds: const {'a1'},
          harvestTotals: const [
            HarvestActivityTotals(honeyKg: 10, honeySupers: 5),
            HarvestActivityTotals(hivesInvolved: 0, honeyKg: 4, honeySupers: 2),
          ],
          activityHivesInvolved: const [null, 0],
          plannedApiaryHiveCounts: const {},
        );

        expect(stats.averageSupersPerHive, isNull);
      });
    },
  );

  group('computeJourneyStats() — hivesWorked (#391)', () {
    test(
      'sums hives_involved across EVERY activity type, not just harvest',
      () {
        final stats = computeJourneyStats(
          plannedApiaryIds: const ['a1', 'a2'],
          visitedApiaryIds: const {'a1', 'a2'},
          harvestTotals: const [
            HarvestActivityTotals(hivesInvolved: 4, honeyKg: 8, honeySupers: 3),
          ],
          // One harvest (4), one feeding (2), one treatment (3) activity.
          activityHivesInvolved: const [4, 2, 3],
          plannedApiaryHiveCounts: const {},
        );

        expect(stats.hivesWorked, 9);
        // hivesHarvested stays harvest-only, unaffected by the feeding/
        // treatment entries in activityHivesInvolved.
        expect(stats.hivesHarvested, 4);
      },
    );

    test('treats a null hives_involved entry as 0 rather than throwing', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1'],
        visitedApiaryIds: const {'a1'},
        harvestTotals: const [],
        activityHivesInvolved: const [null, 5, null],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats.hivesWorked, 5);
    });

    test('is 0 (not null) for a journey with activities that never record '
        'hives_involved', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1'],
        visitedApiaryIds: const {'a1'},
        harvestTotals: const [],
        activityHivesInvolved: const [null],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats.hivesWorked, 0);
    });
  });

  group('computeJourneyStats() — hivesPlanned (#391)', () {
    test('is null when no planned apiary has a hive counter row yet', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1', 'a2'],
        visitedApiaryIds: const {},
        harvestTotals: const [],
        activityHivesInvolved: const [],
        plannedApiaryHiveCounts: const {},
      );

      expect(stats.hivesPlanned, isNull);
    });

    test('sums hive counts across the CURRENTLY planned apiaries only', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1', 'a2'],
        visitedApiaryIds: const {},
        harvestTotals: const [],
        activityHivesInvolved: const [],
        plannedApiaryHiveCounts: const {'a1': 10, 'a2': 6, 'a3': 99},
      );

      // a3 has a counter but is no longer planned — excluded from the sum.
      expect(stats.hivesPlanned, 16);
    });

    test('treats a planned apiary absent from the counter map as 0, once at '
        'least one other planned apiary has a counter (not a fake full-map '
        'requirement)', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1', 'a2', 'a3'],
        visitedApiaryIds: const {},
        harvestTotals: const [],
        activityHivesInvolved: const [],
        plannedApiaryHiveCounts: const {'a1': 10},
      );

      expect(stats.hivesPlanned, 10);
    });

    test(
      'de-duplicates a planned-apiary-id list with repeats before summing',
      () {
        final stats = computeJourneyStats(
          plannedApiaryIds: const ['a1', 'a1', 'a2'],
          visitedApiaryIds: const {},
          harvestTotals: const [],
          activityHivesInvolved: const [],
          plannedApiaryHiveCounts: const {'a1': 5, 'a2': 3},
        );

        expect(stats.hivesPlanned, 8);
      },
    );
  });

  group('computePerApiaryJourneyStats() — empty journey (#391)', () {
    test('returns an empty list for a journey with no plan and no '
        'activities', () {
      final result = computePerApiaryJourneyStats(
        plannedApiaryIds: const [],
        activities: const [],
        hiveCounts: const {},
      );

      expect(result, isEmpty);
    });
  });

  group('computePerApiaryJourneyStats() — planned vs. visited (#391)', () {
    test('an unvisited planned apiary appears with isVisited false and '
        'all-zero metrics', () {
      final result = computePerApiaryJourneyStats(
        plannedApiaryIds: const ['a1'],
        activities: const [],
        hiveCounts: const {'a1': 8},
      );

      expect(result, hasLength(1));
      final stats = result.single;
      expect(stats.apiaryId, 'a1');
      expect(stats.isPlanned, isTrue);
      expect(stats.isVisited, isFalse);
      expect(stats.activityCount, 0);
      expect(stats.hiveCount, 8);
      expect(stats.treated, isFalse);
    });

    test('an off-plan visited apiary still appears, with isPlanned false', () {
      final result = computePerApiaryJourneyStats(
        plannedApiaryIds: const ['a1'],
        activities: const [
          JourneyActivityRecord(
            apiaryId: 'a2',
            type: 'harvest',
            attributes: {'honey_kg': 5, 'honey_supers': 2, 'hives_involved': 1},
          ),
        ],
        hiveCounts: const {},
      );

      expect(result, hasLength(2));
      final off = result.firstWhere((s) => s.apiaryId == 'a2');
      expect(off.isPlanned, isFalse);
      expect(off.isVisited, isTrue);
      expect(off.activityCount, 1);
    });

    test('orders planned apiaries first (plan order), then unplanned-visited '
        'apiaries in first-seen order', () {
      final result = computePerApiaryJourneyStats(
        plannedApiaryIds: const ['a2', 'a1'],
        activities: const [
          JourneyActivityRecord(
            apiaryId: 'a3',
            type: 'generic',
            attributes: {},
          ),
          JourneyActivityRecord(
            apiaryId: 'a1',
            type: 'generic',
            attributes: {},
          ),
        ],
        hiveCounts: const {},
      );

      expect(result.map((s) => s.apiaryId).toList(), ['a2', 'a1', 'a3']);
    });
  });

  group('computePerApiaryJourneyStats() — harvest kg/hive divide-by-zero '
      'safety (#391)', () {
    test('kgPerHive/supersPerHive divide Σ by Σ hives_involved', () {
      final result = computePerApiaryJourneyStats(
        plannedApiaryIds: const ['a1'],
        activities: const [
          JourneyActivityRecord(
            apiaryId: 'a1',
            type: 'harvest',
            attributes: {
              'honey_kg': 20,
              'honey_supers': 8,
              'hives_involved': 4,
            },
          ),
          JourneyActivityRecord(
            apiaryId: 'a1',
            type: 'harvest',
            attributes: {
              'honey_kg': 10,
              'honey_supers': 4,
              'hives_involved': 2,
            },
          ),
        ],
        hiveCounts: const {'a1': 6},
      );

      final stats = result.single;
      expect(stats.harvestHoneyKg, 30);
      expect(stats.harvestHoneySupers, 12);
      expect(stats.harvestHivesInvolved, 6);
      expect(stats.kgPerHive, closeTo(5, 1e-9));
      expect(stats.supersPerHive, closeTo(2, 1e-9));
    });

    test('kgPerHive/supersPerHive are null (not a divide-by-zero) when there '
        'is no harvest hive-count denominator yet', () {
      final result = computePerApiaryJourneyStats(
        plannedApiaryIds: const ['a1'],
        activities: const [
          JourneyActivityRecord(
            apiaryId: 'a1',
            type: 'harvest',
            attributes: {'honey_kg': 10, 'honey_supers': 5},
          ),
        ],
        hiveCounts: const {},
      );

      final stats = result.single;
      expect(stats.kgPerHive, isNull);
      expect(stats.supersPerHive, isNull);
    });
  });

  group('computePerApiaryJourneyStats() — feeding totals (#391)', () {
    test('sums feed_amount across this apiary\'s feeding activities only', () {
      final result = computePerApiaryJourneyStats(
        plannedApiaryIds: const ['a1'],
        activities: const [
          JourneyActivityRecord(
            apiaryId: 'a1',
            type: 'feeding',
            attributes: {'feed_type': 'Xarope 1:1', 'feed_amount': 2.5},
          ),
          JourneyActivityRecord(
            apiaryId: 'a1',
            type: 'feeding',
            attributes: {'feed_type': 'Xarope 1:1', 'feed_amount': 1.5},
          ),
          // A harvest activity on the same apiary must not leak into the
          // feeding total.
          JourneyActivityRecord(
            apiaryId: 'a1',
            type: 'harvest',
            attributes: {'honey_kg': 99, 'honey_supers': 9},
          ),
        ],
        hiveCounts: const {},
      );

      expect(result.single.feedingAmountTotal, closeTo(4.0, 1e-9));
    });
  });

  group('computePerApiaryJourneyStats() — treated counting (#391)', () {
    test('treated is true once the apiary has at least one treatment-type '
        'activity, and sums hives_involved across just those', () {
      final result = computePerApiaryJourneyStats(
        plannedApiaryIds: const ['a1'],
        activities: const [
          JourneyActivityRecord(
            apiaryId: 'a1',
            type: 'treatment',
            attributes: {
              'treatment_context': 'preventive',
              'hives_involved': 3,
            },
          ),
          JourneyActivityRecord(
            apiaryId: 'a1',
            type: 'treatment',
            attributes: {
              'treatment_context': 'preventive',
              'hives_involved': 2,
            },
          ),
        ],
        hiveCounts: const {},
      );

      final stats = result.single;
      expect(stats.treated, isTrue);
      expect(stats.treatmentHivesInvolved, 5);
    });

    test('treated stays false for an apiary with only non-treatment '
        'activities', () {
      final result = computePerApiaryJourneyStats(
        plannedApiaryIds: const ['a1'],
        activities: const [
          JourneyActivityRecord(
            apiaryId: 'a1',
            type: 'generic',
            attributes: {},
          ),
        ],
        hiveCounts: const {},
      );

      expect(result.single.treated, isFalse);
    });
  });
}
