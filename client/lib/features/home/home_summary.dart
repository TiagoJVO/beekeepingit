import '../activities/activities_repository.dart';
import '../apiaries/apiaries_repository.dart';
import '../apiaries/apiary_visit_recency.dart';
import '../journeys/journeys_repository.dart';
import '../todos/todo_due.dart';
import '../todos/todo_priority.dart';
import '../todos/todos_repository.dart';

/// How many rows a Home section renders under its header (#658, D-35: "each a
/// count plus the most relevant few").
///
/// **Three** is a layout budget, not a domain rule: D-35 puts three sections
/// on one screen, and three rows plus a header per section is what still fits
/// above the fold on the narrowest phone this app targets (375 px logical
/// width) without Home becoming a scroll-to-find-anything list — the opposite
/// of the "what needs me right now" glance it exists to be.
///
/// It caps the **preview only**. Every [HomeSummarySection.count] always
/// reports the FULL matching set, so a header reading "12" above three rows is
/// the intended, correct rendering — the "see all" tap-through to that list
/// screen is what shows the rest.
const kHomePreviewLimit = 3;

/// One Home section: how many records matched, plus the first
/// [kHomePreviewLimit] of them in the section's own order.
///
/// [count] is deliberately independent of `preview.length` — collapsing the
/// two would make Home under-report the org's real workload the moment a
/// fourth item exists.
class HomeSummarySection<T> {
  const HomeSummarySection({required this.count, required this.preview});

  /// Builds a section from the FULL, already-ordered match set: [count] is
  /// its length, [preview] its first [kHomePreviewLimit] entries. The single
  /// place the cap is applied, so no section can accidentally count only what
  /// it renders.
  factory HomeSummarySection.from(List<T> matches) => HomeSummarySection(
    count: matches.length,
    preview: List.unmodifiable(matches.take(kHomePreviewLimit)),
  );

  /// The number of records that matched this section's rule — the full set,
  /// not the previewed subset.
  final int count;

  /// At most [kHomePreviewLimit] matches, in the section's own order.
  final List<T> preview;

  bool get isEmpty => count == 0;

  bool get isNotEmpty => count > 0;

  /// True when the section matched more than it previews — what a "see all
  /// (N)" affordance keys off, so the widget never re-derives the cap.
  bool get hasMore => count > preview.length;
}

/// One todo needing attention, paired with the [TodoDueBucket] it fell into.
///
/// The bucket rides on the result — rather than the row widget calling
/// [todoDueBucket] again with a fresh `DateTime.now()` — for exactly the
/// reason [ApiaryVisitRecency] carries its own `daysSinceLastVisit`: a second
/// clock read can straddle a midnight rollover, and a row badged "due soon"
/// inside a list the summary already decided was overdue is a contradiction
/// the user sees.
class AttentionTodo {
  const AttentionTodo({required this.todo, required this.bucket});

  final Todo todo;
  final TodoDueBucket bucket;
}

/// How much of what Home renders is actually KNOWN right now (#658 review).
///
/// **A separate axis from [HomeSummaryState], deliberately.** The two answer
/// different questions — "what did the data say" versus "do we have the data
/// at all" — and they genuinely co-occur: a resolved todos stream alongside a
/// dead apiaries query must render the tasks section AND admit the rest is
/// missing. Folding readiness into the state enum would force that
/// combination to pick one and drop the other, which is exactly the
/// swallowing this exists to stop. [HomeSummaryState] still gains the two
/// variants that describe a screen with NOTHING to show, so the widget's
/// exhaustive `switch` keeps being the closed set that renders Home.
///
/// Computed by `home_providers.dart` from the four dependencies'
/// [AsyncValue]s — the only layer that can see them. [buildHomeSummary] stays
/// pure and takes the answer as a parameter.
enum HomeDataReadiness {
  /// Every dependency has produced a value and none is in error. The only
  /// readiness under which Home may make a claim ABOUT ABSENCE — "your org
  /// owns nothing", "nothing needs you" — since those are statements about
  /// data that is known to be complete.
  ready,

