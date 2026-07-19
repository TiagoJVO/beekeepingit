import 'journeys_repository.dart';

/// Pure matching logic for the #46 activity-form journey picker (FR-JO-1,
/// D-21) — kept as plain functions over a `List<Journey>` (no widget/
/// provider/database dependency) so the AC's "auto-match hit"/"auto-match
/// miss" cases are unit-testable in isolation, without a PowerSync database.
///
/// [JourneysRepository.watchMatching] already does the actual matching QUERY
/// (apiary_id + main_activity_type, the entire D-21 rule) against the local
/// store — this file only decides, given that already-scoped candidate set,
/// what to show by default vs. behind the "show hidden journeys" toggle, and
/// which single journey (if any) to auto-select.

/// The candidate list, split into what the picker shows by default (open
/// journeys) and what it hides behind the "show hidden journeys" toggle
/// (closed journeys) — D-21: "closed journeys are also selectable but hidden
/// by default".
class JourneyPickerCandidates {
  const JourneyPickerCandidates({required this.open, required this.closed});

  /// No matching journeys at all (auto-select is necessarily a miss, the
  /// picker's default list is empty until "show hidden" is toggled — if even
  /// then).
  static const empty = JourneyPickerCandidates(open: [], closed: []);

  /// Open matches, newest-first (mirrors [JourneysRepository.watchMatching]'s
  /// own ordering) — shown by default, and the source of [autoSelected].
  final List<Journey> open;

  /// Closed matches, newest-first — hidden by default, revealed by the
  /// picker's "show hidden journeys" toggle. Still directly selectable once
  /// revealed (D-21); attaching an activity to one is gated by a
  /// confirm-to-proceed warning at SAVE time (add_activity_screen.dart), not
  /// here.
  final List<Journey> closed;

  /// The AC's auto-select default: the most recently created OPEN match, or
  /// null for an "auto-match miss" (no open journey matches this apiary +
  /// activity type — the picker starts unselected, the user must pick one or
  /// create a new one). Never auto-selects a CLOSED journey — that always
  /// requires an explicit, deliberate pick (D-21's "hidden by default" +
  /// "requires an explicit confirm-to-proceed warning" both point at closed
  /// journeys never being a silent default).
  Journey? get autoSelected => open.isEmpty ? null : open.first;

  bool get isEmpty => open.isEmpty && closed.isEmpty;
}

/// Splits [candidates] (already scoped to one apiary + activity type by
/// [JourneysRepository.watchMatching]'s own query) into
/// [JourneyPickerCandidates.open]/[JourneyPickerCandidates.closed] by
/// [Journey.isOpen] — the only decision this function makes; it trusts the
/// caller to have already filtered by apiary/type (kept as a pure,
/// dependency-free split rather than re-deriving that filter here, so a unit
/// test can feed it a hand-built list without needing a fake apiary/type
/// match of its own).
JourneyPickerCandidates splitJourneyCandidates(List<Journey> candidates) {
  final open = <Journey>[];
  final closed = <Journey>[];
  for (final journey in candidates) {
    (journey.isOpen ? open : closed).add(journey);
  }
  return JourneyPickerCandidates(open: open, closed: closed);
}
