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
///
/// [computePerApiaryJourneyStats] (#391) is this file's second pure
/// function: the "More stats" per-apiary breakdown screen's own arithmetic,
/// kept here for the same reason — the screen composes already-live
/// providers (activities/plan/apiaries) and hands this file plain,
/// already-scoped data, never a database dependency of its own.
library;

import '../activities/activity_types.dart';

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
    required this.hivesWorked,
    required this.hivesPlanned,
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
    hivesWorked: 0,
    hivesPlanned: null,
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

  /// Σ `hives_involved` across the journey's activities of EVERY type
  /// (#391) — harvest, feeding, and treatment activities all carry
  /// `hives_involved` (activity_attributes.dart's schemas), so this is
  /// "hive-level completion" across the whole journey, distinct from
  /// [hivesHarvested] (D-2's harvest-only sum, unchanged by this).
  final int hivesWorked;

  /// Σ hive count (the apiary_counters `hive` counter) across the journey's
  /// CURRENTLY PLANNED apiaries (#391) — the denominator for hive-level
  /// completion, paired with [hivesWorked]. Null when NONE of the planned
  /// apiaries has a hive counter row yet (a genuine "no data" state — render
  /// "—" rather than a fake 0/0 — mirroring [averageSupersPerHive]'s own
  /// no-divide-by-zero/no-fake-zero convention). Once at least one planned
  /// apiary has a counter, a planned apiary WITHOUT one contributes 0 to the
  /// sum, matching apiaries_repository.dart's "hive count always displays, 0
  /// default" rule used everywhere else in the app.
  final int? hivesPlanned;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JourneyStats &&
          other.apiariesPlanned == apiariesPlanned &&
          other.apiariesVisited == apiariesVisited &&
          other.hivesHarvested == hivesHarvested &&
          other.honeyCollectedKg == honeyCollectedKg &&
          other.averageSupersPerHive == averageSupersPerHive &&
          other.hivesWorked == hivesWorked &&
          other.hivesPlanned == hivesPlanned);

  @override
  int get hashCode => Object.hash(
    apiariesPlanned,
    apiariesVisited,
    hivesHarvested,
    honeyCollectedKg,
    averageSupersPerHive,
    hivesWorked,
    hivesPlanned,
  );

  @override
  String toString() =>
      'JourneyStats(apiariesPlanned: $apiariesPlanned, '
      'apiariesVisited: $apiariesVisited, hivesHarvested: $hivesHarvested, '
      'honeyCollectedKg: $honeyCollectedKg, '
      'averageSupersPerHive: $averageSupersPerHive, '
      'hivesWorked: $hivesWorked, hivesPlanned: $hivesPlanned)';
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
///
/// [activityHivesInvolved] (#391) is `attributes.hives_involved` from EVERY
/// activity attributed to this journey, regardless of type — one entry per
/// activity, null when that activity never recorded a hive count — summed
/// into [JourneyStats.hivesWorked] the same "regardless of plan membership"
/// way [harvestTotals] feeds [JourneyStats.hivesHarvested]. [
/// plannedApiaryHiveCounts] (#391) is the CURRENTLY PLANNED apiaries' hive
/// counter values, keyed by apiary id — only apiaries that actually have a
/// counter row appear as a key (an apiary with none is simply absent, not a
/// zero entry), which is what lets [JourneyStats.hivesPlanned] tell "no
/// counter data at all yet" (empty map → null) apart from "some planned
/// apiaries have 0 hives" (present, contributes 0).
JourneyStats computeJourneyStats({
  required List<String> plannedApiaryIds,
  required Set<String> visitedApiaryIds,
  required List<HarvestActivityTotals> harvestTotals,
  required List<int?> activityHivesInvolved,
  required Map<String, int> plannedApiaryHiveCounts,
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

  var hivesWorked = 0;
  for (final value in activityHivesInvolved) {
    hivesWorked += value ?? 0;
  }

  int? hivesPlanned;
  if (plannedApiaryHiveCounts.isNotEmpty) {
    var total = 0;
    for (final apiaryId in planned) {
      total += plannedApiaryHiveCounts[apiaryId] ?? 0;
    }
    hivesPlanned = total;
  }

  return JourneyStats(
    apiariesPlanned: planned.length,
    apiariesVisited: visited,
    hivesHarvested: hives,
    honeyCollectedKg: honey,
    averageSupersPerHive: hives > 0 ? supers / hives : null,
    hivesWorked: hivesWorked,
    hivesPlanned: hivesPlanned,
  );
}

/// One activity's minimal shape for [computePerApiaryJourneyStats] (#391) —
/// apiary id, type, and already-decoded attributes — decoupled from the full
/// `Activity` model (activities_repository.dart) so this file stays
/// dependency-free (this file's own stated convention, see its doc comment).
/// The caller (journey_stats_detail_screen.dart) maps its `Activity` list to
/// these before calling.
class JourneyActivityRecord {
  const JourneyActivityRecord({
    required this.apiaryId,
    required this.type,
    required this.attributes,
  });

  final String apiaryId;
  final String type;
  final Map<String, dynamic> attributes;
}

/// One apiary's contribution to a journey (#391's "More stats" per-apiary
/// breakdown screen): whether it's in the current plan and/or visited, how
/// many activities it has, its hive count, and — per activity type — the
/// numeric metrics the breakdown screen renders. Every sum defaults to 0
/// (never null) so a zero-activity apiary reads as "nothing recorded yet",
/// not a rendering gap; only the derived per-hive ratios ([kgPerHive],
/// [supersPerHive]) are nullable, for the same no-divide-by-zero reason
/// [JourneyStats.averageSupersPerHive] is nullable.
class ApiaryJourneyStats {
  const ApiaryJourneyStats({
    required this.apiaryId,
    required this.isPlanned,
    required this.isVisited,
    required this.activityCount,
    required this.hiveCount,
    required this.harvestHoneyKg,
    required this.harvestHoneySupers,
    required this.harvestHivesInvolved,
    required this.feedingAmountTotal,
    required this.treated,
    required this.treatmentHivesInvolved,
  });

  final String apiaryId;

  /// Still in the journey's current plan.
  final bool isPlanned;

  /// Has at least one activity (any type) attributed to this journey (D-21's
  /// stored-`journey_id` rule, same membership test [JourneyStats.
  /// apiariesVisited] and journey_detail_screen.dart's own apiary cards use).
  final bool isVisited;

  /// Every activity attributed to this journey for this apiary, any type.
  final int activityCount;

  /// The apiary's current hive counter value (0 default — the same
  /// always-displays convention [Apiary.hiveCount] already applies).
  final int hiveCount;

  /// Σ `honey_kg` across this apiary's harvest activities in the journey.
  final num harvestHoneyKg;

  /// Σ `honey_supers` across this apiary's harvest activities in the journey.
  final int harvestHoneySupers;

  /// Σ `hives_involved` across this apiary's harvest activities in the
  /// journey — the denominator for [kgPerHive]/[supersPerHive].
  final int harvestHivesInvolved;

  /// Σ `feed_amount` across this apiary's feeding activities in the journey.
  final num feedingAmountTotal;

  /// Has at least one treatment-type activity attributed to this journey for
  /// this apiary (the breakdown screen's "apiaries treated" summary counts
  /// this flag, not [activityCount]).
  final bool treated;

  /// Σ `hives_involved` across this apiary's treatment activities in the
  /// journey.
  final int treatmentHivesInvolved;

  /// [harvestHoneyKg] ÷ [harvestHivesInvolved], or null when there's no hive
  /// denominator yet (no harvest activity, or every one has a null/zero
  /// `hives_involved`) — never a divide-by-zero, mirroring
  /// [JourneyStats.averageSupersPerHive]'s own rule.
  double? get kgPerHive =>
      harvestHivesInvolved > 0 ? harvestHoneyKg / harvestHivesInvolved : null;

  /// [harvestHoneySupers] ÷ [harvestHivesInvolved], same null-safety rule as
  /// [kgPerHive].
  double? get supersPerHive => harvestHivesInvolved > 0
      ? harvestHoneySupers / harvestHivesInvolved
      : null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ApiaryJourneyStats &&
          other.apiaryId == apiaryId &&
          other.isPlanned == isPlanned &&
          other.isVisited == isVisited &&
          other.activityCount == activityCount &&
          other.hiveCount == hiveCount &&
          other.harvestHoneyKg == harvestHoneyKg &&
          other.harvestHoneySupers == harvestHoneySupers &&
          other.harvestHivesInvolved == harvestHivesInvolved &&
          other.feedingAmountTotal == feedingAmountTotal &&
          other.treated == treated &&
          other.treatmentHivesInvolved == treatmentHivesInvolved);

  @override
  int get hashCode => Object.hash(
    apiaryId,
    isPlanned,
    isVisited,
    activityCount,
    hiveCount,
    harvestHoneyKg,
    harvestHoneySupers,
    harvestHivesInvolved,
    feedingAmountTotal,
    treated,
    treatmentHivesInvolved,
  );

  @override
  String toString() =>
      'ApiaryJourneyStats(apiaryId: $apiaryId, isPlanned: $isPlanned, '
      'isVisited: $isVisited, activityCount: $activityCount, '
      'hiveCount: $hiveCount, harvestHoneyKg: $harvestHoneyKg, '
      'harvestHoneySupers: $harvestHoneySupers, '
      'harvestHivesInvolved: $harvestHivesInvolved, '
      'feedingAmountTotal: $feedingAmountTotal, treated: $treated, '
      'treatmentHivesInvolved: $treatmentHivesInvolved)';
}

