import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import 'activities_repository.dart';

/// A closed `[start, end]` inclusive local date range for the date-range
/// filter (#42/#43, FR-AC-5/FR-AC-6). Deliberately plain Dart (not Flutter's
/// `DateTimeRange`) — this file holds pure filter logic + Riverpod state,
/// consistent with apiaries_repository.dart's own pure sort/filter helpers
/// not depending on any widget-layer type.
class ActivityDateRange {
  const ActivityDateRange({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ActivityDateRange &&
          _dateOnly(start) == _dateOnly(other.start) &&
          _dateOnly(end) == _dateOnly(other.end));

  @override
  int get hashCode => Object.hash(_dateOnly(start), _dateOnly(end));
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Keeps only [type]-matching activities, or every activity when [type] is
/// null (the filter's cleared/default "all types" state) — mirrors
/// apiaries_repository.dart's `filterApiariesByQuery` empty-query
/// passthrough.
List<Activity> filterActivitiesByType(List<Activity> activities, String? type) {
  if (type == null) return activities;
  return activities.where((a) => a.type == type).toList();
}

/// Keeps only activities whose [Activity.occurredAtDate] falls within
/// [range], inclusive of both ends, compared by calendar date only (the
/// server's `occurred_at` column — and this client's mirror — carries no
/// time-of-day component). A null [range] is a passthrough.
List<Activity> filterActivitiesByDateRange(
  List<Activity> activities,
  ActivityDateRange? range,
) {
  if (range == null) return activities;
  final start = _dateOnly(range.start);
  final end = _dateOnly(range.end);
  return activities.where((a) {
    final d = _dateOnly(a.occurredAtDate);
    return !d.isBefore(start) && !d.isAfter(end);
  }).toList();
}

/// Applies both filters together (#42/#43 AC: "type and date-range filters
/// can be combined") — the two predicates are independent, so application
/// order doesn't affect the result.
List<Activity> filterActivities(
  List<Activity> activities, {
  String? type,
  ActivityDateRange? dateRange,
}) => filterActivitiesByDateRange(
  filterActivitiesByType(activities, type),
  dateRange,
);

/// The scope key [activitiesViewModelProvider]/the filter-state providers
/// below use for #43's main, cross-apiary Activities tab — there is only
/// ever one such screen, unlike #42's per-apiary sections which are keyed by
/// their own apiary id.
const allActivitiesScope = 'all';

/// Each list screen's own type-filter selection, scoped per screen instance
/// by `scope` (the apiary id for #42's embedded section, [allActivitiesScope]
/// for #43's main tab) — `.family` + `.autoDispose` mirrors apiaries_
/// repository.dart's apiaryCountersProvider/apiaryByIdProvider convention,
/// so opening one apiary's activities never leaks its filter selection into
/// another apiary's section, or into the main tab's own filters.
final activityTypeFilterProvider = StateProvider.autoDispose
    .family<String?, String>((ref, scope) => null);

/// Same scoping as [activityTypeFilterProvider], for the date-range filter.
final activityDateRangeFilterProvider = StateProvider.autoDispose
    .family<ActivityDateRange?, String>((ref, scope) => null);

/// The filtered, ready-to-render state for one activities list screen —
/// mirrors apiaries_list_screen.dart's own `ApiariesViewModel` split between
/// "no activities at all yet" (the onboarding-style empty state) and
/// "the current filters matched nothing" (the no-results state): both look
/// identical (an empty list) but need different messaging (#42/#43 AC).
class ActivitiesViewModel {
  const ActivitiesViewModel({
    required this.hasAnyActivities,
    required this.filtered,
  });

  final bool hasAnyActivities;
  final List<Activity> filtered;
}

/// [args.apiaryId] selects the data source: pass an apiary id for #42's
/// per-apiary section ([activitiesByApiaryProvider]), or null for #43's
/// main, org-wide tab ([activitiesStreamProvider]). [args.scope] keys the
/// filter-state providers above and must be unique per screen instance —
/// the apiary id for #42, [allActivitiesScope] for #43.
final activitiesViewModelProvider = Provider.autoDispose
    .family<
      AsyncValue<ActivitiesViewModel>,
      ({String scope, String? apiaryId})
    >((ref, args) {
      final activitiesAsync = args.apiaryId == null
          ? ref.watch(activitiesStreamProvider)
          : ref.watch(activitiesByApiaryProvider(args.apiaryId!));
      final type = ref.watch(activityTypeFilterProvider(args.scope));
      final dateRange = ref.watch(activityDateRangeFilterProvider(args.scope));
      return activitiesAsync.whenData(
        (activities) => ActivitiesViewModel(
          hasAnyActivities: activities.isNotEmpty,
          filtered: filterActivities(
            activities,
            type: type,
            dateRange: dateRange,
          ),
        ),
      );
    });
