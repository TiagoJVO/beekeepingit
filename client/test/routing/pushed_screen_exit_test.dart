import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/stock_declarations/stock_declarations_repository.dart';
import 'package:beekeepingit_client/features/sync/sync_rejected_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/a11y_matchers.dart' show kDesktopViewport, useViewport;
import '../widget_test.dart' show FakeDeviceLocationService;

/// #639 (FR-AP-10, FR-UX-2, FR-AX-1) — **no screen the app pushes is
/// reachable without also being leavable.**
///
/// Nine routes are declared OUTSIDE `StatefulShellRoute` in
/// `lib/routing/app_router.dart`. Four of them — `/login`, `/profile`,
/// `/organization/new`, `/organization/waiting` — are the gates the router's
/// own `redirect` pins the user to, and leaving one is not something the app
/// offers: the redirect would bounce them straight back. The remaining FIVE,
/// swept below, are normal authenticated leaves the user chose to open. That
/// they sit outside the shell is deliberate — they are settings-ish leaves,
/// not tabs — but it costs them BOTH of the shell's exits at once:
/// there is no bottom navigation (`shell-bottom-nav`) / desktop rail
/// (`shell-nav-rail`), and no shell back action (`shell-back-button`). The
/// screen's own `AppBar` is then the only way out, and two of them
/// (`/stock-declarations`, `/organization/details`) shipped without a
/// `leading`, leaving the user with nothing but the browser/OS back gesture —
/// which on the installed PWA (D-10) is not reliably there at all.
///
/// This is written as a SWEEP rather than as one more single-screen test on
/// purpose. The defect is not a property of either screen; it is a property of
/// the *pattern* — "declare a route outside the shell" silently removes the
/// navigation affordances, and nothing about adding the sixth such route would
/// remind the next author. So the table below is not merely a hand-kept list
/// that a new route could quietly slip past: `the sweep covers every
/// out-of-shell route` reads the LIVE router's own top-level routes and fails
/// if one is neither a gate nor swept here. Adding a sixth out-of-shell route
/// therefore breaks this file until its exit is pinned too, which is the part
/// a per-screen test cannot do.
///
/// It also asserts the shell really is hidden on each route, so the sweep
/// cannot be satisfied by the shell chrome quietly coming back: a screen that
/// still has bottom navigation was never the dead end this pins.
///
/// Each screen's own test file also pins the presence and a11y label of its
/// back control against a hermetic harness with no router. `app_router_test`
/// already drives two of these five (`/account`, `/organization/members`)
/// against the real router; this file is where all five are held to the same
/// bar uniformly, and where the sweep's completeness is enforced.

Profile _profileFixture() => Profile(
  id: 'u1',
  name: 'Ana',
  email: 'ana@example.com',
  locale: 'en',
  profileComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

/// A fixed, COMPLETE profile so the router's onboarding gate lets every route
/// below through without a real ApiClient/network call.
class _FixedProfileController extends ProfileController {
  @override
  Future<Profile> build() async => _profileFixture();
}

Organization _organizationFixture() => Organization(
  id: 'org-1',
  name: 'Dev Apiary Co.',
  address: '',
  registrationNumber: 'PT-111',
  createdBy: 'u1',
  // admin: `/organization/details` renders its fields editable rather than
  // read-only, which is the shape the screen is normally reached in.
  role: 'admin',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

/// A fixed organization so the router's org-completion gate (#26) resolves and
/// stops redirecting to `/organization/new`.
class _FixedOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => _organizationFixture();
}

/// An always-empty members controller so `/organization/members` renders its
/// real (empty) list instead of spinning on a never-resolving fetch.
class _EmptyMembersController extends MembersController {
  @override
  Future<MembersState> build() async =>
      const MembersState(members: [], invitations: []);
}

/// Reaches the live [GoRouter] of a pumped [BeekeepingitApp], so a test can
/// navigate to a route the UI offers no button for — and read back where the
/// router actually ended up.
GoRouter _routerOf(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(Navigator).first));

