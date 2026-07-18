import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/widgets/field_action_button.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/a11y_matchers.dart';

/// A no-op [LocalStoreEngine] — [_FakeTodosRepository] overrides every method
/// the form touches, mirroring add_activity_screen_test.dart's/
/// journey_form_screen_test.dart's identical `_NoopLocalStore` fixture.
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

class _CreatedTodo {
  _CreatedTodo({
    required this.title,
    required this.priority,
    this.description,
    this.dueDate,
    this.assigneeId,
    this.apiaryId,
  });
  final String title;
  final String priority;
  final String? description;
  final String? dueDate;
  final String? assigneeId;
  final String? apiaryId;
}

class _UpdatedTodo {
  _UpdatedTodo({
    required this.id,
    required this.title,
    required this.priority,
    this.description,
    this.dueDate,
    this.assigneeId,
    this.apiaryId,
  });
  final String id;
  final String title;
  final String priority;
  final String? description;
  final String? dueDate;
  final String? assigneeId;
  final String? apiaryId;
}

/// Records create()/update()/complete()/reopen()/delete() calls so the
/// form's flows can be asserted without a real PowerSync backend — mirrors
/// add_activity_screen_test.dart's/journey_form_screen_test.dart's own fake
/// repositories, including their `throwOn*` flags.
class _FakeTodosRepository extends TodosRepository {
  _FakeTodosRepository({
    this.throwOnCreate = false,
    this.throwOnUpdate = false,
    this.throwOnDelete = false,
    this.throwOnGetById = false,
    this.throwOnComplete = false,
    this.throwOnReopen = false,
    this.existing,
  }) : super(_NoopLocalStore());

  final bool throwOnCreate;
  final bool throwOnUpdate;
  final bool throwOnDelete;
  final bool throwOnGetById;
  final bool throwOnComplete;
  final bool throwOnReopen;
  final Todo? existing;

  final List<_CreatedTodo> created = [];
  final List<_UpdatedTodo> updated = [];
  final List<String> completed = [];
  final List<String> reopened = [];
  final List<String> deleted = [];

  @override
  Future<Todo?> getById(String id) async {
    if (throwOnGetById) throw Exception('boom-load');
    return existing;
  }

  @override
  Future<String> create({
    required String title,
    required String priority,
    String? description,
    String? dueDate,
    String? assigneeId,
    String? apiaryId,
  }) async {
    if (throwOnCreate) throw Exception('boom-create');
    created.add(
      _CreatedTodo(
        title: title,
        priority: priority,
        description: description,
        dueDate: dueDate,
        assigneeId: assigneeId,
        apiaryId: apiaryId,
      ),
    );
    return 'fake-${created.length - 1}';
  }

  @override
  Future<void> update(
    String id, {
    required String title,
    required String priority,
    String? description,
    String? dueDate,
    String? assigneeId,
    String? apiaryId,
  }) async {
    if (throwOnUpdate) throw Exception('boom-update');
    updated.add(
      _UpdatedTodo(
        id: id,
        title: title,
        priority: priority,
        description: description,
        dueDate: dueDate,
        assigneeId: assigneeId,
        apiaryId: apiaryId,
      ),
    );
  }

  @override
  Future<void> complete(String id) async {
    if (throwOnComplete) throw Exception('boom-complete');
    completed.add(id);
  }

  @override
  Future<void> reopen(String id) async {
    if (throwOnReopen) throw Exception('boom-reopen');
    reopened.add(id);
  }

  @override
  Future<void> delete(String id) async {
    if (throwOnDelete) throw Exception('boom-delete');
    deleted.add(id);
  }
}

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

const _apiaryA = Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4);
const _apiaryB = Apiary(id: 'a2', name: 'Serra Norte', hiveCount: 2);
const _memberNames = {'m1': 'Maria Silva', 'm2': 'Joao Costa'};

Widget _buildApp({
  required _FakeTodosRepository repo,
  List<Apiary> apiaries = const [_apiaryA, _apiaryB],
  Map<String, String> memberNames = _memberNames,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      memberNamesProvider.overrideWith((ref) async => memberNames),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      todosRepositoryProvider.overrideWith((ref) async => repo),
    ],
    child: const BeekeepingitApp(),
  );
}

/// The todo form's content (title/description/due date/priority/assignee
/// picker/apiary picker/save/complete-reopen/delete) exceeds the default
/// 800x600 test viewport — mirrors journey_form_screen_test.dart's/
/// add_activity_screen_test.dart's own fix.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _goToNewForm(
  WidgetTester tester, {
  required _FakeTodosRepository repo,
}) async {
  _useTallViewport(tester);
  await tester.pumpWidget(_buildApp(repo: repo));
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(AppShell)));
  router.go('/todos/new');
  await tester.pumpAndSettle();
}

