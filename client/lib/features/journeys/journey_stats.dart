/// Pure aggregation logic for a journey's progress/harvest metrics (#49,
/// FR-JO-1, D-2, D-21) — kept as a plain value type + a free function over
/// already-scoped plain data (no widget/provider/database dependency),
/// mirroring journey_matching.dart's own convention so every NFR-TST-1 case
/// (empty/partial/full completion, the hive-count summation, média
/// alças/colmeia) is a unit test with no PowerSync involved.
///
/// [JourneysRepository.getStats]/[JourneysRepository.watchStats]
/// (journeys_repository.dart) do the actual QUERYING — reading the journey's
/// plan-item apiary ids plus every activity whose STORED `journey_id` column
/// equals the journey's id (D-21: never a live re-match against the
/// journey's current plan/apiary/type, so editing an unrelated activity, or
/// re-scoping a journey's plan afterwards, never retroactively changes
/// another activity's already-recorded link or this computation) — then
/// hand the already-scoped result to [computeJourneyStats]. This file only
/// does the arithmetic.
library;

/// One harvest-type activity's numeric contribution to a journey's
/// aggregation (#49, D-2) — just the three attributes
/// [computeJourneyStats] sums (activity_attributes.dart's harvest schema:
/// `hives_involved`, `honey_kg`, `honey_supers`), decoupled from the full
/// `Activity`/attributes-map shape (activities_repository.dart) so this file
/// has no dependency on it and stays independently unit-testable.
class HarvestActivityTotals {
  const HarvestActivityTotals({
    this.hivesInvolved,
    this.honeyKg,
    this.honeySupers,
  });

  /// `attributes.hives_involved` — optional on the harvest schema itself
  /// (activity_attributes.dart's `_AttrSpec('hives_involved', ...)` has no
  /// `required: true`), so a harvest activity that never recorded a hive
  /// count contributes 0 to the sum rather than being a computation error.
  final int? hivesInvolved;

  /// `attributes.honey_kg` — likewise optional.
  final num? honeyKg;

  /// `attributes.honey_supers` — required on the harvest schema itself, but
  /// still nullable here defensively (a pre-existing row from before that
  /// constraint existed, or a decode gap, degrades to 0 rather than throwing).
  final int? honeySupers;
}

/// Aggregated journey progress + harvest metrics (#49, FR-JO-1, D-2, D-21) —
/// apiaries visited vs. planned, hives harvested, honey collected, and the
/// average supers-per-hive ratio. Matches the Melargil prototype's "Jornada
/// detalhe" stat cards (docs/design/prototype.md): apiários visitados
/// (feitos/planeados), colmeias trabalhadas, mel colhido (kg), média
/// alças/colmeia.
class JourneyStats {
  const JourneyStats({
    required this.apiariesPlanned,
    required this.apiariesVisited,
    required this.hivesHarvested,
    required this.honeyCollectedKg,
    required this.averageSupersPerHive,
  });

  /// The all-zero baseline for a brand-new journey with no plan and no
  /// activities yet (NFR-TST-1's "empty journey" case) — also exactly what
  /// [computeJourneyStats] returns when given empty inputs, so `empty` and a
  /// truly empty journey's computed stats always compare equal.
  static const empty = JourneyStats(
    apiariesPlanned: 0,
    apiariesVisited: 0,
    hivesHarvested: 0,
    honeyCollectedKg: 0,
    averageSupersPerHive: null,
  );

  /// The journey's current plan size (its apiaries-to-visit list).
  final int apiariesPlanned;

  /// How many of the PLANNED apiaries have at least one activity (any type)
  /// whose stored `journey_id` equals this journey's id — never larger than
  /// [apiariesPlanned] by construction (see [computeJourneyStats]), even if
  /// an activity was attributed to an apiary no longer in the current plan.
  final int apiariesVisited;

  /// Σ `hives_involved` across the journey's harvest-type activities only
  /// (D-2: "hives harvested" is a summed activity attribute, not a live
  /// apiary counter read).
  final int hivesHarvested;

  /// Σ `honey_kg` across the journey's harvest-type activities.
  final num honeyCollectedKg;

  /// Σ `honey_supers` ÷ Σ `hives_involved` across the journey's harvest-type
  /// activities, or null when there is no hive-count denominator yet (zero
  /// harvest activities, or every one of them has a null/zero
  /// `hives_involved`) — a genuine "no data yet" state, never a synthetic 0
  /// or a divide-by-zero (NFR-TST-1's explicit "no divide-by-zero" case).
  final double? averageSupersPerHive;

  /// Planned apiaries with no matching executed activity yet (FR-JO-1's
  /// "how much is still missing, planned vs. done") — never negative:
  /// [apiariesVisited] only counts planned apiaries that DO have a match.
  int get apiariesMissing => apiariesPlanned - apiariesVisited;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JourneyStats &&
          other.apiariesPlanned == apiariesPlanned &&
          other.apiariesVisited == apiariesVisited &&
          other.hivesHarvested == hivesHarvested &&
          other.honeyCollectedKg == honeyCollectedKg &&
          other.averageSupersPerHive == averageSupersPerHive);

  @override
  int get hashCode => Object.hash(
    apiariesPlanned,
    apiariesVisited,
    hivesHarvested,
    honeyCollectedKg,
    averageSupersPerHive,
  );

  @override
  String toString() =>
      'JourneyStats(apiariesPlanned: $apiariesPlanned, '
      'apiariesVisited: $apiariesVisited, hivesHarvested: $hivesHarvested, '
      'honeyCollectedKg: $honeyCollectedKg, '
      'averageSupersPerHive: $averageSupersPerHive)';
}

/// Pure aggregation (#49, FR-JO-1, D-2, D-21) — no database/repository
/// dependency, mirroring journey_matching.dart's `splitJourneyCandidates`'
/// own "pure function over already-scoped data" convention.
///
/// [plannedApiaryIds] is the journey's current plan (JourneysRepository's own
/// apiary-id list, possibly with duplicates from a stale caller — de-duped
/// here). [visitedApiaryIds] is every apiary id with AT LEAST one activity
/// (any type) whose stored `journey_id` equals this journey's id — an apiary
/// only counts toward [JourneyStats.apiariesVisited] when it's ALSO still in
/// the plan (an activity attributed to an apiary since removed from the plan
/// doesn't inflate progress past 100%, and never makes [apiariesMissing]
/// negative). [harvestTotals] is every HARVEST-type activity's numeric
/// attributes attributed to this journey (by stored link, D-21) — the sums
/// run across ALL of them regardless of plan membership, per the AC's own
/// wording ("across the harvest activities whose stored journey_id matches
/// the journey").
JourneyStats computeJourneyStats({
  required List<String> plannedApiaryIds,
  required Set<String> visitedApiaryIds,
  required List<HarvestActivityTotals> harvestTotals,
}) {
  final planned = plannedApiaryIds.toSet();
  final visited = planned.intersection(visitedApiaryIds).length;

  var hives = 0;
  num honey = 0;
  var supers = 0;
  for (final totals in harvestTotals) {
    hives += totals.hivesInvolved ?? 0;
    honey += totals.honeyKg ?? 0;
    supers += totals.honeySupers ?? 0;
  }

  return JourneyStats(
    apiariesPlanned: planned.length,
    apiariesVisited: visited,
    hivesHarvested: hives,
    honeyCollectedKg: honey,
    averageSupersPerHive: hives > 0 ? supers / hives : null,
  );
}
