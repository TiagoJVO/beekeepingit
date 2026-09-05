import '../../core/l10n/diacritics.dart';
import '../activities/activities_repository.dart';
import 'apiaries_repository.dart';

/// How many days without a recorded activity make an apiary count as "not
/// visited recently" (D-35, #658).
///
/// **30 days is D-35's own deliberate default** — no prior requirement fixed
/// this number, so it is a product-owner choice recorded there rather than a
/// value derived from `FR-AP-*`. Documented here instead of left as a bare
/// magic number at the call site, the same way notification_engine.dart owns
/// its `_dueSoonWindowDays` window.
///
/// It lives in the **apiaries** feature, not the home feature that first
/// consumes it (#658's Home summary section): the moment an apiary-list badge
/// or a map marker wants the same "stale" mark, it reuses this constant and
/// [apiariesNotVisitedSince] rather than re-deriving the rule — two surfaces
/// disagreeing about what "recently" means is exactly the drift D-35 calls
/// out ("owned as one constant in the client's apiaries feature so other
/// surfaces reuse it rather than re-deriving it").
const apiaryVisitRecencyDays = 30;

/// [d]'s calendar day at local midnight — the same day-only normalization
/// todo_filters.dart applies before comparing plain `YYYY-MM-DD` values, and
/// what [DateTime.parse] of such a string already returns.
DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Whole days between two calendar days, counted on **UTC** midnights.
///
/// Subtracting local midnights would silently lose (or gain) an hour across a
/// DST transition, turning a 30-day gap into `inDays == 29` and flipping the
/// [apiaryVisitRecencyDays] boundary twice a year. These UTC instants are
/// never stored or displayed — they exist only for this subtraction.
int _daysBetween(DateTime from, DateTime to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// The most recent activity date per apiary id, keyed by
/// [Activity.apiaryId].
///
/// [Activity.occurredAt] is a plain `YYYY-MM-DD` string (no time-of-day),
/// mirroring the server's `DATE` column — parsed here through the model's own
/// [Activity.occurredAtDate] so this file never re-implements that format.
/// Apiaries with no activity are simply absent from the map; there is no
/// sentinel date.
Map<String, DateTime> lastVisitByApiary(List<Activity> activities) {
  final result = <String, DateTime>{};
  for (final activity in activities) {
    final occurred = _dateOnly(activity.occurredAtDate);
    final current = result[activity.apiaryId];
    if (current == null || occurred.isAfter(current)) {
      result[activity.apiaryId] = occurred;
    }
  }
  return result;
}

/// One apiary that hasn't been visited within the recency window (D-35,
/// #658), together with everything the Home summary section needs to render
/// its subtitle — so the widget never re-derives a date difference of its own.
class ApiaryVisitRecency {
  const ApiaryVisitRecency({
    required this.apiary,
    required this.lastVisitedAt,
    required this.daysSinceLastVisit,
  });

  final Apiary apiary;

  /// The date of the apiary's most recent activity, or **null when the apiary
  /// has never been visited** — a distinct state D-35 calls out explicitly
  /// ("apiaries never visited are included and sort first"), not a stand-in
  /// for "very long ago". Callers must render it as its own case (see
  /// [neverVisited]), never as "0 days ago".
  final DateTime? lastVisitedAt;

  /// Whole days between [lastVisitedAt] and the `now` the list was computed
  /// against, or null exactly when [lastVisitedAt] is null. Carried on the
  /// result (rather than recomputed at render time from a second
  /// `DateTime.now()`) for the same reason `TodosViewModel` carries its
  /// `today`: two clock reads can straddle a midnight rollover and disagree.
  final int? daysSinceLastVisit;

  bool get neverVisited => lastVisitedAt == null;
}

/// The [apiaries] with no recorded activity in the last [days] (D-35, #658),
/// ordered **never-visited first, then longest-since-visit first**.
///
/// The boundary is **inclusive**: an apiary last visited exactly [days] ago
/// is included ("30 days with no recorded activity" reads as "the 30th day
/// counts"), one visited 29 days ago is not.
///
/// [now] is a parameter and never read from the clock in here, mirroring how
/// `TodosViewModel` threads a single `today` through its filter/sort: one
/// caller-owned instant means the section header count and the rows under it
/// can't be computed against two different days.
///
/// Activities referencing an apiary absent from [apiaries] (a different org's
/// row can't reach the client, but a locally-deleted apiary's activity can
/// still sit in the store) are ignored — the result is driven by [apiaries],
/// which is also why an empty [apiaries] yields an empty list regardless of
/// [activities].
List<ApiaryVisitRecency> apiariesNotVisitedSince({
  required List<Apiary> apiaries,
  required List<Activity> activities,
  required DateTime now,
  int days = apiaryVisitRecencyDays,
}) {
  final today = _dateOnly(now);
  final lastVisits = lastVisitByApiary(activities);

  final stale = <ApiaryVisitRecency>[];
  for (final apiary in apiaries) {
    final lastVisit = lastVisits[apiary.id];
    if (lastVisit == null) {
      stale.add(
        ApiaryVisitRecency(
          apiary: apiary,
          lastVisitedAt: null,
          daysSinceLastVisit: null,
        ),
      );
      continue;
    }
    final elapsed = _daysBetween(lastVisit, today);
    if (elapsed >= days) {
      stale.add(
        ApiaryVisitRecency(
          apiary: apiary,
          lastVisitedAt: lastVisit,
          daysSinceLastVisit: elapsed,
        ),
      );
    }
  }

  stale.sort(_byStaleness);
  return stale;
}

/// Never-visited first, then oldest last-visit first, then by name — the
/// name tie-break (diacritic- and case-insensitive, reusing the apiary
/// search fold so "Águas" sorts with the A's) exists so two apiaries sharing
/// a last-visit date, which is common when a journey logs several on one
/// day, always render in the same order instead of inheriting the incoming
/// list's order. Id breaks a duplicate-name tie so the ordering is total.
int _byStaleness(ApiaryVisitRecency a, ApiaryVisitRecency b) {
  final aVisit = a.lastVisitedAt;
  final bVisit = b.lastVisitedAt;
  if (aVisit == null && bVisit != null) return -1;
  if (aVisit != null && bVisit == null) return 1;
  if (aVisit != null && bVisit != null) {
    final byDate = aVisit.compareTo(bVisit);
    if (byDate != 0) return byDate;
  }
  final byName = normalizeForSearch(a.apiary.name)
      .compareTo(normalizeForSearch(b.apiary.name));
  if (byName != 0) return byName;
  return a.apiary.id.compareTo(b.apiary.id);
}
