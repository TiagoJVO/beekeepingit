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
/// **The boundary is reading vs. doing.** Following a row that PREVIEWS a
/// record stays in the branch, however deep the reading goes — Home previews
/// a journey, that journey previews its own activities, and both taps stay
/// in Home's stack. ACTING on a record (edit forms, delete, the full "view
/// all" lists, per-entity history) is a deliberate handoff into the entity's
/// owning tab, where those surfaces live and where the user has now gone to
/// work; the bottom nav follows them there, so it still says where they are.
/// That is the same split `journeyActivityDetail` has always documented
/// ("edit/delete/history stay reachable only via the apiaries-branch
/// route"), stated once here for every branch.
///
/// A branch-local copy's path is the owning path with the branch root in
/// front of it — `/home/journeys/j1/activities/ac1` for
/// `/journeys/j1/activities/ac1` — so the mapping below is a PREFIX, not a
/// table, and app_router.dart's home branch mirrors the owning branches
/// segment for segment. A new preview surface therefore costs one route,
/// not a new special case in here.
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
///
/// Home's own copy of a journey counts: `/home/journeys/j1` IS that journey's
/// stack, in the branch Home owns. Without the optional prefix an activity
/// row on a journey opened from Home would fall through to the apiaries
/// branch — the very hand-off #384 exists to prevent, reached by another
/// door.
String? journeyBranchIdOf(String location) {
  final match = RegExp('^(?:$homeBranchRoot)?/journeys/([^/]+)')
      .firstMatch(location);
  final id = match?.group(1);
  return (id == null || id == 'new') ? null : id;
}

/// [ownerLocation] as reached from [from]'s own branch.
///
/// The whole mapping: inside the Home branch a record's location is the
/// owning location with `/home` in front of it, because that branch's routes
/// mirror the owning ones (app_router.dart). Everywhere else the owning
/// location already IS the branch-local one.
String _inBranchOf(String from, String ownerLocation) =>
    isInHomeBranch(from) ? '$homeBranchRoot$ownerLocation' : ownerLocation;

/// Where a todo's read-only detail lives for a tap made at [from].
String todoDetailLocation({required String from, required String todoId}) =>
    _inBranchOf(from, '/todos/$todoId');

/// Where a journey's detail lives for a tap made at [from].
String journeyDetailLocation({
  required String from,
  required String journeyId,
}) => _inBranchOf(from, '/journeys/$journeyId');

/// Where an apiary's detail lives for a tap made at [from].
String apiaryDetailLocation({required String from, required String apiaryId}) =>
    _inBranchOf(from, '/apiaries/$apiaryId');

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
/// Home renders no activity rows itself, but the journey and apiary pages it
/// opens do — an embedded PREVIEW list, so those taps stay in Home's stack
/// too (`/home/journeys/j1/activities/ac1`,
/// `/home/apiaries/a1/activities/ac1`), per the reading-vs-doing boundary
/// above.
String activityDetailLocation({
  required String from,
  required String apiaryId,
  required String activityId,
}) {
  final journeyId = journeyBranchIdOf(from);
  return _inBranchOf(
    from,
    journeyId == null
        ? '/apiaries/$apiaryId/activities/$activityId'
        : '/journeys/$journeyId/activities/$activityId?apiaryId=$apiaryId',
  );
}

/// Where a detail screen opened at [from] goes when its record turns out to
/// be gone — deleted under it, or a stale deep link.
///
/// [ownerList] is the entity's own list route, which is the right answer
/// everywhere except a branch-local copy: a record opened from Home that no
/// longer exists returns the user to Home, not to a tab they never chose.
String recordGoneLocation({required String from, required String ownerList}) =>
    isInHomeBranch(from) ? homeBranchRoot : ownerList;

/// The location of the page calling from [context] — the `from` every
/// function above takes.
///
/// The full current path, not the calling route's `matchedLocation`, so a
/// widget embedded partway down a page reads the same branch as the page
/// itself. Query and fragment are dropped: the rule keys off which branch's
/// stack this is, and nothing else.
String branchLocationOf(BuildContext context) =>
    GoRouterState.of(context).uri.path;

/// Whether the page calling from [context] is the one the user is actually
/// looking at.
///
/// [StatefulShellRoute.indexedStack] keeps every branch MOUNTED, merely
/// off-stage — so a page in an inactive branch still rebuilds when its data
/// changes, and a `context.go` fired from that rebuild would drag the user
/// out of the tab they are in (a record deleted from its own tab makes
/// Home's off-stage copy of it bounce, and the whole app would jump to
/// Home). Any navigation a screen performs on its OWN initiative must ask
/// this first; a navigation the user asked for by tapping cannot be
/// off-stage by definition, and does not need to.
///
/// [GoRouter.state] is the live top-level state, while the state registered
/// for this page is its own branch's saved location — the two differ exactly
/// when this page is off-stage.
bool isLiveLocation(BuildContext context) =>
    GoRouter.of(context).state.uri.path == branchLocationOf(context);
