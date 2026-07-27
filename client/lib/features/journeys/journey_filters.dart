import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../activities/activities_repository.dart';
import 'journeys_repository.dart';

/// A closed `[start, end]` inclusive local date range for journeys' date-
/// range filter (#47, FR-JO-2) — same semantics as activity_filters.dart's
/// `ActivityDateRange`, kept as its own small type (rather than importing
/// that one directly) so journeys' filter state doesn't reach into the
/// activities feature's own internal type.
class JourneyDateRange {
  const JourneyDateRange({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JourneyDateRange &&
          _dateOnly(start) == _dateOnly(other.start) &&
          _dateOnly(end) == _dateOnly(other.end));

  @override
  int get hashCode => Object.hash(_dateOnly(start), _dateOnly(end));
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// A journey's plan-vs-done progress count (#47, FR-JO-2: "feitos/
/// planeados") — [planned] is the total number of plan items (apiaries to
/// visit), [done] is how many of those apiaries already have at least one
/// matching local activity. Deliberately just a count: the full harvested/
/// honey/média statistics aggregation is #49's separate FR-JO-1 scope, not
/// built here.
class JourneyProgress {
  const JourneyProgress({required this.planned, required this.done});

  final int planned;
  final int done;

  static const zero = JourneyProgress(planned: 0, done: 0);
}

/// Computes one journey's [JourneyProgress] (#47) from its planned apiary
/// ids and the (already journey-filtered) activities recorded against it — a
/// planned apiary counts as "done" once at least one of [journeyActivities]
/// was logged against that same apiary ([Activity.apiaryId]), mirroring the
/// issue's own definition ("count of journey_plan_items with at least one
/// matching executed activity, vs. total plan items").
JourneyProgress computeJourneyProgress({
  required List<String> plannedApiaryIds,
  required List<Activity> journeyActivities,
}) {
  if (plannedApiaryIds.isEmpty) return JourneyProgress.zero;
  final doneApiaryIds = journeyActivities.map((a) => a.apiaryId).toSet();
  final done = plannedApiaryIds.where(doneApiaryIds.contains).length;
  return JourneyProgress(planned: plannedApiaryIds.length, done: done);
}

/// Groups [activities] with a non-null [Activity.journeyId] by journey id —
/// the shape [computeJourneyProgress]/[filterJourneysByDateRange] both need,
/// since a [Journey] itself carries no back-reference to its activities.
/// Activities with no journey attached are dropped (they can't belong to any
/// journey's progress or date-range match).
Map<String, List<Activity>> groupActivitiesByJourney(
  List<Activity> activities,
) {
  final map = <String, List<Activity>>{};
  for (final activity in activities) {
    final journeyId = activity.journeyId;
    if (journeyId == null) continue;
    (map[journeyId] ??= []).add(activity);
  }
  return map;
}

/// Every journey's [JourneyProgress] (#47), keyed by journey id. A journey
/// with no plan items at all is omitted — callers treat a missing key as
/// [JourneyProgress.zero] (and, per the list screen's own convention, hide
/// the badge entirely rather than show a meaningless "0/0").
Map<String, JourneyProgress> progressByJourney(
  List<Journey> journeys,
  Map<String, List<String>> plannedApiaryIdsByJourney,
  Map<String, List<Activity>> activitiesByJourney,
) => {
  for (final journey in journeys)
    journey.id: computeJourneyProgress(
      plannedApiaryIds: plannedApiaryIdsByJourney[journey.id] ?? const [],
      journeyActivities: activitiesByJourney[journey.id] ?? const [],
    ),
};

/// Keeps only journeys whose [Journey.mainActivityType] equals [type], or
/// every journey when [type] is null (#47 AC: "filterable by activity
/// type") — a direct field match, since a journey's own type IS its main
/// activity type (unlike activities' own type filter over a list of
/// heterogeneous records).
List<Journey> filterJourneysByType(List<Journey> journeys, String? type) {
  if (type == null) return journeys;
  return journeys.where((j) => j.mainActivityType == type).toList();
}

/// Keeps only journeys with at least one activity (per [activitiesByJourney])
/// whose [Activity.occurredAtDate] falls within [range], inclusive of both
/// ends (#47 AC: "filterable by date range") — journeys carry no date of
/// their own (journeys_list_screen.dart's doc comment explains this
/// interpretation), so date-range filtering reaches into the journey's own
/// recorded activities. A journey with no activities yet cannot match a date
/// filter and is excluded whenever [range] is active. A null [range] is a
/// passthrough.
List<Journey> filterJourneysByDateRange(
  List<Journey> journeys,
  Map<String, List<Activity>> activitiesByJourney,
  JourneyDateRange? range,
) {
  if (range == null) return journeys;
  final start = _dateOnly(range.start);
  final end = _dateOnly(range.end);
  return journeys.where((j) {
    final activities = activitiesByJourney[j.id] ?? const [];
    return activities.any((a) {
      final d = _dateOnly(a.occurredAtDate);
      return !d.isBefore(start) && !d.isAfter(end);
    });
  }).toList();
}

/// Applies both filters together (#47 AC: "date-range and activity-type
/// filters can be combined") — the two predicates are independent, so
/// application order doesn't affect the result (mirrors activity_filters.
/// dart's own `filterActivities`).
List<Journey> filterJourneys(
  List<Journey> journeys,
  Map<String, List<Activity>> activitiesByJourney, {
  String? type,
  JourneyDateRange? dateRange,
}) => filterJourneysByDateRange(
  filterJourneysByType(journeys, type),
  activitiesByJourney,
  dateRange,
);

/// The Journeys tab's filter-state providers (#47). Plain `autoDispose`
/// (not `.family`-scoped like activity_filters.dart's own): there is only
/// ever one Journeys list screen — no embedded/per-apiary variant like
/// Activities has — so per-instance scoping has no second consumer to serve
/// yet (YAGNI).
final journeyTypeFilterProvider = StateProvider.autoDispose<String?>(
  (ref) => null,
);

/// Same scoping (none) as [journeyTypeFilterProvider], for the date-range
/// filter.
final journeyDateRangeFilterProvider =
    StateProvider.autoDispose<JourneyDateRange?>((ref) => null);

/// The filtered, ready-to-render state for the Journeys tab (#47) — mirrors
/// activity_filters.dart's own `ActivitiesViewModel` split between "no
/// journeys at all yet" (the onboarding-style empty state) and "the current
/// filters matched nothing" (the no-results state, #47 AC).
class JourneysViewModel {
  const JourneysViewModel({
    required this.hasAnyJourneys,
    required this.filtered,
    required this.progressByJourney,
  });

  final bool hasAnyJourneys;
  final List<Journey> filtered;
  final Map<String, JourneyProgress> progressByJourney;
}

/// Combines [journeysStreamProvider] (all journeys), [activitiesStreamProvider]
/// (for the date-range filter + progress badge — an activity's [Activity.
/// journeyId]/[Activity.apiaryId] is what ties it back to a journey) and
/// [journeyPlanApiariesByJourneyProvider] (the progress badge's planned side)
/// with the two filter-state providers above into one ready-to-render state.
/// Never awaits any of its dependencies' futures — only reads their current
/// `.value`, defaulting to empty — so it renders immediately (as empty)
/// while any of them is still loading, same offline-first convention
/// [activitiesViewModelProvider] itself relies on.
final journeysViewModelProvider =
    Provider.autoDispose<AsyncValue<JourneysViewModel>>((ref) {
      final journeysAsync = ref.watch(journeysStreamProvider);
      final activities =
          ref.watch(activitiesStreamProvider).value ?? const <Activity>[];
      final plannedApiaryIdsByJourney =
          ref.watch(journeyPlanApiariesByJourneyProvider).value ??
          const <String, List<String>>{};
      final type = ref.watch(journeyTypeFilterProvider);
      final dateRange = ref.watch(journeyDateRangeFilterProvider);

      return journeysAsync.whenData((journeys) {
        final activitiesByJourney = groupActivitiesByJourney(activities);
        final filtered = filterJourneys(
          journeys,
          activitiesByJourney,
          type: type,
          dateRange: dateRange,
        );
        return JourneysViewModel(
          hasAnyJourneys: journeys.isNotEmpty,
          filtered: filtered,
          // Computed over the FILTERED set, not every journey — only rows
          // that actually render need a progress lookup (#47).
          progressByJourney: progressByJourney(
            filtered,
            plannedApiaryIdsByJourney,
            activitiesByJourney,
          ),
        );
      });
    });
