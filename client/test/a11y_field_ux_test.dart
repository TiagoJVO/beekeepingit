// Systematic accessibility + field-first UX sweep (#79, #80, D-18) across the
// app's main flows: login, apiaries list/form, profile, organization,
// account, members, and the Home summary screen (#658, D-35).
// Generalizes the single tap-target check
// `apiaries_list_screen_test.dart` already had (the toggle segments) into a
// shared assertion (`test/support/a11y_matchers.dart`) applied consistently,
// plus semantics-label and keyboard-focus-order checks per the checklist:
// `docs/design/accessibility-field-ux-checklist.md`.
//
// One sweep file rather than scattering into each screen's own test file:
// these are cross-cutting checks (the same shape of assertion, repeated per
// screen) rather than screen-specific behavior, so they're easier to keep
// consistent and to extend for a new screen in one place.
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/core/widgets/field_action_button.dart';
import 'package:beekeepingit_client/features/account/account_screen.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_list_screen.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_form_screen.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_visit_recency.dart';
import 'package:beekeepingit_client/features/auth/login_screen.dart';
import 'package:beekeepingit_client/features/home/home_screen.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/members/members_screen.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_screen.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_screen.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/shell/sync_status.dart';
import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/a11y_matchers.dart';

class _FakeDeviceLocationService implements DeviceLocationService {
  const _FakeDeviceLocationService();
  @override
  Future<DeviceLocation> current() async => const DeviceLocationUnavailable();
}