String _locationOf(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

Widget _buildApp() {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      deviceLocationServiceProvider.overrideWithValue(
        const FakeDeviceLocationService(),
      ),
      // Home is the landing screen (#658, D-35) and composes all four
      // org-scoped streams, so all four are stubbed to keep the landing render
      // hermetic — every route below is navigated to FROM there.
      apiariesStreamProvider.overrideWith((ref) => Stream.value(const [])),
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      journeysStreamProvider.overrideWith(
        (ref) => Stream.value(const <Journey>[]),
      ),
      activitiesStreamProvider.overrideWith(
        (ref) => Stream.value(const <Activity>[]),
      ),
      profileProvider.overrideWith(_FixedProfileController.new),
      organizationProvider.overrideWith(_FixedOrganizationController.new),
      membersProvider.overrideWith(_EmptyMembersController.new),
      // The two out-of-shell leaves that read from the local store directly;
      // without these they would spin on a PowerSync connection this suite
      // has no business opening.
      stockDeclarationsStreamProvider.overrideWith(
        (ref) => Stream.value(const <StockDeclaration>[]),
      ),
      syncRejectedOpsProvider.overrideWith(
        (ref) => Stream.value(const <RejectedOp>[]),
      ),
    ],
    child: const BeekeepingitApp(),
  );
}

/// One out-of-shell route, the key of the back control its own app bar owes
/// the user, and where that control must land.
///
/// [destination] is asserted exactly, not merely "somewhere else". Each screen
/// documents the screen it goes back to (Home for the two Home links, Account
/// for the three Account leaves), and a comment saying so with only a
/// "location changed" assertion behind it would let the destination drift
/// silently — the shape of failure #639 itself is.
typedef _PushedScreen = ({
  String route,
  Key backButton,
  String destination,
  String description,
});

const _pushedScreens = <_PushedScreen>[
  (
    route: '/account',
    backButton: Key('account-back-button'),
    destination: '/home',
    description: 'the account screen',
  ),
  (
    route: '/organization/members',
    backButton: Key('members-back-button'),
    destination: '/home',
    description: 'the members screen',
  ),
  (
    route: '/organization/details',
    backButton: Key('organization-details-back-button'),
    destination: '/account',
    description: 'the organization-details screen',
  ),
  (
    route: '/stock-declarations',
    backButton: Key('stock-declarations-back-button'),
    destination: '/account',
    description: 'the stock-declaration log',
  ),
  (
    route: '/sync-needs-fix',
    backButton: Key('needs-fix-back-button'),
    destination: '/account',
    description: 'the needs-fix list',
  ),
];

/// One of the app shell's two navigation affordances, and the viewport at
/// which it actually renders.
///
/// The shell swaps chrome at `BrandDimens.breakpointExpanded` (840): the
/// `NavigationBar` below it, the `NavigationRail` at or above (#650). A single
/// surface can therefore only ever disprove ONE of them — at the default
/// 800x600 test surface a "no rail" assertion passes on an in-shell route just
/// as happily, so it proves nothing. Each half runs at a width where the
/// affordance it denies would otherwise be on screen, and asserts it IS on
/// `/home` first.
typedef _ShellChrome = ({
  Key key,
  // `null` means "leave the default 800x600 surface alone" — below the
  // breakpoint, which is exactly where the bottom bar belongs.
  Size? viewport,
  String description,
});

const _shellChrome = <_ShellChrome>[
  (
    key: Key('shell-bottom-nav'),
    viewport: null,
    description: 'bottom navigation',
  ),
  (
    key: Key('shell-nav-rail'),
    viewport: kDesktopViewport,
    description: 'desktop navigation rail (#650)',
  ),
];

/// The out-of-shell routes the router's own `redirect` pins the user to. They
/// are exempt from the sweep because leaving one is not something the app
/// offers — the redirect bounces the user straight back — so there is no exit
/// affordance to pin.
const _gateRoutes = <String>{
  '/login',
  '/profile',
  '/organization/new',
  '/organization/waiting',
};