  /// Nothing has failed, but at least one dependency has not reported yet:
  /// the cold-start window while the local store opens and its first queries
  /// return. Present on EVERY launch, which is why it must not read as an
  /// empty org.
  waiting,

  /// At least one dependency is in error — a local store that would not open
  /// (denied storage, a private-mode browser, a worker that failed to load),
  /// or one that died mid-session. Held even when a prior value survives in
  /// the [AsyncValue]: without it, a store that dies after first emission
  /// freezes Home on stale data with nothing on screen to say so.
  unavailable,
}

/// Which of Home's mutually exclusive whole-screen states applies (#658).
///
/// D-35 asks for "a genuine first-run state (one action: add your first
/// apiary) and an all-clear state, rather than several empty sections" — so
/// these are a closed set an exhaustive `switch` renders, never independent
/// booleans a widget could combine into an undesigned screen.
///
/// D-35's three are joined by two that describe a screen with nothing
/// TRUSTWORTHY to show (#658 review). Both used to render as [firstRun],
/// because the provider coalesced every dependency to `.value ?? const []`
/// and an unresolved or errored stream became indistinguishable from an
/// empty one — so Home told a user whose org already owns apiaries "Let's
/// set up your first apiary" and offered a button that creates a duplicate.
enum HomeSummaryState {
  /// The org has no records at all — not one apiary, activity, todo or
  /// journey. The onboarding case: one action, add your first apiary.
  ///
  /// Requires [HomeDataReadiness.ready]: this is a claim that the org owns
  /// NOTHING, and only complete data can support it.
  firstRun,

  /// The org has data, but nothing in it needs attention right now. A
  /// positive state, not three empty sections stacked up. Also requires
  /// [HomeDataReadiness.ready], for the same reason.
  allClear,

  /// At least one section matched.
  needsAttention,

  /// Nothing matched and [HomeDataReadiness.waiting] — the cold-start
  /// window. Home knows nothing yet, so it says nothing yet: this renders
  /// blank, NOT a spinner (FR-OF-1 — offline is the normal case, not a
  /// loading state — and a spinner on the app's landing screen is the thing
  /// D-35's at-a-glance summary exists to avoid).
  notReady,

  /// Nothing matched and [HomeDataReadiness.unavailable] — the local store
  /// could not be read at all. One honest message, in the same
  /// notify-and-fix voice `sync_needs_fix_screen.dart` uses, rather than a
  /// screen that quietly asserts the org is empty forever.
  unavailable,
}

/// Everything Home renders (#658, D-35), derived in one pass from the four
/// org-scoped local streams — deliberately NOT including sync state (already
/// in the app-shell header) or pending stock declarations (D-19 derives no
/// deadlines, so "pending" has no definition to surface).
class HomeSummary {
  const HomeSummary({
    required this.attentionTodos,
    required this.openJourneys,
    required this.staleApiaries,
    required this.state,
    required this.readiness,
    required this.overdueTodoCount,
    required this.now,
  });

  /// Todos that are overdue or due soon, per [todoDueBucket].
  final HomeSummarySection<AttentionTodo> attentionTodos;

  /// Journeys still open, per [Journey.isOpen].
  final HomeSummarySection<Journey> openJourneys;

  /// Apiaries with no recorded activity inside the recency window, per
  /// [apiariesNotVisitedSince].
  final HomeSummarySection<ApiaryVisitRecency> staleApiaries;

  final HomeSummaryState state;

  /// How complete the data behind [state] and the three sections is (#658
  /// review).
  ///
  /// Read by the widget ALONGSIDE [state], because a [state] of
  /// [HomeSummaryState.needsAttention] with a readiness of
  /// [HomeDataReadiness.unavailable] is a real, reachable combination — some
  /// dependencies resolved and some died — and Home then shows both the
  /// sections it does have and a notice that the rest could not be read.
  final HomeDataReadiness readiness;