class _CompleteProfileController extends ProfileController {
  @override
  Future<Profile> build() async => Profile(
    id: 'u1',
    name: 'Ana',
    email: 'ana@example.com',
    locale: 'en',
    profileComplete: true,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _IncompleteProfileController extends ProfileController {
  @override
  Future<Profile> build() async => Profile(
    id: 'u1',
    name: '',
    email: '',
    locale: 'en',
    profileComplete: false,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _ExistingOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => Organization(
    id: 'org-1',
    name: 'Test Apiary Co.',
    address: '',
    createdBy: 'u1',
    role: 'admin',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _EmptyOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => null;
}

class _EmptyMembersController extends MembersController {
  @override
  Future<MembersState> build() async =>
      const MembersState(members: [], invitations: []);
}

// `List<Object>` + `.cast()` below because Riverpod 3 no longer exports the
// `Override` type by name — `cast()`'s target is inferred from
// `ProviderScope.overrides`' own declared type.
Widget _withMaterial(Widget child, {List<Object> overrides = const []}) {
  return ProviderScope(
    overrides: overrides.cast(),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      home: child,
    ),
  );
}

void main() {
  group('tap targets (>= 44x44) — #80 AC "large tap targets"', () {
    testWidgets('login screen primary action', (tester) async {
      await tester.pumpWidget(_withMaterial(const LoginScreen()));
      await tester.pumpAndSettle();

      expectMinTapTarget(tester, find.byKey(const Key('login-button')));
    });

    // #363 (D-18): the federated action must be as gloves-friendly as the
    // primary one — same 56px SecondaryActionButton, not a bare text link.
    testWidgets('login screen federated action (Continue with Google)', (
      tester,
    ) async {
      await tester.pumpWidget(_withMaterial(const LoginScreen()));
      await tester.pumpAndSettle();

      expectMinTapTarget(tester, find.byKey(const Key('login-google-button')));
    });

    testWidgets('apiaries list view-toggle segments', (tester) async {
      final router = GoRouter(
        initialLocation: '/apiaries',
        routes: [
          GoRoute(
            path: '/apiaries',
            builder: (context, state) =>
                const Scaffold(body: ApiariesListScreen()),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiariesStreamProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
            deviceLocationServiceProvider.overrideWithValue(
              const _FakeDeviceLocationService(),
            ),
          ],
          child: MaterialApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: kSupportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expectMinTapTarget(
        tester,
        find.byKey(const Key('apiaries-view-list-button')),
      );
      expectMinTapTarget(
        tester,
        find.byKey(const Key('apiaries-view-map-button')),
      );
    });

    testWidgets('apiary form save button (create mode)', (tester) async {
      // The form screen relies on the app shell's Scaffold for its Material
      // ancestor — supply one here like the shell does.
      await tester.pumpWidget(
        _withMaterial(const Scaffold(body: ApiaryFormScreen())),
      );
      await tester.pumpAndSettle();

      expectMinTapTarget(tester, find.byKey(const Key('apiary-save-button')));
    });

    testWidgets('profile screen save button', (tester) async {
      await tester.pumpWidget(
        _withMaterial(
          const ProfileScreen(),
          overrides: [
            profileProvider.overrideWith(_IncompleteProfileController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expectMinTapTarget(tester, find.byKey(const Key('profile-save-button')));
    });

    testWidgets('organization screen save button', (tester) async {
      await tester.pumpWidget(
        _withMaterial(
          const OrganizationScreen(),
          overrides: [
            organizationProvider.overrideWith(_EmptyOrganizationController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expectMinTapTarget(
        tester,
        find.byKey(const Key('organization-save-button')),
      );
    });

    testWidgets('account screen actions', (tester) async {
      await tester.pumpWidget(
        _withMaterial(
          const AccountScreen(),
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            profileProvider.overrideWith(_CompleteProfileController.new),
            organizationProvider.overrideWith(
              _ExistingOrganizationController.new,
            ),
            syncStatusProvider.overrideWithValue(
              const SyncStatus(
                connectivity: SyncConnectivity.online,
                pendingCount: 0,
              ),
            ),
            syncNowProvider.overrideWithValue(() async {}),
          ],
        ),
      );
      await tester.pumpAndSettle();

      for (final key in [
        'account-save-button',
        'account-change-password-button',
        'account-manage-members-button',
        'account-logout-button',
      ]) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        expectMinTapTarget(tester, find.byKey(Key(key)));
      }
    });

    testWidgets('members invite button (not full-width, still >= 44x44)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _withMaterial(
          const MembersScreen(),
          overrides: [
            membersProvider.overrideWith(_EmptyMembersController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expectMinTapTarget(tester, find.byKey(const Key('invite-submit-button')));
    });
  });

  group(
    'semantics labels — #79 AC "screens expose proper semantics/labels"',
    () {
      testWidgets('login button announces its action', (tester) async {
        await tester.pumpWidget(_withMaterial(const LoginScreen()));
        await tester.pumpAndSettle();

        expectHasSemanticsLabel(tester, const Key('login-button'));
      });

      testWidgets('federated login button announces its action (#363)', (
        tester,
      ) async {
        await tester.pumpWidget(_withMaterial(const LoginScreen()));
        await tester.pumpAndSettle();

        expectHasSemanticsLabel(tester, const Key('login-google-button'));
      });

      testWidgets('apiaries view toggle segments announce list/map', (
        tester,
      ) async {
        final router = GoRouter(
          initialLocation: '/apiaries',
          routes: [
            GoRoute(
              path: '/apiaries',
              builder: (context, state) =>
                  const Scaffold(body: ApiariesListScreen()),
            ),
          ],
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiariesStreamProvider.overrideWith(
                (ref) => Stream.value(const []),
              ),
              deviceLocationServiceProvider.overrideWithValue(
                const _FakeDeviceLocationService(),
              ),
            ],
            child: MaterialApp.router(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: kSupportedLocales,
              routerConfig: router,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expectHasSemanticsLabel(tester, const Key('apiaries-view-list-button'));
        expectHasSemanticsLabel(tester, const Key('apiaries-view-map-button'));
      });

      testWidgets('account screen logout announces as a button', (
        tester,
      ) async {
        await tester.pumpWidget(
          _withMaterial(
            const AccountScreen(),
            overrides: [
              isAuthenticatedProvider.overrideWithValue(true),
              profileProvider.overrideWith(_CompleteProfileController.new),
              organizationProvider.overrideWith(
                _ExistingOrganizationController.new,
              ),
              syncStatusProvider.overrideWithValue(
                const SyncStatus(
                  connectivity: SyncConnectivity.online,
                  pendingCount: 0,
                ),
              ),
              syncNowProvider.overrideWithValue(() async {}),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('account-logout-button')),
        );
        await tester.pumpAndSettle();
        expectHasSemanticsLabel(tester, const Key('account-logout-button'));
      });
    },
  );

  group('keyboard focus order — #79 AC "reachable and operable by keyboard '
      'with ... a logical focus order"', () {
    // FocusManager.instance.primaryFocus is the FocusNode that actually owns
    // keyboard input right now. Checking whether *that* node's context sits
    // inside the keyed widget's own subtree (rather than asking the keyed
    // element itself, via Focus.of, which walks *up* the tree and would
    // report an ancestor FocusScope instead of a descendant control's own
    // node) is the precise way to assert "this exact field/button is the one
    // currently focused" for both TextFormFields and the FilledButton/
    // OutlinedButton wrapped inside PrimaryActionButton/SecondaryActionButton.
    bool fieldHasFocus(WidgetTester tester, Key key) {
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext == null) return false;
      final target = find.byKey(key).evaluate().single;
      if (focusedContext == target) return true;
      var found = false;
      focusedContext.visitAncestorElements((ancestor) {
        if (ancestor == target) {
          found = true;
          return false;
        }
        return true;
      });
      return found;
    }

    testWidgets('organization form: name field is focused first, address '
        'next, then save', (tester) async {
      await tester.pumpWidget(
        _withMaterial(
          const OrganizationScreen(),
          overrides: [
            organizationProvider.overrideWith(_EmptyOrganizationController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // The name field has autofocus: true (organization_screen.dart) — it's
      // the logical first stop for a keyboard/screen-reader user landing on
      // this onboarding-gate screen.
      expect(
        fieldHasFocus(tester, const Key('organization-name-field')),
        isTrue,
      );

      // Tab moves focus forward in visual order: name -> address -> save.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        fieldHasFocus(tester, const Key('organization-address-field')),
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        fieldHasFocus(tester, const Key('organization-save-button')),
        isTrue,
      );
    });
  });

  // -------------------------------------------------------------------------
  // Home summary screen (#658, D-35) — the app's landing screen, swept here
  // for the first time. Home renders one of three states, so each check below
  // names the state it covers; the fixtures come from `_pumpHome`'s named
  // helpers so a state can't drift between checks.
  // -------------------------------------------------------------------------
  group('Home summary screen (#658, D-35)', () {
    testWidgets('needs-attention: every row and view-all link is >= 44x44', (
      tester,
    ) async {
      await _pumpHomeNeedsAttention(tester);

      for (final key in _homeInteractiveKeys) {
        expectMinTapTarget(tester, find.byKey(key));
      }
    });

    testWidgets(
      'needs-attention: every row and view-all link announces a label',
      (tester) async {
        await _pumpHomeNeedsAttention(tester);

        for (final key in _homeInteractiveKeys) {
          expectHasSemanticsLabel(tester, key);
        }
      },
    );

    // The badges are the ONLY signal separating an overdue row from a
    // due-soon one, and a never-visited apiary from a stale one. If that
    // information reaches sighted users only, the row is a different row for
    // a screen-reader user than it is for everyone else.
    testWidgets(
      'needs-attention: a row announces its badge, not just its title and '
      'subtitle',
      (tester) async {
        await _pumpHomeNeedsAttention(tester);

        expect(
          _semanticsLabel(tester, const Key('home-todo-late')),
          allOf(contains('Late task'), contains('5 days overdue')),
        );
        expect(
          _semanticsLabel(tester, const Key('home-todo-soon')),
          allOf(contains('Task due today'), contains('Due soon')),
        );
        expect(
          _semanticsLabel(tester, const Key('home-apiary-never')),
          allOf(contains('Never seen'), contains('No activity recorded yet')),
        );
        expect(
          _semanticsLabel(tester, const Key('home-apiary-stale')),
          allOf(
            contains('Stale yard'),
            contains('40 days since the last visit'),
          ),
        );

        // Guards the four assertions above against passing for the wrong
        // reason: `getSemantics` walks UP to the nearest node, so a row whose
        // badge produced no label of its own would still "contain" the badge
        // text if the node returned were an ancestor covering the whole
        // screen. Each row must be its own node, announcing only itself.
        expect(
          _semanticsLabel(tester, const Key('home-todo-late')),
          isNot(anyOf(contains('Stale yard'), contains('Task due today'))),
        );
      },
    );

    // FR-UX-1's "forgiving spacing": a slightly-off tap must not land on the
    // neighbouring row — or, at the bottom of a section, on the view-all link
    // that navigates away from Home entirely.
    testWidgets('needs-attention: adjacent tap targets are >= 8px apart', (
      tester,
    ) async {
      await _pumpHomeNeedsAttention(tester);

      _expectTapTargetGaps(tester, _homeInteractiveKeys);
    });

    testWidgets(
      'first run: the single action is the 56px PrimaryActionButton',
      (tester) async {
        await _pumpHome(tester);

        const key = Key('home-first-run-action');
        expect(find.byKey(key), findsOneWidget);
        expect(tester.widget(find.byKey(key)), isA<PrimaryActionButton>());
        expectMinTapTarget(tester, find.byKey(key));
        expect(
          tester.getSize(find.byKey(key)).height,
          greaterThanOrEqualTo(kFieldActionButtonHeight),
        );
        expectHasSemanticsLabel(tester, key);
      },
    );

    // 375x667 is the narrowest phone this app targets (kHomePreviewLimit's own
    // doc), and 1.3x-2.0x is the checklist's text-scale band. The count badges
    // and the plural strings are the clipping candidates.
    for (final scale in <double>[1.0, 1.3, 2.0]) {
      testWidgets(
        'needs-attention: no overflow at 375x667 @ ${scale}x text scale',
        (tester) async {
          await _pumpHomeNeedsAttention(tester, textScale: scale);

          expect(find.byKey(const Key('home-tasks-section')), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('first run: no overflow at 375x667 @ ${scale}x text scale', (
        tester,
      ) async {
        await _pumpHome(tester, textScale: scale);

        expect(find.byKey(const Key('home-first-run')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('all clear: no overflow at 375x667 @ ${scale}x text scale', (
        tester,
      ) async {
        await _pumpHome(
          tester,
          textScale: scale,
          // Data exists, but nothing matches a section: one done todo.
          todos: [_homeTodo('done', title: 'Finished', status: 'done')],
        );

        expect(find.byKey(const Key('home-all-clear')), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('needs-attention: Tab walks the sections top to bottom', (
      tester,
    ) async {
      // One row per section, and a viewport tall enough to hold all of them:
      // focus traversal auto-scrolls to reveal the focused widget, which would
      // move every other row's offset mid-assertion on a scrolling screen.
      await _pumpHomeNeedsAttention(
        tester,
        size: const Size(375, 1400),
        singleRowPerSection: true,
      );

      final keys = <Key>[
        const Key('home-todo-late'),
        const Key('home-tasks-view-all'),
        const Key('home-journey-open'),
        const Key('home-journeys-view-all'),
        const Key('home-apiary-never'),
      ];
      final tops = <double>[];
      for (var i = 0; i < keys.length; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final focused = FocusManager.instance.primaryFocus?.context;
        expect(focused, isNotNull, reason: 'nothing focused after Tab #$i');
        final box = focused!.findRenderObject()! as RenderBox;
        tops.add(box.localToGlobal(Offset.zero).dy);
      }

      for (var i = 1; i < tops.length; i++) {
        expect(
          tops[i],
          greaterThan(tops[i - 1]),
          reason:
              'focus stop #$i (${keys[i]}) sits at ${tops[i]}, above the '
              'previous stop at ${tops[i - 1]} — focus order is not '
              'top-to-bottom',
        );
      }
    });

    // FR-UX-2: the persistent app shell is the only navigation chrome. A tab
    // root that grows its own AppBar/FAB/bottom bar gives the app two.
    testWidgets('adds no navigation chrome of its own', (tester) async {
      await _pumpHomeNeedsAttention(tester);

      for (final chrome in <Finder>[
        find.byType(Scaffold),
        find.byType(AppBar),
        find.byType(SliverAppBar),
        find.byType(BottomNavigationBar),
        find.byType(NavigationBar),
        find.byType(TabBar),
        find.byType(FloatingActionButton),
        find.byType(Drawer),
      ]) {
        expect(
          find.descendant(
            of: find.byKey(const Key('home-screen')),
            matching: chrome,
          ),
          findsNothing,
          reason: 'Home must not supply its own navigation chrome',
        );
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Home fixtures + helpers (#658, D-35).
// ---------------------------------------------------------------------------

/// Every interactive element the needs-attention state renders, in layout
/// order. The stale-apiaries section deliberately has no view-all link
/// (home_screen.dart's `_StaleApiariesSection`).
const _homeInteractiveKeys = <Key>[
  Key('home-todo-late'),
  Key('home-todo-soon'),
  Key('home-tasks-view-all'),
  Key('home-journey-open'),
  Key('home-journeys-view-all'),
  Key('home-apiary-never'),
  Key('home-apiary-stale'),
];

String _homeIsoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime _homeDaysAgo(int days) =>
    DateTime.now().subtract(Duration(days: days));

Todo _homeTodo(
  String id, {
  required String title,
  String priority = todoPriorityMedium,
  String status = 'open',
  String? dueDate,
}) => Todo(
  id: id,
  title: title,
  priority: priority,
  status: status,
  dueDate: dueDate,
  organizationId: 'org-1',
);

/// The label a screen reader would announce for the widget keyed [key].
String _semanticsLabel(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  expect(finder, findsOneWidget, reason: '_semanticsLabel: key $key not found');
  return tester.getSemantics(finder).label;
}

/// Asserts every consecutive pair of the tap targets keyed by [keys], ordered
/// top to bottom, is at least [minGap] apart vertically (FR-UX-1's
/// "forgiving spacing").
void _expectTapTargetGaps(
  WidgetTester tester,
  List<Key> keys, {
  double minGap = 8,
}) {
  final rects = [for (final key in keys) (key, tester.getRect(find.byKey(key)))]
    ..sort((a, b) => a.$2.top.compareTo(b.$2.top));
  for (var i = 1; i < rects.length; i++) {
    final gap = rects[i].$2.top - rects[i - 1].$2.bottom;
    expect(
      gap,
      greaterThanOrEqualTo(minGap),
      reason:
          'only ${gap}px between ${rects[i - 1].$1} and ${rects[i].$1}, '
          'expected >= ${minGap}px',
    );
  }
}

/// Pumps [HomeScreen] alone inside a router — the shell supplies the header
/// and bottom nav in the real app, and pumping the shell here would put that
/// chrome inside the very subtree the "no chrome of its own" check inspects.
Future<void> _pumpHome(
  WidgetTester tester, {
  List<Todo> todos = const [],
  List<Journey> journeys = const [],
  List<Apiary> apiaries = const [],
  List<Activity> activities = const [],
  double textScale = 1.0,
  Size size = const Size(375, 667),
}) async {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(body: HomeScreen()),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        todosStreamProvider.overrideWith((ref) => Stream.value(todos)),
        journeysStreamProvider.overrideWith((ref) => Stream.value(journeys)),
        apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
        activitiesStreamProvider.overrideWith(
          (ref) => Stream.value(activities),
        ),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The needs-attention state with all three sections populated: an overdue
/// todo and a due-soon one, an open journey, a never-visited apiary and a
/// stale one — one fixture per badge variant Home can render.
Future<void> _pumpHomeNeedsAttention(
  WidgetTester tester, {
  double textScale = 1.0,
  Size size = const Size(375, 667),
  bool singleRowPerSection = false,
}) {
  const staleApiary = Apiary(id: 'stale', name: 'Stale yard', hiveCount: 4);
  return _pumpHome(
    tester,
    textScale: textScale,
    size: size,
    todos: [
      _homeTodo(
        'late',
        title: 'Late task',
        dueDate: _homeIsoDate(_homeDaysAgo(5)),
      ),
      if (!singleRowPerSection)
        _homeTodo(
          'soon',
          title: 'Task due today',
          priority: todoPriorityHigh,
          dueDate: _homeIsoDate(DateTime.now()),
        ),
    ],
    journeys: [
      const Journey(
        id: 'open',
        name: 'Spring inspection round',
        mainActivityType: 'inspection',
        status: journeyStatusOpen,
        organizationId: 'org-1',
      ),
    ],
    apiaries: [
      const Apiary(id: 'never', name: 'Never seen', hiveCount: 2),
      if (!singleRowPerSection) staleApiary,
    ],
    activities: [
      if (!singleRowPerSection)
        Activity(
          id: 'act-1',
          apiaryId: staleApiary.id,
          type: 'inspection',
          occurredAt: _homeIsoDate(_homeDaysAgo(apiaryVisitRecencyDays + 10)),
          attributes: const {},
          organizationId: 'org-1',
        ),
    ],
  );
}