void main() {
  // Without this, `_pushedScreens` would be a hand-kept list and a sixth
  // out-of-shell route could ship as a dead end with every test still green —
  // exactly how #639 happened. This reads the router itself, so the next
  // out-of-shell route fails here until it is classified as a gate or given an
  // exit and swept below.
  testWidgets('the sweep covers every out-of-shell route', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    // Top-level `GoRoute`s only: `StatefulShellRoute` is a `ShellRouteBase`,
    // so the shell and everything nested inside it is excluded by the type
    // filter — what is left is precisely the routes declared outside it.
    final outOfShell = _routerOf(tester).configuration.routes
        .whereType<GoRoute>()
        .map((route) => route.path)
        .toSet();

    expect(
      outOfShell,
      _gateRoutes.union(_pushedScreens.map((s) => s.route).toSet()),
      reason:
          'a route declared outside StatefulShellRoute has neither bottom '
          'navigation nor the desktop rail, so it owes its own back control '
          '(#639, FR-UX-2). Add it to _pushedScreens with the key of that '
          'control — or to _gateRoutes if the router redirect pins the user '
          'to it and leaving is not on offer.',
    );
  });

  for (final screen in _pushedScreens) {
    group('${screen.route} — ${screen.description}', () {
      for (final chrome in _shellChrome) {
        testWidgets('is pushed outside the app shell, so it carries no '
            '${chrome.description}', (tester) async {
          if (chrome.viewport != null) {
            useViewport(tester, size: chrome.viewport!);
          }
          await tester.pumpWidget(_buildApp());
          await tester.pumpAndSettle();

          // Control, and the reason each half runs at its own viewport: the
          // shell swaps chrome at BrandDimens.breakpointExpanded (840), so at
          // the default 800x600 surface the rail is absent from IN-shell
          // routes too and "no rail here" would pass without proving
          // anything. Assert the affordance IS on the shell route first, so
          // the `findsNothing` below can only be the route's own doing.
          expect(
            find.byKey(chrome.key),
            findsOneWidget,
            reason:
                '/home is inside the shell, so at '
                '${chrome.viewport ?? 'the default surface'} it must render '
                '${chrome.description} — otherwise the assertion below is '
                'vacuous',
          );

          _routerOf(tester).go(screen.route);
          await tester.pumpAndSettle();

          // The premise of the whole file: if this is present the user
          // already had a way out, and the back-button assertions below would
          // be pinning something that does not matter.
          expect(
            find.byKey(chrome.key),
            findsNothing,
            reason:
                '${screen.route} is declared outside StatefulShellRoute, so '
                'it has no ${chrome.description} to leave by',
          );
        });
      }

      testWidgets('its own app bar carries a back control with an accessible '
          'name', (tester) async {
        await tester.pumpWidget(_buildApp());
        await tester.pumpAndSettle();

        _routerOf(tester).go(screen.route);
        await tester.pumpAndSettle();

        final finder = find.byKey(screen.backButton);
        expect(
          finder,
          findsOneWidget,
          reason:
              '${screen.description} has no shell chrome, so its own app bar '
              'must offer the way out (${screen.backButton})',
        );

        final button = tester.widget<IconButton>(finder);
        expect(
          button.tooltip,
          isNotNull,
          reason:
              'the back control on ${screen.description} must announce itself '
              'to a screen reader / on hover (FR-AX-1)',
        );
        expect(button.tooltip, isNotEmpty);
      });

      testWidgets('tapping that control leaves the route, landing on '
          '${screen.destination}', (tester) async {
        await tester.pumpWidget(_buildApp());
        await tester.pumpAndSettle();

        final router = _routerOf(tester);
        router.go(screen.route);
        await tester.pumpAndSettle();
        expect(_locationOf(router), screen.route);

        await tester.tap(find.byKey(screen.backButton));
        await tester.pumpAndSettle();

        expect(
          _locationOf(router),
          screen.destination,
          reason:
              'the back control on ${screen.description} must take the user '
              'to ${screen.destination} — the screen that links here. A '
              'control that leaves them on the same route is still a dead '
              'end, and one that lands somewhere unannounced is a different '
              'kind of lie.',
        );
      });
    });
  }
}