  /// How many of [attentionTodos] are [TodoDueBucket.overdue], over the FULL
  /// matching set rather than the capped preview.
  ///
  /// Exists so the tasks section's "view all" link can be labelled with the
  /// subset it actually opens. The section is the UNION of overdue and
  /// due-soon, but `/todos?status=overdue` is only its overdue half — the
  /// Todos tab cannot express the union today (#661). Counted here rather
  /// than in the widget because the widget only ever sees
  /// [kHomePreviewLimit] rows and would under-report on any larger set.
  final int overdueTodoCount;

  /// The single instant all three sections were computed against
  /// ([buildHomeSummary]'s own `now` parameter) — carried here, exactly like
  /// `TodosViewModel.today`, so nothing downstream needs a clock read of its
  /// own and no two sections can disagree about what day it is.
  final DateTime now;
}

/// Builds the Home summary (#658, D-35) from the org's todos, journeys,
/// apiaries and activities as of [now].
///
/// Pure: no clock read, no I/O, no provider access — [now] is the only
/// time input, which is what lets a test pin a midnight boundary and what
/// guarantees the three sections can never be computed against two different
/// days.
///
/// Every section's rule is DELEGATED to the feature that owns it —
/// [todoDueBucket] for overdue/due-soon, [Journey.isOpen] for open, and
/// [apiariesNotVisitedSince] for the 30-day recency window. Home re-derives
/// none of them: D-35 explicitly wants one owner per rule so surfaces cannot
/// drift apart.
///
/// [readiness] is the caller's answer to "is this all the data there is?" —
/// the one thing this function cannot see for itself, since it receives plain
/// lists and an empty list from an unresolved stream is identical to an empty
/// list from an empty org. It defaults to [HomeDataReadiness.ready] because
/// that IS the truth for a caller passing concrete lists; only
/// `home_providers.dart`, which can see the four [AsyncValue]s, ever passes
/// anything else.
HomeSummary buildHomeSummary({
  required List<Todo> todos,
  required List<Journey> journeys,
  required List<Apiary> apiaries,
  required List<Activity> activities,
  required DateTime now,
  HomeDataReadiness readiness = HomeDataReadiness.ready,
}) {
  final attention = _attentionTodos(todos, now);
  final attentionTodos = HomeSummarySection.from(attention);
  // Not re-sorted: journeysStreamProvider already arrives newest-first
  // (JourneysRepository.watchAll's `ORDER BY created_at DESC`), and
  // `created_at` is not a field on [Journey] — so preserving the incoming
  // order is the only way to match the Journeys list screen's own order
  // rather than invent a second one.
  final openJourneys = HomeSummarySection.from(
    journeys.where((j) => j.isOpen).toList(),
  );
  final staleApiaries = HomeSummarySection.from(
    apiariesNotVisitedSince(
      apiaries: apiaries,
      activities: activities,
      now: now,
    ),
  );

  return HomeSummary(
    attentionTodos: attentionTodos,
    openJourneys: openJourneys,
    staleApiaries: staleApiaries,
    state: _stateFor(
      hasAnyData:
          apiaries.isNotEmpty ||
          activities.isNotEmpty ||
          todos.isNotEmpty ||
          journeys.isNotEmpty,
      hasAnySection:
          attentionTodos.isNotEmpty ||
          openJourneys.isNotEmpty ||
          staleApiaries.isNotEmpty,
      readiness: readiness,
    ),
    readiness: readiness,
    overdueTodoCount: attention
        .where((a) => a.bucket == TodoDueBucket.overdue)
        .length,
    now: now,
  );
}