/// Pure per-apiary aggregation (#391) — the "More stats" breakdown screen's
/// own arithmetic, mirroring [computeJourneyStats]'s "no database
/// dependency" convention. [plannedApiaryIds] is the journey's current plan
/// (de-duped, order preserved). [activities] is every activity attributed to
/// this journey (any apiary, D-21's stored-`journey_id` scoping — the caller
/// already did that query via `activitiesByJourneyProvider`). [hiveCounts]
/// is every apiary's current hive counter value, keyed by apiary id (an
/// apiary absent from this map reads as 0 — [ApiaryJourneyStats.hiveCount]'s
/// own always-displays convention).
///
/// Returns one entry per apiary in the union of "planned" and "has an
/// attributed activity" — planned apiaries first (in the plan's own order),
/// then any visited-but-unplanned apiary in the order it first appears in
/// [activities] — mirroring journey_detail_screen.dart's `_ApiaryEntries`
/// ordering convention.
List<ApiaryJourneyStats> computePerApiaryJourneyStats({
  required List<String> plannedApiaryIds,
  required List<JourneyActivityRecord> activities,
  required Map<String, int> hiveCounts,
}) {
  final plannedSeen = <String>{};
  final planned = <String>[
    for (final id in plannedApiaryIds)
      if (plannedSeen.add(id)) id,
  ];

  final byApiary = <String, List<JourneyActivityRecord>>{};
  final visitOrder = <String>[];
  for (final activity in activities) {
    if (!byApiary.containsKey(activity.apiaryId)) {
      visitOrder.add(activity.apiaryId);
    }
    (byApiary[activity.apiaryId] ??= []).add(activity);
  }

  final orderedIds = <String>[
    ...planned,
    for (final id in visitOrder)
      if (!plannedSeen.contains(id)) id,
  ];

  return [
    for (final apiaryId in orderedIds)
      _computeOneApiary(
        apiaryId: apiaryId,
        isPlanned: plannedSeen.contains(apiaryId),
        activities: byApiary[apiaryId] ?? const [],
        hiveCount: hiveCounts[apiaryId] ?? 0,
      ),
  ];
}

