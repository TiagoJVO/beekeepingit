import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/a11y_matchers.dart' show useViewport;

/// #666 (FR-UX-1, FR-UX-2, D-35) — **Back from a Home row returns to Home.**
///
/// Home is the landing screen and the post-login redirect target (D-35), so
/// every row it renders is a navigation the user makes from the app's front
/// door. Routing those rows straight into the Todos / Journeys / Apiaries
/// branches switched the shell's branch under them: the tab changed, and the
/// shell's Back then popped within the NEW branch, landing on that tab's list
/// with Home nowhere in sight.
///
/// The three cases below are one table rather than three hand-written tests
/// because the defect is a property of the pattern, not of any one section —
/// a fourth summary section added later belongs in the table, not in a fourth
/// copy of the same assertions.
///
/// Each case pins BOTH halves of the contract at BOTH steps: where the router
/// actually is, and which bottom-nav destination is selected — a fix that
/// returned to Home while leaving the Todos tab highlighted would be the same
/// lie in the other direction.

class _CompleteProfileController extends ProfileController {
  @override
  Future<Profile> build() async => Profile(
    id: 'test-user',
    name: 'Test User',
    email: 'test@example.com',
    locale: 'en',
    profileComplete: true,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _ExistingOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => Organization(
    id: 'test-org',
    name: 'Test Apiary Co.',
    address: '',
    createdBy: 'test-user',
    role: 'admin',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// An overdue task, an open journey and an apiary nobody has visited: one
/// fixture set that lights up all three D-35 attention sections at once, so
/// every case below starts from the same Home screen the user sees.
final _todo = Todo(
  id: 't1',
  title: 'Late task',
  priority: todoPriorityMedium,
  status: 'open',
  dueDate: _isoDate(DateTime.now().subtract(const Duration(days: 4))),
  organizationId: 'test-org',
);

final _journey = Journey(
  id: 'j1',
  name: 'Spring round',
  mainActivityType: 'inspection',
  status: journeyStatusOpen,
  organizationId: 'test-org',
);

const _apiary = Apiary(id: 'a1', name: 'Quinta velha', hiveCount: 3);

Widget _buildApp() => ProviderScope(
  overrides: [
    isAuthenticatedProvider.overrideWithValue(true),
    profileProvider.overrideWith(_CompleteProfileController.new),
    organizationProvider.overrideWith(_ExistingOrganizationController.new),
    todosStreamProvider.overrideWith((ref) => Stream.value([_todo])),
    journeysStreamProvider.overrideWith((ref) => Stream.value([_journey])),
    apiariesStreamProvider.overrideWith((ref) => Stream.value(const [_apiary])),
    activitiesStreamProvider.overrideWith(
      (ref) => Stream.value(const <Activity>[]),
    ),
    // The tap-through targets, served off the same fixtures: every detail
    // screen bounces back to its own list when its record resolves to null,
    // which would erase the very navigation this file asserts on.
    todoByIdProvider.overrideWith(
      (ref, id) => Stream.value(id == _todo.id ? _todo : null),
    ),
    journeyByIdProvider.overrideWith(
      (ref, id) => Stream.value(id == _journey.id ? _journey : null),
    ),
    apiaryByIdProvider.overrideWith(
      (ref, id) => Stream.value(id == _apiary.id ? _apiary : null),
    ),
    memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
  ],
  child: const BeekeepingitApp(),
);

/// Pumps a bounded number of frames instead of settling — the detail routes
/// Home taps into read from stubbed streams and never finish painting their
/// embedded sections; nothing here depends on them having done so, only on
/// the router having moved.
Future<void> _pumpBounded(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String _location(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(AppShell)))
        .routeInformationProvider
        .value
        .uri
        .toString();

int _selectedTab(WidgetTester tester) => tester
    .widget<NavigationBar>(find.byKey(const Key('shell-bottom-nav')))
    .selectedIndex;

final int _homeTab = AppShell.tabs.indexWhere((tab) => tab.route == 'home');

/// One Home row, and the location its tap must open **inside Home's own
/// branch** — not the entity's own tab.
typedef _HomeRow = ({Key row, String detail, String description});

const _homeRows = <_HomeRow>[
  (
    row: Key('home-todo-t1'),
    detail: '/home/todos/t1',
    description: 'a task row',
  ),
  (
    row: Key('home-journey-j1'),
    detail: '/home/journeys/j1',
    description: 'a journey row',
  ),
  (
    row: Key('home-apiary-a1'),
    detail: '/home/apiaries/a1',
    description: 'an apiary row',
  ),
];

/// A phone-width surface tall enough for all three attention sections at
/// once: the fixtures light up every section, and on the default 800x600
/// test surface the apiaries section lands under the bottom navigation, where
/// a tap hits the chrome instead of the row.
const _tallPhone = Size(400, 1200);

Future<void> _openHome(WidgetTester tester) async {
  useViewport(tester, size: _tallPhone);
  await tester.pumpWidget(_buildApp());
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('shell-tab-home')));
  await tester.pumpAndSettle();
  expect(_location(tester), '/home');
  expect(_selectedTab(tester), _homeTab);
}

void main() {
  for (final row in _homeRows) {
    group('${row.description} on Home', () {
      testWidgets('opens the record inside the Home branch, keeping Home the '
          'selected tab', (tester) async {
        await _openHome(tester);

        await tester.tap(find.byKey(row.row));
        await _pumpBounded(tester);

        expect(
          _location(tester),
          row.detail,
          reason:
              'a row on the landing screen must open the record in HOME\'s '
              'own stack (#666). Routing into the entity\'s own branch '
              'switches the tab under the user and takes Home out of the '
              'stack Back pops.',
        );
        expect(
          _selectedTab(tester),
          _homeTab,
          reason:
              'the user tapped a row on Home and has gone nowhere else, so '
              'the bottom nav must still say Home (FR-UX-2)',
        );
      });

      testWidgets('Back from that record returns to Home', (tester) async {
        await _openHome(tester);

        await tester.tap(find.byKey(row.row));
        await _pumpBounded(tester);

        final back = find.byKey(const Key('shell-back-button'));
        expect(
          back,
          findsOneWidget,
          reason:
              'the record opened from Home is a pushed page, so the shell '
              'owes it a Back control',
        );
        await tester.tap(back);
        await _pumpBounded(tester);

        expect(
          _location(tester),
          '/home',
          reason:
              'Back from a record opened on Home returns to Home — not to '
              'the entity tab\'s list, which is where the user never was '
              '(#666, FR-UX-1)',
        );
        expect(
          _selectedTab(tester),
          _homeTab,
          reason: 'and the bottom nav says so too (FR-UX-2)',
        );
        expect(find.byKey(const Key('home-screen')), findsOneWidget);
      });
    });
  }
}
