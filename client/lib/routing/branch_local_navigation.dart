import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// **One rule for opening a record from a list that previews it (#666, #384,
/// FR-UX-1/FR-UX-2):** a row opens the record *inside the branch the user is
/// already in*, never by crossing into the record's own tab.
///
/// The shell is a [StatefulShellRoute] — one navigation stack per tab — so a
/// `context.go` to another branch's location does two things at once: it
/// switches the selected tab under the user, and it takes the screen they
/// came from out of the stack the shell's Back pops. Back then lands on the
/// *target* tab's list, somewhere the user never was.
///
/// This file is where that rule lives, so there is exactly one of it. It
/// replaces two independently-written instances:
///
/// * **#384** — a journey's own activity rows, which routed into the
///   apiaries branch until `journeyActivityDetail` was added under the
///   journeys branch and `ActivityListView` grew a per-caller
///   `detailLocationBuilder` override to reach it. The override is gone: the
///   tile now asks this file, which answers from where the tap happened.
/// * **#666** — the Home summary's task / journey / apiary rows, which
///   routed into the todos / journeys / apiaries branches from the app's
///   landing screen (D-35), for every row it renders.
///
/// **The boundary is one hop.** A branch owns a read-only copy of the record
/// its own list previews — that is all. Everything *past* that first record
/// (edit forms, full lists, per-entity history) is a deliberate handoff into
/// the entity's owning tab, where those surfaces live and where the user has
/// now gone to work; the bottom nav follows them there, so it still says
/// where they are. That is the same split `journeyActivityDetail` has always
/// documented ("edit/delete/history stay reachable only via the
/// apiaries-branch route"), stated once here for every branch.
///
/// Every function below is a pure `String` -> `String` mapping of the CURRENT
/// location to a destination, so the rule is unit-testable without pumping a
/// router ([branchLocationOf] is the only part that needs a [BuildContext]).

/// The Home branch's root — the app's landing screen (D-35).
const String homeBranchRoot = '/home';

/// Whether [location] is a page of the Home branch's own stack.
///
/// Prefix-matched against `'/home/'` (with the exact root as a separate
/// case), never `startsWith('/home')` alone: a future top-level `/homestead`
/// would otherwise be read as a Home page.
bool isInHomeBranch(String location) =>
    location == homeBranchRoot || location.startsWith('$homeBranchRoot/');

/// The journey whose stack [location] sits in, or null when it sits
/// elsewhere.
///
/// `/journeys` itself and `/journeys/new` are not a journey's stack, so both
/// yield null — `new` is the create form, not an id.
String? journeyBranchIdOf(String location) {
  final match = RegExp(r'^/journeys/([^/]+)').firstMatch(location);
  final id = match?.group(1);
  return (id == null || id == 'new') ? null : id;
}

/// Where a todo's read-only detail lives for a tap made at [from].
String todoDetailLocation({required String from, required String todoId}) =>
    isInHomeBranch(from) ? '$homeBranchRoot/todos/$todoId' : '/todos/$todoId';

/// Where a journey's detail lives for a tap made at [from].
String journeyDetailLocation({
  required String from,
  required String journeyId,
}) => isInHomeBranch(from)
    ? '$homeBranchRoot/journeys/$journeyId'
    : '/journeys/$journeyId';

/// Where an apiary's detail lives for a tap made at [from].
String apiaryDetailLocation({
  required String from,
  required String apiaryId,
}) => isInHomeBranch(from)
    ? '$homeBranchRoot/apiaries/$apiaryId'
    : '/apiaries/$apiaryId';

/// Where an activity's read-only detail lives for a tap made at [from].
///
/// Inside a journey's own stack that is the journeys-branch copy (#384),
/// which carries [apiaryId] as a query parameter rather than a path segment
/// — the route's identity there is the journey, not the apiary — so the page
/// still reloads and deep-links without a live lookup first. Anywhere else
/// (the Activities tab, an apiary's own embedded list) it is the
/// apiaries-branch route, which is also where the activity's edit, delete and
/// history surfaces live.
///
/// Home renders no activity rows, so it needs no copy of its own: the one
/// place an activity is reachable from Home's branch is the apiary detail
/// page it opens, whose embedded activity list is already one hop past the
/// record — a handoff, per this file's boundary rule.
String activityDetailLocation({
  required String from,
  required String apiaryId,
  required String activityId,
}) {
  final journeyId = journeyBranchIdOf(from);
  return journeyId == null
      ? '/apiaries/$apiaryId/activities/$activityId'
      : '/journeys/$journeyId/activities/$activityId?apiaryId=$apiaryId';
}

/// Where a detail screen opened at [from] goes when its record turns out to
/// be gone — deleted under it, or a stale deep link.
///
/// [ownerList] is the entity's own list route, which is the right answer
/// everywhere except a branch-local copy: a record opened from Home that no
/// longer exists returns the user to Home, not to a tab they never chose.
String recordGoneLocation({
  required String from,
  required String ownerList,
}) => isInHomeBranch(from) ? homeBranchRoot : ownerList;

/// The location of the page calling from [context] — the `from` every
/// function above takes.
///
/// The full current path, not the calling route's `matchedLocation`, so a
/// widget embedded partway down a page reads the same branch as the page
/// itself. Query and fragment are dropped: the rule keys off which branch's
/// stack this is, and nothing else.
String branchLocationOf(BuildContext context) =>
    GoRouterState.of(context).uri.path;