Future<void> _goToEditForm(
  WidgetTester tester, {
  required _FakeTodosRepository repo,
  String todoId = 't1',
}) async {
  _useTallViewport(tester);
  await tester.pumpWidget(_buildApp(repo: repo));
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(AppShell)));
  router.go('/todos/$todoId/edit');
  await tester.pumpAndSettle();
}

/// Pumps a bounded number of frames rather than [WidgetTester.pumpAndSettle]
/// — mirrors activity_detail_screen_test.dart's own documented workaround:
/// after a successful save this form navigates to `/todos/:id`, whose
/// `todoByIdProvider` watch never resolves in this PowerSync-less
/// environment (the fake repository's underlying `_NoopLocalStore.watch()`
/// never emits), leaving an indefinite `CircularProgressIndicator` that
/// `pumpAndSettle()` would time out waiting on.
Future<void> _pumpBounded(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('create (#293, FR-TD-1)', () {
    testWidgets('saving without a title is blocked', (tester) async {
      final repo = _FakeTodosRepository();
      await _goToNewForm(tester, repo: repo);

      await tester.tap(find.byKey(const Key('todo-save-button')));
      await tester.pumpAndSettle();

      expect(repo.created, isEmpty);
      expect(find.text('Title is required'), findsOneWidget);
    });

    testWidgets(
      'a valid create calls create() with all fields, defaulting priority '
      'to medium, and omitted due-date/assignee/apiary as null',
      (tester) async {
        final repo = _FakeTodosRepository();
        await _goToNewForm(tester, repo: repo);

        await tester.enterText(
          find.byKey(const Key('todo-title-field')),
          'Inspect hive 3',
        );
        await tester.tap(find.byKey(const Key('todo-save-button')));
        await tester.pumpAndSettle();

        expect(repo.created, hasLength(1));
        final saved = repo.created.single;
        expect(saved.title, 'Inspect hive 3');
        expect(saved.priority, 'medium');
        expect(saved.description, isNull);
        expect(saved.dueDate, isNull);
        expect(saved.assigneeId, isNull);
        expect(saved.apiaryId, isNull);
      },
    );

    testWidgets('a valid create with every field set passes them all through', (
      tester,
    ) async {
      final repo = _FakeTodosRepository();
      await _goToNewForm(tester, repo: repo);

      await tester.enterText(
        find.byKey(const Key('todo-title-field')),
        'Order syrup',
      );
      await tester.enterText(
        find.byKey(const Key('todo-description-field')),
        'Enough for 6 hives',
      );
      await tester.tap(find.byKey(const Key('todo-priority-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('todo-assignee-option-m1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('todo-apiary-option-a1')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('todo-save-button')));
      await tester.pumpAndSettle();

      expect(repo.created, hasLength(1));
      final saved = repo.created.single;
      expect(saved.title, 'Order syrup');
      expect(saved.description, 'Enough for 6 hives');
      expect(saved.priority, 'high');
      expect(saved.assigneeId, 'm1');
      expect(saved.apiaryId, 'a1');
    });

    testWidgets(
      'a failing create() keeps the form open and shows an error, not an '
      'indefinite spinner',
      (tester) async {
        final repo = _FakeTodosRepository(throwOnCreate: true);
        await _goToNewForm(tester, repo: repo);

        await tester.enterText(
          find.byKey(const Key('todo-title-field')),
          'Inspect hive 3',
        );
        await tester.tap(find.byKey(const Key('todo-save-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining('boom-create'), findsOneWidget);
      },
    );

    testWidgets(
      'a successful create navigates to the new todo\'s detail, leaving the '
      'form',
      (tester) async {
        final repo = _FakeTodosRepository();
        await _goToNewForm(tester, repo: repo);

        await tester.enterText(
          find.byKey(const Key('todo-title-field')),
          'Inspect hive 3',
        );
        await tester.tap(find.byKey(const Key('todo-save-button')));
        await _pumpBounded(tester);

        expect(repo.created, hasLength(1));
        expect(find.byKey(const Key('todo-title-field')), findsNothing);
        // The detail screen's edit FAB renders even while its own data watch
        // is still loading (see _pumpBounded's doc comment) — proof we
        // actually left the form for the detail route.
        expect(
          find.byKey(const Key('todo-detail-edit-button')),
          findsOneWidget,
        );
      },
    );
  });

  group('edit (#293, FR-TD-1)', () {
    Todo existingTodo({
      String status = 'open',
      String? dueDate,
      String? completedAt,
      String? assigneeId,
      String? apiaryId,
    }) => Todo(
      id: 't1',
      title: 'Existing todo',
      description: 'Some notes',
      priority: 'low',
      status: status,
      dueDate: dueDate,
      completedAt: completedAt,
      assigneeId: assigneeId,
      apiaryId: apiaryId,
    );

    testWidgets('pre-fills every field from getById', (tester) async {
      final repo = _FakeTodosRepository(
        existing: existingTodo(
          dueDate: '2026-08-01',
          assigneeId: 'm1',
          apiaryId: 'a1',
        ),
      );
      await _goToEditForm(tester, repo: repo);

      final titleField = tester.widget<TextFormField>(
        find.byKey(const Key('todo-title-field')),
      );
      expect(titleField.controller!.text, 'Existing todo');
      final descField = tester.widget<TextFormField>(
        find.byKey(const Key('todo-description-field')),
      );
      expect(descField.controller!.text, 'Some notes');
      expect(find.text('Low'), findsOneWidget);
      expect(find.text('Maria Silva'), findsOneWidget);
      expect(find.text('Monte Alto'), findsOneWidget);
      // A complete-toggle and a delete affordance are both present in edit
      // mode.
      expect(
        find.byKey(const Key('todo-complete-toggle-button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('todo-delete-button')), findsOneWidget);
    });

    testWidgets(
      'a valid edit calls update() (never create()) with all six fields as '
      'a full resubmit',
      (tester) async {
        final repo = _FakeTodosRepository(
          existing: existingTodo(
            dueDate: '2026-08-01',
            assigneeId: 'm1',
            apiaryId: 'a1',
          ),
        );
        await _goToEditForm(tester, repo: repo);

        await tester.enterText(
          find.byKey(const Key('todo-title-field')),
          'Renamed todo',
        );
        await tester.tap(find.byKey(const Key('todo-save-button')));
        await tester.pumpAndSettle();

        expect(repo.created, isEmpty);
        expect(repo.updated, hasLength(1));
        final saved = repo.updated.single;
        expect(saved.id, 't1');
        expect(saved.title, 'Renamed todo');
        expect(saved.description, 'Some notes');
        expect(saved.priority, 'low');
        expect(saved.dueDate, '2026-08-01');
        expect(saved.assigneeId, 'm1');
        expect(saved.apiaryId, 'a1');
      },
    );

    testWidgets(
      'clearing the due date resubmits it as null, leaving everything else '
      'unchanged',
      (tester) async {
        final repo = _FakeTodosRepository(
          existing: existingTodo(
            dueDate: '2026-08-01',
            assigneeId: 'm1',
            apiaryId: 'a1',
          ),
        );
        await _goToEditForm(tester, repo: repo);

        expect(
          find.byKey(const Key('todo-due-date-clear-button')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('todo-due-date-clear-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('todo-save-button')));
        await tester.pumpAndSettle();

        expect(repo.updated.single.dueDate, isNull);
        expect(repo.updated.single.assigneeId, 'm1');
        expect(repo.updated.single.apiaryId, 'a1');
      },
    );

    testWidgets(
      'changing the assignee resubmits the new assignee, apiary unchanged',
      (tester) async {
        final repo = _FakeTodosRepository(
          existing: existingTodo(assigneeId: 'm1', apiaryId: 'a1'),
        );
        await _goToEditForm(tester, repo: repo);

        await tester.tap(find.byKey(const Key('todo-assignee-option-m2')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('todo-save-button')));
        await tester.pumpAndSettle();

        expect(repo.updated.single.assigneeId, 'm2');
        expect(repo.updated.single.apiaryId, 'a1');
      },
    );

    testWidgets(
      'clearing the apiary association resubmits it as null, assignee '
      'unchanged',
      (tester) async {
        final repo = _FakeTodosRepository(
          existing: existingTodo(assigneeId: 'm1', apiaryId: 'a1'),
        );
        await _goToEditForm(tester, repo: repo);

        await tester.tap(find.byKey(const Key('todo-apiary-option-none')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('todo-save-button')));
        await tester.pumpAndSettle();

        expect(repo.updated.single.apiaryId, isNull);
        expect(repo.updated.single.assigneeId, 'm1');
      },
    );

    testWidgets(
      'a failing update() keeps the form open and shows an error, not an '
      'indefinite spinner',
      (tester) async {
        final repo = _FakeTodosRepository(
          existing: existingTodo(),
          throwOnUpdate: true,
        );
        await _goToEditForm(tester, repo: repo);

        await tester.tap(find.byKey(const Key('todo-save-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining('boom-update'), findsOneWidget);
      },
    );

    testWidgets(
      'a failing load resets busy and shows an error, not an indefinite '
      'spinner',
      (tester) async {
        final repo = _FakeTodosRepository(throwOnGetById: true);
        await _goToEditForm(tester, repo: repo);

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining('boom-load'), findsOneWidget);
      },
    );

    group('complete/reopen toggle (#293, FR-TD-1)', () {
      testWidgets(
        'tapping the toggle on an open todo calls complete(), updates in '
        'place, and does not navigate away',
        (tester) async {
          final repo = _FakeTodosRepository(existing: existingTodo());
          await _goToEditForm(tester, repo: repo);

          await tester.tap(
            find.byKey(const Key('todo-complete-toggle-button')),
          );
          await tester.pumpAndSettle();

          expect(repo.completed, ['t1']);
          expect(repo.reopened, isEmpty);
          // Still on the form (no navigation) — the label flipped to Reopen.
          expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
          expect(find.text('Reopen'), findsOneWidget);
          expect(find.textContaining('Todo marked complete'), findsOneWidget);
        },
      );

      testWidgets(
        'tapping the toggle on a done todo calls reopen(), updates in place',
        (tester) async {
          final repo = _FakeTodosRepository(
            existing: existingTodo(
              status: 'done',
              completedAt: '2026-07-01T00:00:00Z',
            ),
          );
          await _goToEditForm(tester, repo: repo);

          await tester.tap(
            find.byKey(const Key('todo-complete-toggle-button')),
          );
          await tester.pumpAndSettle();

          expect(repo.reopened, ['t1']);
          expect(repo.completed, isEmpty);
          expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
          expect(find.textContaining('Mark as complete'), findsOneWidget);
        },
      );

      testWidgets('a failing toggle shows an error and stays on the form', (
        tester,
      ) async {
        final repo = _FakeTodosRepository(
          existing: existingTodo(),
          throwOnComplete: true,
        );
        await _goToEditForm(tester, repo: repo);

        await tester.tap(find.byKey(const Key('todo-complete-toggle-button')));
        await tester.pumpAndSettle();

        expect(find.textContaining('boom-complete'), findsOneWidget);
        expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
      });
    });

    group('delete (#293, FR-TD-1)', () {
      testWidgets('tapping delete opens a confirm dialog; cancel is a no-op', (
        tester,
      ) async {
        final repo = _FakeTodosRepository(existing: existingTodo());
        await _goToEditForm(tester, repo: repo);

        await tester.tap(find.byKey(const Key('todo-delete-button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('todo-delete-confirm-dialog')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('todo-delete-confirm-cancel')));
        await tester.pumpAndSettle();

        expect(repo.deleted, isEmpty);
        expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
      });

      testWidgets('confirming delete calls delete() and navigates to /todos', (
        tester,
      ) async {
        final repo = _FakeTodosRepository(existing: existingTodo());
        await _goToEditForm(tester, repo: repo);

        await tester.tap(find.byKey(const Key('todo-delete-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('todo-delete-confirm-delete')));
        await tester.pumpAndSettle();

        expect(repo.deleted, ['t1']);
        expect(find.byKey(const Key('todo-title-field')), findsNothing);
      });

      testWidgets('a failing delete() keeps the form open and shows an error', (
        tester,
      ) async {
        final repo = _FakeTodosRepository(
          existing: existingTodo(),
          throwOnDelete: true,
        );
        await _goToEditForm(tester, repo: repo);

        await tester.tap(find.byKey(const Key('todo-delete-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('todo-delete-confirm-delete')));
        await tester.pumpAndSettle();

        expect(find.textContaining('boom-delete'), findsOneWidget);
        expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
      });
    });
  });

  group(
    'accessibility (D-18, docs/design/accessibility-field-ux-checklist.md)',
    () {
      testWidgets(
        'the save button meets the 56px field-action height, and every '
        'other interactive control meets the 44x44 minimum',
        (tester) async {
          final repo = _FakeTodosRepository(
            existing: const Todo(
              id: 't1',
              title: 'Existing todo',
              priority: 'low',
              status: 'open',
              dueDate: '2026-08-01',
              assigneeId: 'm1',
              apiaryId: 'a1',
            ),
          );
          await _goToEditForm(tester, repo: repo);

          expectMinTapTarget(
            tester,
            find.byKey(const Key('todo-save-button')),
            minSize: kFieldActionButtonHeight,
          );
          expectMinTapTarget(
            tester,
            find.byKey(const Key('todo-complete-toggle-button')),
          );
          expectMinTapTarget(
            tester,
            find.byKey(const Key('todo-delete-button')),
          );
          expectMinTapTarget(
            tester,
            find.byKey(const Key('todo-due-date-clear-button')),
          );
          expectMinTapTarget(
            tester,
            find.byKey(const Key('todo-assignee-option-m1')),
          );
          expectMinTapTarget(
            tester,
            find.byKey(const Key('todo-apiary-option-a1')),
          );
          expectHasSemanticsLabel(
            tester,
            const Key('todo-assignee-option-m1'),
          );
          expectHasSemanticsLabel(tester, const Key('todo-apiary-option-a1'));
        },
      );
    },
  );
}