ApiaryJourneyStats _computeOneApiary({
  required String apiaryId,
  required bool isPlanned,
  required List<JourneyActivityRecord> activities,
  required int hiveCount,
}) {
  num honeyKg = 0;
  var honeySupers = 0;
  var harvestHives = 0;
  num feedAmount = 0;
  var treated = false;
  var treatmentHives = 0;

  for (final activity in activities) {
    final attrs = activity.attributes;
    switch (activity.type) {
      case activityTypeHarvest:
        honeyKg += (attrs['honey_kg'] as num?) ?? 0;
        honeySupers += (attrs['honey_supers'] as num?)?.toInt() ?? 0;
        harvestHives += (attrs['hives_involved'] as num?)?.toInt() ?? 0;
      case activityTypeFeeding:
        feedAmount += (attrs['feed_amount'] as num?) ?? 0;
      case activityTypeTreatment:
        treated = true;
        treatmentHives += (attrs['hives_involved'] as num?)?.toInt() ?? 0;
    }
  }

  return ApiaryJourneyStats(
    apiaryId: apiaryId,
    isPlanned: isPlanned,
    isVisited: activities.isNotEmpty,
    activityCount: activities.length,
    hiveCount: hiveCount,
    harvestHoneyKg: honeyKg,
    harvestHoneySupers: honeySupers,
    harvestHivesInvolved: harvestHives,
    feedingAmountTotal: feedAmount,
    treated: treated,
    treatmentHivesInvolved: treatmentHives,
  );
}