/// [firstRun] is "the org owns NOTHING", evaluated over the raw inputs rather
/// than over the sections: an org whose only todo is already done has data and
/// is [allClear], not on its first run — showing it "add your first apiary"
/// would be wrong.
///
/// **[readiness] is a floor under both absence claims (#658 review).**
/// [firstRun] and [allClear] each assert something about data that ISN'T
/// there, and only [HomeDataReadiness.ready] — every dependency resolved,
/// none errored — can support such a claim. Without the floor, a cold start
/// and a local store that never opened both arrived here as four empty lists
/// and were rendered as "your org owns nothing, add your first apiary".
///
/// A matched section still wins outright, before readiness is consulted:
/// finding something is a POSITIVE claim, true regardless of what else is
/// still missing, and refusing to paint it would trade a lie for a blank
/// landing screen (FR-OF-1). The unresolved remainder is not lost — it rides
/// on [HomeSummary.readiness], which the widget surfaces as a notice above
/// the sections.
HomeSummaryState _stateFor({
  required bool hasAnyData,
  required bool hasAnySection,
  required HomeDataReadiness readiness,
}) {
  if (hasAnySection) return HomeSummaryState.needsAttention;
  return switch (readiness) {
    HomeDataReadiness.unavailable => HomeSummaryState.unavailable,
    HomeDataReadiness.waiting => HomeSummaryState.notReady,
    HomeDataReadiness.ready =>
      hasAnyData ? HomeSummaryState.allClear : HomeSummaryState.firstRun,
  };
}

/// Every todo [todoDueBucket] buckets as of [now], ordered by [_byUrgency].
List<AttentionTodo> _attentionTodos(List<Todo> todos, DateTime now) {
  final attention = <AttentionTodo>[];
  for (final todo in todos) {
    final bucket = todoDueBucket(todo, now);
    if (bucket == null) continue;
    attention.add(AttentionTodo(todo: todo, bucket: bucket));
  }
  attention.sort(_byUrgency);
  return attention;
}

/// Overdue before due-soon, then earliest due date first, then most urgent
/// priority first, then id.
///
/// **`sortTodos` does not fit here and is deliberately not used.** It applies
/// exactly ONE [TodoSortField] and always breaks ties on `Todo.id`, so it
/// cannot express this three-level ordering, and chaining two calls would not
/// compose either (its id tie-break destroys any prior order, and
/// `List.sort` is not stable). What this DOES reuse are the same building
/// blocks `sortTodos` itself is built from — [todoDueBucket] for the bucket
/// and [todoPriorityRank] for priority — so the two can never disagree about
/// what "overdue" or "more urgent" means, only about presentation order.
///
/// Every entry here has a non-null due date by construction ([todoDueBucket]
/// returns null without one), which is why this needs none of
/// `sortTodos`' null-due-date handling.
int _byUrgency(AttentionTodo a, AttentionTodo b) {
  // Redundant with the due-date comparison below as long as "overdue" means
  // "due before today" — kept because it is the ordering D-35 states, so a
  // future change to either rule fails loudly here instead of silently
  // reordering Home. Ranked explicitly, NOT by `TodoDueBucket.index`: that
  // enum declares `dueSoon` first, and leaning on declaration order would
  // invert Home the day a third bucket is appended.
  final byBucket = _bucketRank(a.bucket).compareTo(_bucketRank(b.bucket));
  if (byBucket != 0) return byBucket;

  final byDue = _dueDate(a.todo).compareTo(_dueDate(b.todo));
  if (byDue != 0) return byDue;

  // Descending rank: high before medium before low, matching
  // `defaultSortDirectionFor(TodoSortField.priority)`'s own most-urgent-first
  // default on the Todos tab.
  final byPriority = todoPriorityRank(
    b.todo.priority,
  ).compareTo(todoPriorityRank(a.todo.priority));
  if (byPriority != 0) return byPriority;

  return a.todo.id.compareTo(b.todo.id);
}

/// Sort weight for a bucket — lower renders first (overdue above due-soon).
int _bucketRank(TodoDueBucket bucket) => switch (bucket) {
  TodoDueBucket.overdue => 0,
  TodoDueBucket.dueSoon => 1,
};

/// The plain `YYYY-MM-DD` due date of a todo that has one. Only ever called
/// for an [AttentionTodo], which [todoDueBucket] guarantees has a due date —
/// a null here would be a programming error, and `??` would silently reorder
/// the list instead of surfacing it.
DateTime _dueDate(Todo todo) => DateTime.parse(todo.dueDate!);
