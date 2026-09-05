import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_visit_recency.dart';
import 'package:beekeepingit_client/features/home/home_providers.dart';
import 'package:beekeepingit_client/features/home/home_summary.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Widget-level cover for the Home summary screen (#658, D-35): the three
/// sections it renders, the first-run and all-clear states that replace them,
/// and the tap-throughs out of it.
///
/// Harnessed exactly like todos_list_screen_test.dart — the whole
/// [BeekeepingitApp] inside a [ProviderScope] with auth/profile/organization
/// and the four org-scoped streams overridden — because Home is a tab root
/// inside the app shell, so pumping the screen bare would exercise a widget
/// arrangement that never exists in the app.

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

final _today = DateTime.now();

DateTime _daysAgo(int days) => _today.subtract(Duration(days: days));

Todo _todo(
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
  organizationId: 'test-org',
);

Journey _journey(
  String id, {
  required String name,
  String status = journeyStatusOpen,
}) => Journey(
  id: id,
  name: name,
  mainActivityType: 'inspection',
  status: status,
  organizationId: 'test-org',
);

Apiary _apiary(String id, {required String name}) =>
    Apiary(id: id, name: name, hiveCount: 3);

Activity _activity(
  String id, {
  required String apiaryId,
  required int daysAgo,
}) => Activity(
  id: id,
  apiaryId: apiaryId,
  type: 'inspection',
  occurredAt: _isoDate(_daysAgo(daysAgo)),
  attributes: const {},
  organizationId: 'test-org',
);

/// The fixture in [items] whose [idOf] matches [id], or null.
T? _byId<T>(List<T> items, String id, String Function(T) idOf) {
  for (final item in items) {
    if (idOf(item) == id) return item;
  }
  return null;
}

