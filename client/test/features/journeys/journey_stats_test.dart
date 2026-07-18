import 'package:beekeepingit_client/features/journeys/journey_stats.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the pure #49 aggregation (FR-JO-1, D-2, D-21,
/// NFR-TST-1) — every case NFR-TST-1 explicitly calls for: empty journey,
/// partial completion, full completion, the hive-count summation across
/// multiple harvest activities, and the média alças/colmeia calculation
/// (including its no-divide-by-zero guard). Repository-level wiring
/// (querying by stored `journey_id`, live recompute, stability against
/// unrelated activity edits) is covered separately in
/// journeys_repository_stats_test.dart — this file only exercises the
/// arithmetic over already-scoped plain data, mirroring
/// journey_matching_test.dart's own split.
void main() {
  group('computeJourneyStats() — empty journey', () {
    test('an empty journey (no plan, no activities) is all zeros with no '
        'divide-by-zero on média alças/colmeia', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const [],
        visitedApiaryIds: const {},
        harvestTotals: const [],
      );

      expect(stats, JourneyStats.empty);
      expect(stats.apiariesPlanned, 0);
      expect(stats.apiariesVisited, 0);
      expect(stats.apiariesMissing, 0);
      expect(stats.hivesHarvested, 0);
      expect(stats.honeyCollectedKg, 0);
      expect(stats.averageSupersPerHive, isNull);
    });

    test('a planned-but-not-yet-started journey (plan set, zero activities) '
        'has every planned apiary missing and no hive data yet', () {
      final stats = computeJourneyStats(
        plannedApiaryIds: const ['a1', 'a2', 'a3'],
        visitedApiaryIds: const {},
        harvestTotals: const [],
      );

      expect(stats.apiariesPlanned, 3);
      expect(stats.apiariesVisited, 0);
      expect(stats.apiariesMissing, 3);
      expect(stats.hivesHarvested, 0);
      expect(stats.honeyCollectedKg, 0);
      expect(stats.averageSupersPerHive, isNull);
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
        );

        expect(stats.averageSupersPerHive, isNull);
      });
    },
  );
}
