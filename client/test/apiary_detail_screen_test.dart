import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixtures mirroring widget_test.dart's/app_shell_test.dart's own — kept
/// local rather than imported since those files' fixtures are file-private.
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

/// A no-op [LocalStoreEngine] — [_FakeTodosRepository] overrides every
/// method the quick-create sheet touches, so the superclass's store is
/// never actually used. Mirrors todo_quick_create_sheet_test.dart's/
/// add_activity_screen_test.dart's own identical fixture.
class _NoopLocalStore implements LocalStoreEngine {
  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) => const Stream.empty();
  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async => null;
  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => const [];
  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}
  @override
  Future<void> clear() async {}
}

/// Records `create()` calls from the apiary detail page's own contextual
/// "New todo" FAB (#52, FR-UX-2) — mirrors
/// todo_quick_create_sheet_test.dart's own `_FakeTodosRepository`.
class _FakeTodosRepository extends TodosRepository {
  _FakeTodosRepository() : super(_NoopLocalStore());

  final List<({String title, String? apiaryId})> created = [];

  @override
  Future<String> create({
    required String title,
    required String priority,
    String? description,
    String? dueDate,
    String? assigneeId,
    String? apiaryId,
  }) async {
    created.add((title: title, apiaryId: apiaryId));
    return 'fake-${created.length - 1}';
  }
}