Widget _buildApp({
  List<Todo> todos = const [],
  List<Journey> journeys = const [],
  List<Apiary> apiaries = const [],
  List<Activity> activities = const [],
  Stream<List<Todo>>? todosStream,
  Stream<List<Journey>>? journeysStream,
  Stream<List<Apiary>>? apiariesStream,
  Stream<List<Activity>>? activitiesStream,
  HomeSummary? summary,
}) {
  return ProviderScope(
    overrides: [
      // Only ever set by the pinned-clock guard below: it replaces the live
      // summary wholesale so `now` is a fixture value rather than the real
      // clock. Left null everywhere else, so every other test still
      // exercises the real provider composing the four streams.
      if (summary != null) homeSummaryProvider.overrideWith((ref) => summary),
      isAuthenticatedProvider.overrideWithValue(true),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      todosStreamProvider.overrideWith(
        (ref) => todosStream ?? Stream.value(todos),
      ),
      journeysStreamProvider.overrideWith(
        (ref) => journeysStream ?? Stream.value(journeys),
      ),
      apiariesStreamProvider.overrideWith(
        (ref) => apiariesStream ?? Stream.value(apiaries),
      ),
      activitiesStreamProvider.overrideWith(
        (ref) => activitiesStream ?? Stream.value(activities),
      ),
      // The tap-through targets, served off the same fixtures rather than
      // left to reach for a PowerSync database this test has none of. They
      // must resolve to the REAL record: every detail screen bounces back to
      // its list when its record is null, which would erase the very
      // navigation these tests assert on.
      todoByIdProvider.overrideWith(
        (ref, id) => Stream.value(_byId(todos, id, (t) => t.id)),
      ),
      journeyByIdProvider.overrideWith(
        (ref, id) => Stream.value(_byId(journeys, id, (j) => j.id)),
      ),
      apiaryByIdProvider.overrideWith(
        (ref, id) => Stream.value(_byId(apiaries, id, (a) => a.id)),
      ),
      memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openHome(
  WidgetTester tester, {
  List<Todo> todos = const [],
  List<Journey> journeys = const [],
  List<Apiary> apiaries = const [],
  List<Activity> activities = const [],
  Stream<List<Todo>>? todosStream,
  Stream<List<Journey>>? journeysStream,
  Stream<List<Apiary>>? apiariesStream,
  Stream<List<Activity>>? activitiesStream,
  HomeSummary? summary,
}) async {
  await tester.pumpWidget(
    _buildApp(
      todos: todos,
      journeys: journeys,
      apiaries: apiaries,
      activities: activities,
      todosStream: todosStream,
      journeysStream: journeysStream,
      apiariesStream: apiariesStream,
      activitiesStream: activitiesStream,
      summary: summary,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('shell-tab-home')));
  await tester.pumpAndSettle();
}

/// Pumps a bounded number of frames instead of settling — the detail routes
/// Home taps into are stubbed, and nothing here depends on them having
/// finished painting, only on the router having moved.
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

/// Every row title inside [section], in the order the section lays them out.
///
/// Branded row cards ([BrandRowCard]) are not `ListTile`s, so render order is
/// read off each title's vertical offset — copied from
/// todos_list_screen_test.dart's own `_rowTitlesInOrder` for the same reason.
List<String> _rowTitlesInOrder(WidgetTester tester, Key section) {
  final titles = <(double, String)>[];
  for (final element
      in find
          .descendant(of: find.byKey(section), matching: find.byType(Text))
          .evaluate()) {
    final widget = element.widget as Text;
    final text = widget.data;
    if (text == null) continue;
    // Row titles are bold (w700); headers, subtitles and badges are not.
    if (widget.style?.fontWeight != FontWeight.w700) continue;
    titles.add((tester.getTopLeft(find.byWidget(widget)).dy, text));
  }
  titles.sort((a, b) => a.$1.compareTo(b.$1));
  return titles.map((e) => e.$2).toList();
}

void main() {
  group('Home summary — tasks needing attention (#658, D-35, FR-TD-1)', () {
    testWidgets('counts the full set while rendering only the preview', (
      tester,
    ) async {
      await _openHome(
        tester,
        todos: [
          for (var i = 1; i <= 5; i++)
            _todo(
              't$i',
              title: 'Late task $i',
              dueDate: _isoDate(_daysAgo(10 + i)),
            ),
        ],
      );

      expect(find.byKey(const Key('home-tasks-section')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('home-tasks-count')),
          matching: find.text('5'),
        ),
        findsOneWidget,
      );
      expect(
        _rowTitlesInOrder(tester, const Key('home-tasks-section')).length,
        3,
      );
      // All five fixtures are overdue, so the link's own count matches the
      // section's here — the two diverge only when due-soon rows are mixed
      // in, which the "#661" group below pins.
      expect(find.text('View all 5 overdue tasks'), findsOneWidget);
    });

    testWidgets('renders overdue rows before due-soon rows, each badged from '
        'the bucket the summary already decided', (tester) async {
      await _openHome(
        tester,
        todos: [
          _todo(
            'soon',
            title: 'Due today',
            priority: todoPriorityHigh,
            dueDate: _isoDate(_today),
          ),
          _todo('late-2', title: 'Late two', dueDate: _isoDate(_daysAgo(2))),
          _todo('late-9', title: 'Late nine', dueDate: _isoDate(_daysAgo(9))),
        ],
      );

      expect(_rowTitlesInOrder(tester, const Key('home-tasks-section')), [
        'Late nine',
        'Late two',
        'Due today',
      ]);
      expect(
        find.descendant(
          of: find.byKey(const Key('home-todo-badge-late-9')),
          matching: find.text('9 d late'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('home-todo-badge-soon')),
          matching: find.text('Soon'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an overdue badge pairs its text with an icon, never colour '
        'alone (WCAG 2.2 AA 1.4.1)', (tester) async {
      await _openHome(
        tester,
        todos: [
          _todo('late', title: 'Late one', dueDate: _isoDate(_daysAgo(3))),
        ],
      );

      expect(
        find.descendant(
          of: find.byKey(const Key('home-todo-badge-late')),
          matching: find.byType(Icon),
        ),
        findsOneWidget,
      );
    });

    testWidgets('tapping a task row opens that todo', (tester) async {
      await _openHome(
        tester,
        todos: [
          _todo('t1', title: 'Late task', dueDate: _isoDate(_daysAgo(4))),
        ],
      );

      await tester.tap(find.byKey(const Key('home-todo-t1')));
      await _pumpBounded(tester);

      expect(_location(tester), '/todos/t1');
    });

    testWidgets('the section is absent when nothing is overdue or due soon', (
      tester,
    ) async {
      await _openHome(
        tester,
        apiaries: [_apiary('a1', name: 'Fresh apiary')],
        activities: [_activity('x1', apiaryId: 'a1', daysAgo: 1)],
        todos: [
          _todo(
            'far',
            title: 'Far away',
            dueDate: _isoDate(_today.add(const Duration(days: 60))),
          ),
        ],
      );

      expect(find.byKey(const Key('home-tasks-section')), findsNothing);
    });
  });

  group('Home summary — journeys in progress (#658, D-35, FR-JO-1)', () {
    testWidgets('counts every open journey while previewing three', (
      tester,
    ) async {
      await _openHome(
        tester,
        journeys: [
          for (var i = 1; i <= 4; i++) _journey('j$i', name: 'Journey $i'),
        ],
      );

      expect(
        find.descendant(
          of: find.byKey(const Key('home-journeys-count')),
          matching: find.text('4'),
        ),
        findsOneWidget,
      );
      expect(
        _rowTitlesInOrder(tester, const Key('home-journeys-section')).length,
        3,
      );
      expect(find.byKey(const Key('home-journeys-view-all')), findsOneWidget);
    });

    testWidgets('a closed journey never appears', (tester) async {
      await _openHome(
        tester,
        journeys: [
          _journey('open-1', name: 'Still going'),
          _journey('closed-1', name: 'All done', status: journeyStatusClosed),
        ],
      );

      expect(find.byKey(const Key('home-journey-open-1')), findsOneWidget);
      expect(find.byKey(const Key('home-journey-closed-1')), findsNothing);
      expect(find.text('All done'), findsNothing);
    });

    testWidgets('tapping a journey row opens that journey', (tester) async {
      await _openHome(tester, journeys: [_journey('j1', name: 'Spring round')]);

      await tester.tap(find.byKey(const Key('home-journey-j1')));
      await _pumpBounded(tester);

      expect(_location(tester), '/journeys/j1');
    });

    testWidgets('the section is absent when no journey is open', (
      tester,
    ) async {
      await _openHome(
        tester,
        apiaries: [_apiary('a1', name: 'Fresh apiary')],
        activities: [_activity('x1', apiaryId: 'a1', daysAgo: 1)],
        journeys: [
          _journey('closed-1', name: 'All done', status: journeyStatusClosed),
        ],
      );

      expect(find.byKey(const Key('home-journeys-section')), findsNothing);
    });
  });

  group(
    'Home summary — apiaries not visited recently (#658, D-35, FR-AP-2)',
    () {
      testWidgets('includes an apiary past the window and excludes one inside '
          'it, never-visited first', (tester) async {
        await _openHome(
          tester,
          apiaries: [
            _apiary('stale', name: 'Stale apiary'),
            _apiary('fresh', name: 'Fresh apiary'),
            _apiary('never', name: 'Never apiary'),
          ],
          activities: [
            _activity('x1', apiaryId: 'stale', daysAgo: 31),
            _activity('x2', apiaryId: 'fresh', daysAgo: 29),
          ],
        );

        expect(_rowTitlesInOrder(tester, const Key('home-apiaries-section')), [
          'Never apiary',
          'Stale apiary',
        ]);
        expect(find.byKey(const Key('home-apiary-fresh')), findsNothing);
        expect(
          find.descendant(
            of: find.byKey(const Key('home-apiary-never')),
            matching: find.text('No activity recorded yet'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('home-apiary-badge-never')),
            matching: find.text('Never'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('home-apiary-badge-stale')),
            matching: find.text('31 d'),
          ),
          findsOneWidget,
        );
      });

      testWidgets('tapping an apiary row opens that apiary', (tester) async {
        await _openHome(
          tester,
          apiaries: [_apiary('a1', name: 'Quinta velha')],
        );

        await tester.tap(find.byKey(const Key('home-apiary-a1')));
        await _pumpBounded(tester);

        expect(_location(tester), '/apiaries/a1');
      });

      testWidgets('offers no "view all" link — rows tap to the record (D-35)', (
        tester,
      ) async {
        await _openHome(
          tester,
          apiaries: [
            for (var i = 1; i <= 5; i++) _apiary('a$i', name: 'Apiary $i'),
          ],
        );

        expect(find.byKey(const Key('home-apiaries-section')), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const Key('home-apiaries-section')),
            matching: find.byType(TextButton),
          ),
          findsNothing,
        );
      });

      testWidgets('the section is absent when every apiary is fresh', (
        tester,
      ) async {
        await _openHome(
          tester,
          apiaries: [_apiary('a1', name: 'Fresh apiary')],
          activities: [_activity('x1', apiaryId: 'a1', daysAgo: 2)],
        );

        expect(find.byKey(const Key('home-apiaries-section')), findsNothing);
      });
    },
  );

  group('Home summary — first run (#658, D-35)', () {
    testWidgets('shows ONE empty state with the first-run copy and no section '
        'headers at all', (tester) async {
      await _openHome(tester);

      expect(find.byType(EmptyState), findsOneWidget);
      expect(find.byType(SectionHeader), findsNothing);
      expect(
        find.textContaining("Let's set up your first apiary"),
        findsOneWidget,
      );
      expect(find.byKey(const Key('home-first-run')), findsOneWidget);
      expect(find.byKey(const Key('home-all-clear')), findsNothing);
    });

    testWidgets('its single action adds the first apiary', (tester) async {
      await _openHome(tester);

      await tester.tap(find.byKey(const Key('home-first-run-action')));
      await _pumpBounded(tester);

      expect(_location(tester), '/apiaries/new');
    });
  });

  group('Home summary — all clear (#658, D-35)', () {
    testWidgets('an org with data but nothing due gets the all-clear copy, '
        'not the first-run copy', (tester) async {
      await _openHome(
        tester,
        apiaries: [_apiary('a1', name: 'Fresh apiary')],
        activities: [_activity('x1', apiaryId: 'a1', daysAgo: 1)],
      );

      expect(find.byKey(const Key('home-all-clear')), findsOneWidget);
      expect(find.byKey(const Key('home-first-run')), findsNothing);
      expect(
        find.textContaining('Nothing needs your attention'),
        findsOneWidget,
      );
      // The recency window is named so the threshold is discoverable, and it
      // comes from the constant rather than a hardcoded string.
      expect(
        find.textContaining('$apiaryVisitRecencyDays days'),
        findsOneWidget,
      );
      expect(
        find.textContaining("Let's set up your first apiary"),
        findsNothing,
      );
    });
  });

  group('Home summary — loading (#658, FR-OF-1)', () {
    testWidgets('a section whose stream has not emitted renders nothing, not '
        'a spinner', (tester) async {
      await _openHome(
        tester,
        todos: [
          _todo('t1', title: 'Late task', dueDate: _isoDate(_daysAgo(5))),
        ],
        journeysStream: const Stream<List<Journey>>.empty(),
      );

      expect(find.byKey(const Key('home-tasks-section')), findsOneWidget);
      expect(find.byKey(const Key('home-journeys-section')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('home-screen')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
    });
  });

  // D-35: "every item tapping through to the record or to that list screen
  // FILTERED to the same set" — a "view all" that lands on the unfiltered
  // list makes the user re-derive by hand the very set Home just counted.
  group('Home view-all links land on a filtered list (#658, D-35)', () {
    testWidgets('the tasks view-all opens the Todos tab filtered to the '
        'tasks needing attention', (tester) async {
      await _openHome(
        tester,
        todos: [
          _todo('t1', title: 'Late task', dueDate: _isoDate(_daysAgo(4))),
          _todo(
            't2',
            title: 'Far away',
            dueDate: _isoDate(_today.add(const Duration(days: 60))),
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('home-tasks-view-all')));
      await tester.pumpAndSettle();

      expect(_location(tester), '/todos?status=overdue');
      expect(find.byKey(const Key('todo-t1')), findsOneWidget);
      expect(find.byKey(const Key('todo-t2')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('todo-filter-status-field')),
          matching: find.text('Overdue'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the journeys view-all opens the Journeys tab filtered to '
        'the open journeys', (tester) async {
      await _openHome(
        tester,
        journeys: [
          _journey('j1', name: 'Spring round'),
          _journey('j2', name: 'Last autumn', status: journeyStatusClosed),
        ],
      );

      await tester.tap(find.byKey(const Key('home-journeys-view-all')));
      await tester.pumpAndSettle();

      expect(_location(tester), '/journeys?status=open');
      expect(find.byKey(const Key('journey-j1')), findsOneWidget);
      expect(find.byKey(const Key('journey-j2')), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('journey-filter-status-field')),
          matching: find.text('Open'),
        ),
        findsOneWidget,
      );
    });
  });

  // Two states that were both rendered as first-run before this group
  // existed: "nothing has loaded yet" and "the local store is dead". Home is
  // the landing screen, so it says its first-run sentence — "Let's set up
  // your first apiary", with a button that creates one — before it has any
  // basis for it. On a device that already owns apiaries that is a false
  // statement AND an invitation to create a duplicate.
  group('Home is honest about not knowing yet (#658 review, D-35)', () {
    /// The four streams as they are on a cold start: subscribed, never yet
    /// emitted. In production this is the PowerSync wasm DB opening and the
    /// first query returning — a window that exists on EVERY launch.
    Future<void> openColdStart(WidgetTester tester) => _openHome(
      tester,
      todosStream: const Stream<List<Todo>>.empty(),
      journeysStream: const Stream<List<Journey>>.empty(),
      apiariesStream: const Stream<List<Apiary>>.empty(),
      activitiesStream: const Stream<List<Activity>>.empty(),
    );

    /// The shape of a local store that failed to open — denied storage,
    /// a private-mode browser, a worker that would not load: every stream
    /// errors without ever having produced a value.
    Future<void> openDeadStore(WidgetTester tester) => _openHome(
      tester,
      todosStream: Stream.error(StateError('local store failed to open')),
      journeysStream: Stream.error(StateError('local store failed to open')),
      apiariesStream: Stream.error(StateError('local store failed to open')),
      activitiesStream: Stream.error(StateError('local store failed to open')),
    );

    testWidgets('a cold start shows no first-run copy and no "add your first '
        'apiary" button', (tester) async {
      await openColdStart(tester);

      expect(find.byKey(const Key('home-first-run')), findsNothing);
      expect(find.byKey(const Key('home-first-run-action')), findsNothing);
      expect(
        find.textContaining("Let's set up your first apiary"),
        findsNothing,
      );
    });

    testWidgets('a cold start stays quiet — no spinner on the landing screen '
        '(FR-OF-1)', (tester) async {
      await openColdStart(tester);

      expect(find.byKey(const Key('home-screen')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('home-screen')),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
      );
      expect(find.byType(EmptyState), findsNothing);
    });

    testWidgets('a dead local store never renders as first-run', (
      tester,
    ) async {
      await openDeadStore(tester);

      expect(find.byKey(const Key('home-first-run')), findsNothing);
      expect(find.byKey(const Key('home-first-run-action')), findsNothing);
      expect(find.byKey(const Key('home-all-clear')), findsNothing);
    });

    testWidgets('a dead local store reaches the user instead of being '
        'swallowed forever', (tester) async {
      await openDeadStore(tester);

      expect(find.byKey(const Key('home-unavailable')), findsOneWidget);
    });

    testWidgets('a store that dies while sections are on screen says so '
        'rather than freezing silently on stale data', (tester) async {
      // Todos resolved first and Home painted its tasks section; the store
      // then failed for the apiaries query. The section that DID resolve
      // must stay (offline-first), but the screen must not pretend the rest
      // of the picture is simply empty.
      await _openHome(
        tester,
        todos: [
          _todo('t1', title: 'Late task', dueDate: _isoDate(_daysAgo(4))),
        ],
        apiariesStream: Stream.error(StateError('local store went away')),
      );

      expect(find.byKey(const Key('home-tasks-section')), findsOneWidget);
      expect(find.byKey(const Key('home-unavailable-notice')), findsOneWidget);
    });
  });

  // The tasks section shows the UNION of overdue and due-soon, but its link
  // opens `/todos?status=overdue` — a strict subset. Labelling that link with
  // the union's count promises rows the destination will not show, and with
  // no overdue row at all it promises N tasks and delivers "No todos match
  // your filters." The Tasks tab cannot express the union today (its filters
  // AND together, `open` excludes overdue, and its due presets are calendar
  // windows rather than todo_due.dart's per-priority lead time) — that gap is
  // #661. Until then the LABEL must describe what the link actually opens.
  group('the tasks view-all promises only what it opens (#658 review, '
      '#661)', () {
    testWidgets('with no overdue row, the section offers no view-all link at '
        'all rather than one that lands on an empty list', (tester) async {
      await _openHome(
        tester,
        todos: [
          _todo(
            'soon-1',
            title: 'Due tomorrow',
            priority: todoPriorityHigh,
            dueDate: _isoDate(_today.add(const Duration(days: 1))),
          ),
          _todo(
            'soon-2',
            title: 'Due today',
            priority: todoPriorityHigh,
            dueDate: _isoDate(_today),
          ),
        ],
      );

      // Both rows are on screen and counted...
      expect(find.byKey(const Key('home-todo-soon-1')), findsOneWidget);
      expect(find.byKey(const Key('home-todo-soon-2')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('home-tasks-count')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
      // ...and nothing offers to "view all 2" of them anywhere else.
      expect(find.byKey(const Key('home-tasks-view-all')), findsNothing);
      expect(find.textContaining('View all 2'), findsNothing);
    });

    testWidgets('with a mix, the link is worded and counted as OVERDUE — the '
        'subset it opens — not as the whole section', (tester) async {
      await _openHome(
        tester,
        todos: [
          _todo('late-1', title: 'Late one', dueDate: _isoDate(_daysAgo(3))),
          _todo(
            'soon-1',
            title: 'Due today',
            priority: todoPriorityHigh,
            dueDate: _isoDate(_today),
          ),
          _todo(
            'soon-2',
            title: 'Due tomorrow',
            priority: todoPriorityHigh,
            dueDate: _isoDate(_today.add(const Duration(days: 1))),
          ),
        ],
      );

      // The section still counts the full union of 3...
      expect(
        find.descendant(
          of: find.byKey(const Key('home-tasks-count')),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
      // ...but the link names the 1 overdue task it actually opens.
      expect(find.byKey(const Key('home-tasks-view-all')), findsOneWidget);
      expect(find.text('View the 1 overdue task'), findsOneWidget);
      expect(find.textContaining('View all 3'), findsNothing);
    });

    testWidgets('the link it does offer lands on a list with rows in it', (
      tester,
    ) async {
      await _openHome(
        tester,
        todos: [
          _todo('late-1', title: 'Late one', dueDate: _isoDate(_daysAgo(3))),
          _todo('late-2', title: 'Late two', dueDate: _isoDate(_daysAgo(9))),
          _todo(
            'soon-1',
            title: 'Due today',
            priority: todoPriorityHigh,
            dueDate: _isoDate(_today),
          ),
        ],
      );

      expect(find.text('View all 2 overdue tasks'), findsOneWidget);

      await tester.tap(find.byKey(const Key('home-tasks-view-all')));
      await tester.pumpAndSettle();

      expect(_location(tester), '/todos?status=overdue');
      expect(find.byKey(const Key('todo-late-1')), findsOneWidget);
      expect(find.byKey(const Key('todo-late-2')), findsOneWidget);
    });
  });

  // home_screen.dart's contract is that it reads NO clock: a row's badge
  // comes from the [AttentionTodo.bucket] and the
  // [ApiaryVisitRecency.daysSinceLastVisit] the summary already decided. That
  // held by convention only — nothing failed if a widget reached for
  // `DateTime.now()` again, and a second read can straddle midnight and badge
  // a row differently from the list it sits in.
  //
  // This pins it: the whole summary is built against a `now` YEARS away from
  // the real clock, so any re-read produces wildly different numbers and
  // these assertions fail.
  group('Home renders against the summary\'s clock, never its own (#658 '
      'review, D-35)', () {
    /// A summary computed at a fixed instant, from fixtures dated relative
    /// to THAT instant rather than to today.
    HomeSummary pinnedSummary() {
      final now = DateTime(2031, 3, 14, 9, 30);
      return buildHomeSummary(
        todos: [
          _todo('late', title: 'Late one', dueDate: '2031-03-05'),
          _todo(
            'soon',
            title: 'Due soon',
            priority: todoPriorityHigh,
            dueDate: '2031-03-15',
          ),
        ],
        journeys: const [],
        apiaries: [_apiary('stale', name: 'Stale apiary')],
        activities: [
          const Activity(
            id: 'x1',
            apiaryId: 'stale',
            type: 'inspection',
            occurredAt: '2031-01-31',
            attributes: {},
            organizationId: 'test-org',
          ),
        ],
        now: now,
      );
    }

    testWidgets('an overdue badge counts days from the summary\'s now', (
      tester,
    ) async {
      await _openHome(tester, summary: pinnedSummary());

      // 2031-03-14 minus 2031-03-05 — not "days since today".
      expect(
        find.descendant(
          of: find.byKey(const Key('home-todo-badge-late')),
          matching: find.text('9 d late'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a due-soon row stays due-soon — the badge is the bucket the '
        'summary decided, not a re-derived one', (tester) async {
      await _openHome(tester, summary: pinnedSummary());

      expect(
        find.descendant(
          of: find.byKey(const Key('home-todo-badge-soon')),
          matching: find.text('Soon'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('an apiary badge counts days from the summary\'s now', (
      tester,
    ) async {
      await _openHome(tester, summary: pinnedSummary());

      // 2031-01-31 to 2031-03-14 — 42 days, fixed for all time.
      expect(
        find.descendant(
          of: find.byKey(const Key('home-apiary-badge-stale')),
          matching: find.text('42 d'),
        ),
        findsOneWidget,
      );
    });
  });
}
