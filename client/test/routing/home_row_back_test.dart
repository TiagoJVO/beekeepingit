import 'dart:async';

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todo_detail_screen.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/routing/branch_local_navigation.dart';
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

const _journey = Journey(
  id: 'j1',
  name: 'Spring round',
  mainActivityType: 'inspection',
  status: journeyStatusOpen,
  organizationId: 'test-org',
);

const _apiary = Apiary(id: 'a1', name: 'Quinta velha', hiveCount: 3);

/// A todo the test can change under the app.
///
/// Every subscription replays the current value before following further
/// changes, the way a local-store query does — a plain broadcast controller
/// would silently hand a re-created provider an empty stream, and the page
/// under test would sit on its loading state instead of seeing the record
/// vanish.
class _MutableTodo {
  Todo? value = _todo;
  final _changes = StreamController<Todo?>.broadcast();

  Stream<Todo?> stream() async* {
    yield value;
    yield* _changes.stream;
  }

  void set(Todo? next) {
    value = next;
    _changes.add(next);
  }

  Future<void> dispose() => _changes.close();
}

Widget _buildApp({
  Stream<Todo?> Function(String id)? todoById,
}) => ProviderScope(
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
      (ref, id) =>
          todoById?.call(id) ?? Stream.value(id == _todo.id ? _todo : null),
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
final int _todosTab = AppShell.tabs.indexWhere((tab) => tab.route == 'todos');

/// One Home row, and the location its tap must open **inside Home's own
/// branch** — not the entity's own tab.
/// [title] is the shell header the record must carry: Home's copies render
/// the same screens as the owning routes, so they owe the same titles — a
/// header still reading "Home" over an apiary is the lie #638 fixed for the
/// not-found screen, and nothing else would catch it.
typedef _HomeRow = ({Key row, String detail, String title, String description});

const _homeRows = <_HomeRow>[
  (
    row: Key('home-todo-t1'),
    detail: '/home/todos/t1',
    title: 'Todo',
    description: 'a task row',
  ),
  (
    row: Key('home-journey-j1'),
    detail: '/home/journeys/j1',
    title: 'Journey',
    description: 'a journey row',
  ),
  (
    row: Key('home-apiary-a1'),
    detail: '/home/apiaries/a1',
    title: 'Apiary',
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
  // #666 review (MEDIUM): StatefulShellRoute.indexedStack keeps every branch
  // MOUNTED, merely off-stage, so Home's copy of a record outlives the visit
  // that opened it. A screen that navigates on its OWN initiative — the
  // null-record bounce every detail screen has — must therefore be able to
  // tell "I am the page the user is looking at" from "I am a page parked in
  // another tab", or a record deleted elsewhere (or deleted over sync) would
  // fire that bounce from off-stage and drag the whole app to Home.
  //
  // What this pins is `isLiveLocation`, the predicate the guard is written
  // in, evaluated on the real off-stage page inside the real shell — not the
  // bounce itself: the widget binding does not deliver that rebuild the way
  // a running app does, so an assertion on the router alone would pass with
  // the guard removed and pin nothing.
  testWidgets('Home\'s copy of a record knows when it is not the page the '
      'user is looking at', (tester) async {
    final todo = _MutableTodo();
    addTearDown(todo.dispose);

    useViewport(tester, size: _tallPhone);
    await tester.pumpWidget(_buildApp(todoById: (id) => todo.stream()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shell-tab-home')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('home-todo-t1')));
    await _pumpBounded(tester);
    expect(_location(tester), '/home/todos/t1');

    final onScreen = tester.element(find.byType(TodoDetailScreen));
    expect(
      isLiveLocation(onScreen),
      isTrue,
      reason:
          'the page the user is looking at is the live location — if this '
          'were false the guard would suppress a bounce that should happen',
    );

    // The user moves on to the Todos tab; Home's copy of the task stays
    // mounted off-stage behind it, and the task is then deleted (there, or
    // over sync).
    await tester.tap(find.byKey(const Key('shell-tab-todos')));
    await tester.pumpAndSettle();
    expect(_location(tester), '/todos');
    expect(_selectedTab(tester), _todosTab);
    todo.set(null);
    await _pumpBounded(tester);

    final offStage = find.byType(TodoDetailScreen, skipOffstage: false);
    expect(
      offStage,
      findsOneWidget,
      reason:
          'the premise: StatefulShellRoute.indexedStack keeps inactive '
          'branches MOUNTED. If Home\'s copy were gone it could not navigate, '
          'and the assertion below would pin nothing',
    );
    expect(
      isLiveLocation(tester.element(offStage)),
      isFalse,
      reason:
          'Home\'s parked copy of the deleted task must know it is not the '
          'live page, so its null-bounce stays put instead of dragging the '
          'user out of the Todos tab',
    );
    expect(_location(tester), '/todos');
  });

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
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.text(row.title),
          ),
          findsOneWidget,
          reason:
              'the shell header names the record, not the tab it is filed '
              'under — Home\'s copy renders the same screen, so it owes the '
              'same title',
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