/// Builds the full app (real router/shell included) as an authenticated,
/// onboarded user with a fixed local apiaries list — the detail screen
/// (#32) reads from the same apiariesStreamProvider the list screen does,
/// so this harness matches widget_test.dart's/app_shell_test.dart's own
/// override-providers-not-network convention.
///
/// Note on the edit-navigation test below: apiariesRepositoryProvider (the
/// one that actually reads/writes — powered by a real, connecting
/// PowerSync instance) is intentionally left un-overridden, matching every
/// other widget test in this suite. That means once navigation reaches
/// apiary_form_screen.dart in edit mode, its initState-triggered
/// _loadExisting() never resolves in this environment (no platform
/// channel/network), so the form is left showing its own indefinite busy
/// spinner rather than the loaded field — expected and asserted on, not a
/// bug in the screen under test.
///
/// [todosRepository] is only needed by the #52 add-todo FAB tests below — a
/// real (un-overridden) todosRepositoryProvider would otherwise hang on the
/// never-resolving PowerSync chain the moment that FAB's sheet is saved.
Widget _buildApp({
  required List<Apiary> apiaries,
  Map<String, List<ApiaryCounter>> counters = const {},
  TodosRepository? todosRepository,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      if (todosRepository != null)
        todosRepositoryProvider.overrideWith((ref) async => todosRepository),
      // The detail screen watches apiaryByIdProvider (HIGH finding: a
      // narrow per-id family provider, not the whole-org
      // apiariesStreamProvider) — overridden here the same way
      // apiaryCountersProvider already is, resolving from the same fixed
      // [apiaries] list by id so existing fixtures/tests don't need to
      // change shape.
      apiaryByIdProvider.overrideWith(
        (ref, apiaryId) => Stream.value(
          apiaries.cast<Apiary?>().firstWhere(
            (a) => a!.id == apiaryId,
            orElse: () => null,
          ),
        ),
      ),
      // The detail screen's generic counters section (#256) watches this
      // family provider per apiary id. Un-overridden it depends on the real
      // (never-resolving in tests) apiariesRepositoryProvider, so the tests
      // that don't care about non-hive counters simply see it stay in
      // loading state (only the always-on hive badge renders — exactly the
      // "hives always shows" default). Tests that DO exercise other-type
      // rendering pass a fixed list here.
      apiaryCountersProvider.overrideWith(
        (ref, apiaryId) =>
            Stream.value(counters[apiaryId] ?? const <ApiaryCounter>[]),
      ),
      // The activities section (#42) watches this family provider per
      // apiary id — overridden with an empty stream so opening the detail
      // screen doesn't hang on the real (never-resolving here)
      // activitiesRepositoryProvider chain; unlike the counters section,
      // ActivityListView DOES render a loading spinner, which would make
      // pumpAndSettle time out if left un-overridden.
      activitiesByApiaryProvider.overrideWith(
        (ref, apiaryId) => Stream.value(const <Activity>[]),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      // Keep the member-name roster hermetic (#44): the activity list watches
      // memberNamesProvider, which would otherwise attempt a real fetch —
      // attribution falls back to short ids here, which these tests assert.
      memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

void main() {
  testWidgets('tapping an apiary in the list opens its detail screen (#32)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('apiary-a1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('apiary-detail-header')), findsOneWidget);
    expect(find.text('Serra Norte'), findsOneWidget);
    expect(find.text('3 hives'), findsOneWidget);
  });

  testWidgets(
    'the detail screen renders correctly when location and notes are empty (#32 AC)',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 0)],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('apiary-detail-header')), findsOneWidget);
      expect(find.byKey(const Key('apiary-detail-location')), findsOneWidget);
      expect(find.text('No location set'), findsOneWidget);
      // No notes block at all when notes is unset — not an empty card.
      expect(find.byKey(const Key('apiary-detail-notes')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the detail screen shows notes when present (FR-AP-8, #196)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        apiaries: const [
          Apiary(
            id: 'a1',
            name: 'Serra Norte',
            hiveCount: 3,
            notes: 'Rosmaninho e eucalipto; acesso por caminho de terra.',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('apiary-a1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('apiary-detail-notes')), findsOneWidget);
    expect(
      find.text('Rosmaninho e eucalipto; acesso por caminho de terra.'),
      findsOneWidget,
    );
  });

  testWidgets('a blank (whitespace-only) notes value is treated as absent', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        apiaries: const [
          Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3, notes: '   '),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('apiary-a1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('apiary-detail-notes')), findsNothing);
  });

  testWidgets('the edit action navigates to the edit form (#32)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        apiaries: const [
          Apiary(
            id: 'a1',
            name: 'Serra Norte',
            hiveCount: 3,
            notes: 'Cerca elétrica.',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('apiary-a1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('apiary-detail-edit-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('apiary-detail-edit-button')));
    // Pump past the page-transition animation in bounded steps (not
    // pumpAndSettle, which would wait forever): the edit form's initState
    // kicks off a real apiariesRepositoryProvider load
    // (apiary_form_screen.dart's _loadExisting), which needs a real
    // PowerSync instance this widget-test environment doesn't provide —
    // the form is left showing its own (indefinite) busy spinner, whose
    // implicit animation would make pumpAndSettle hang. What this test
    // asserts is the navigation itself: the route changed to the edit
    // form and the shell header/back button reflect that. Several smaller
    // pumps (rather than one large jump) reliably carry the transition to
    // completion regardless of its exact curve/duration.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // "Edit apiary" is asserted via findsWidgets, not findsOneWidget: the
    // string is shared by the shell header title (editApiaryTitle) and
    // the detail screen's own FAB label (editApiaryAction) — both
    // legitimately render "Edit apiary" in EN. The detail screen's own
    // Container (apiary-detail-header) also stays mounted underneath the
    // pushed edit route (the Navigator keeps the previous page's widget
    // tree alive, not just off-screen, until it's actually popped). The
    // real signal that navigation reached the edit form is the header
    // title switch plus the form's own (indefinite, PowerSync-less)
    // loading spinner — apiary_form_screen.dart's edit mode always shows
    // that spinner in this test environment (see the file-level doc
    // comment above), never the loaded field, so a spinner is exactly
    // what "we're on the edit form" looks like here.
    expect(find.text('Edit apiary'), findsWidgets);
    expect(find.byKey(const Key('shell-back-button')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // The back button returns to the detail screen, not straight to the
    // list (edit is pushed under the detail route in app_router.dart).
    await tester.tap(find.byKey(const Key('shell-back-button')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const Key('apiary-detail-header')), findsOneWidget);
  });

  // --- Counters section (#256, FR-AP-7) ---

  testWidgets(
    'the hives badge ALWAYS shows (0 when the apiary has no counter row) '
    '(#256 AC)',
    (tester) async {
      // No hive counter row for this apiary at all — hive_count resolves to
      // 0 at the repository (the "0 default" here comes in via hiveCount: 0
      // on the model, which the real repo derives from the absent counter),
      // and the badge must still render.
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 0)],
          counters: const {'a1': <ApiaryCounter>[]},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      // The hive badge is present and reads the "no hives" plural — the exact
      // text the e2e depends on, unchanged by the counters decoupling.
      expect(find.byKey(const Key('apiary-detail-hive-count')), findsOneWidget);
      expect(find.text('No hives'), findsOneWidget);
    },
  );

  testWidgets(
    'the hives badge shows the counter-backed value (e2e "12 hives" stays '
    'identical) (#256)',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [
            Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 12),
          ],
          counters: const {
            'a1': [
              ApiaryCounter(apiaryId: 'a1', counterType: 'hive', value: 12),
            ],
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('apiary-detail-hive-count')), findsOneWidget);
      expect(find.text('12 hives'), findsOneWidget);
    },
  );

  testWidgets(
    'an unknown/newer-server counter type is skipped, not rendered as raw '
    'internals (#256: additive row shapes degrade gracefully)',
    (tester) async {
      // A counter type this client version has no label for
      // (counter_types.dart's counterValueLabel returns null). It must NOT
      // appear on screen (no badge, no leaked type string), while the hive
      // badge still renders normally.
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 4)],
          counters: const {
            'a1': [
              ApiaryCounter(apiaryId: 'a1', counterType: 'hive', value: 4),
              ApiaryCounter(
                apiaryId: 'a1',
                counterType: 'nucs_from_future',
                value: 7,
              ),
            ],
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      expect(find.text('4 hives'), findsOneWidget);
      expect(
        find.byKey(const Key('apiary-detail-counter-nucs_from_future')),
        findsNothing,
      );
      expect(find.textContaining('nucs_from_future'), findsNothing);
      expect(find.textContaining('7'), findsNothing);
    },
  );

  // --- Error state (HIGH #4: no test previously drove the error: branch) ---

  testWidgets(
    'shows an error state (not a crash/blank page) when the per-apiary '
    'stream errors',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            apiariesStreamProvider.overrideWith(
              (ref) => Stream.value(const [
                Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
              ]),
            ),
            apiaryByIdProvider.overrideWith(
              (ref, apiaryId) => Stream<Apiary?>.error('boom'),
            ),
            apiaryCountersProvider.overrideWith(
              (ref, apiaryId) => Stream.value(const <ApiaryCounter>[]),
            ),
            activitiesByApiaryProvider.overrideWith(
              (ref, apiaryId) => Stream.value(const <Activity>[]),
            ),
            profileProvider.overrideWith(_CompleteProfileController.new),
            memberNamesProvider.overrideWith(
              (ref) async => const <String, String>{},
            ),
            organizationProvider.overrideWith(
              _ExistingOrganizationController.new,
            ),
          ],
          child: const BeekeepingitApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not load apiaries'), findsOneWidget);
      expect(find.byKey(const Key('apiary-detail-header')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  // --- Quick-create-todo FAB (#52, FR-TD-1, FR-UX-1, FR-UX-2) ---

  group('add-todo FAB (#52)', () {
    testWidgets(
      'coexists with the existing add-activity and edit FABs (all three '
      'render together)',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('apiary-detail-add-todo-button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('apiary-detail-add-activity-button')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('apiary-detail-edit-button')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'tapping it opens the quick-create sheet pre-filled with this apiary '
      '(FR-UX-2 contextual create)',
      (tester) async {
        final repo = _FakeTodosRepository();
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
            todosRepository: repo,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-todo-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('todo-quick-create-apiary-chip')),
          findsOneWidget,
        );
        expect(find.textContaining('Serra Norte'), findsWidgets);

        await tester.enterText(
          find.byKey(const Key('todo-quick-create-title-field')),
          'Check queen',
        );
        await tester.tap(
          find.byKey(const Key('todo-quick-create-save-button')),
        );
        await tester.pumpAndSettle();

        expect(repo.created, hasLength(1));
        expect(repo.created.single.title, 'Check queen');
        expect(repo.created.single.apiaryId, 'a1');
      },
    );

    testWidgets(
      'the existing add-activity FAB still navigates as before (regression '
      'guard)',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        // Bounded pumps (not pumpAndSettle, which would hang forever): the
        // pushed add-activity form's own journey-matching section
        // (journeyMatchesProvider) depends on the real, never-resolving
        // journeysRepositoryProvider in this environment, whose loading
        // state renders an indeterminate LinearProgressIndicator — same
        // rationale as this file's own edit-navigation test above, which
        // hits the equivalent issue via apiariesRepositoryProvider.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(find.byKey(const Key('shell-back-button')), findsOneWidget);
        expect(find.text('Add activity'), findsWidgets);
      },
    );
  });
}
