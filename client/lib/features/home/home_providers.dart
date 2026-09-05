import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../activities/activities_repository.dart';
import '../apiaries/apiaries_repository.dart';
import '../journeys/journeys_repository.dart';
import '../todos/todos_repository.dart';
import 'home_summary.dart';

/// The live [HomeSummary] Home renders (#658, D-35) — composed from the four
/// org-scoped local streams and nothing else.
///
/// **Never `AsyncValue`, never awaited.** Each dependency is read as its
/// current `.value ?? const []`, exactly like `journeysViewModelProvider`
/// (journey_filters.dart). That is load-bearing twice over:
///
/// * Home paints **immediately** while the PowerSync streams warm up, instead
///   of showing a spinner on the app's landing screen (FR-OF-1: offline is the
///   normal case, not a loading state).
/// * A stream in error degrades **that section** to empty rather than throwing
///   the whole screen away — a not-yet-open sync session must not blank out
///   the other two sections.
///
/// **But `?? const []` is only ever a per-SECTION degrade (#658 review.)**
/// Read as the whole picture it erases the difference between "this org owns
/// nothing" and "we haven't been able to look yet", and Home used to render
/// both as its first-run state: a false sentence plus an *Add your first
/// apiary* button that invites a duplicate. It was reachable on **every**
/// launch (the wasm DB opening, before the first query returns) and permanent
/// when the local store failed to open at all — denied storage, a
/// private-mode browser, a worker that would not load — with no error text
/// anywhere and a header sync pill that reports *connection* state, so
/// nothing on screen contradicted it. [_readinessOf] reads the same four
/// [AsyncValue]s a second time to answer "is this all the data there is?",
/// and [buildHomeSummary] uses that as a floor under both of its
/// absence-claiming states.
///
/// **Tenancy (FR-TEN-2) is inherited, never re-implemented here.** This
/// provider issues no query of its own: [todosStreamProvider],
/// [journeysStreamProvider], [apiariesStreamProvider] and
/// [activitiesStreamProvider] each await `organizationProvider` and pass the
/// org id into a query carrying its own `organization_id = ? OR
/// organization_id IS NULL` predicate, on top of the org-scoped PowerSync
/// Sync Rule. Adding an `organization_id` filter here would be a second,
/// drifting copy of that rule — the composition IS the scoping.
///
/// That claim was **not** true of [apiariesStreamProvider] when this file
/// was written: it alone read unscoped and leaned on the Sync Rule as its
/// only layer, so on a shared device a previous user's org rows (nothing
/// purges the local store at login) surfaced here as never-visited apiaries
/// and Home rendered them by name. Closed in #658 by giving
/// `ApiariesRepository`'s reads the same Dart-side predicate its three
/// siblings already had; home_providers_test.dart pins the scenario.
///
/// **Known limitation (accepted for v1):** `now` is read once per rebuild, so
/// an app left open across midnight keeps showing the previous day's buckets
/// until something else rebuilds this provider (a sync emission, a navigation,
/// a resume). No ticker exists to force it, matching the rest of the app's
/// date handling (`todosViewModelProvider`'s identical per-rebuild
/// `DateTime.now()`); the single [HomeSummary.now] means the summary is at
/// worst uniformly stale, never internally inconsistent.
final homeSummaryProvider = Provider.autoDispose<HomeSummary>((ref) {
  final todos = ref.watch(todosStreamProvider);
  final journeys = ref.watch(journeysStreamProvider);
  final apiaries = ref.watch(apiariesStreamProvider);
  final activities = ref.watch(activitiesStreamProvider);

  return buildHomeSummary(
    todos: todos.value ?? const <Todo>[],
    journeys: journeys.value ?? const <Journey>[],
    apiaries: apiaries.value ?? const <Apiary>[],
    activities: activities.value ?? const <Activity>[],
    readiness: _readinessOf([todos, journeys, apiaries, activities]),
    // One clock read per rebuild, threaded through every section — see the
    // known limitation above.
    now: DateTime.now(),
  );
});

/// How much of [dependencies] has actually reported in — the input
/// [buildHomeSummary] cannot derive from the coalesced lists it receives.
///
/// **Error outranks not-yet-loaded**, since a dependency that failed is not
/// going to arrive by waiting, and a screen that stays blank forever is the
/// same lie as one that says the org is empty forever.
///
/// **A prior value does not clear the error.** `AsyncError` retains the last
/// `.value`, so a store that dies mid-session leaves the sections rendering
/// data that will now never update. Keeping this [HomeDataReadiness.unavailable]
/// is what puts a notice above those frozen sections instead of letting them
/// pass for live.
HomeDataReadiness _readinessOf(List<AsyncValue<Object?>> dependencies) {
  if (dependencies.any((d) => d.hasError)) {
    return HomeDataReadiness.unavailable;
  }
  if (dependencies.any((d) => !d.hasValue)) return HomeDataReadiness.waiting;
  return HomeDataReadiness.ready;
}
