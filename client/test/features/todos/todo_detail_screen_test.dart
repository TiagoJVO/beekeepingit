import 'dart:async';

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
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

/// A no-op [LocalStoreEngine] — [_FakeTodosRepository] overrides every method
/// exercised, mirroring the sibling todos/activities/journeys test fixtures.
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

/// A fake [TodosRepository] whose [complete]/[reopen] push a new [Todo] onto
/// a broadcast stream — the detail screen watches [todoByIdProvider] (a LIVE
/// per-id provider, mirrors [ActivityDetailScreen]'s own `activityByIdProvider`
/// watch), so exercising its in-place toggle needs a genuinely live stream
/// rather than a fixed `Stream.value(...)`, the same technique
/// sync_needs_fix_screen_test.dart's `_FakeRejectedStore` already uses to
/// prove a write is reflected by the SAME live query a real PowerSync-backed
/// store would re-emit through.
class _FakeTodosRepository extends TodosRepository {
  _FakeTodosRepository(
    Todo? initial, {
    this.throwOnComplete = false,
    this.throwOnReopen = false,
  }) : current = initial,
       super(_NoopLocalStore());

  Todo? current;
  final bool throwOnComplete;
  final bool throwOnReopen;
  final _controller = StreamController<Todo?>.broadcast();

  final List<String> completed = [];
  final List<String> reopened = [];

  /// Yields [current] immediately on listen, then forwards every subsequent
  /// write — the fixture-level equivalent of a live PowerSync watch query.
  Stream<Todo?> get liveStream async* {
    yield current;
    yield* _controller.stream;
  }

  /// Used by the edit form's own one-shot `_loadExisting()` (reached via the
  /// detail screen's edit FAB) — the base [TodosRepository.getById] would
  /// otherwise always resolve null against [_NoopLocalStore], leaving the
  /// form blank instead of pre-filled.
  @override
  Future<Todo?> getById(String id) async => current;

  @override
  Future<void> complete(String id) async {
    if (throwOnComplete) throw Exception('boom-complete');
    final t = current!;
    current = Todo(
      id: t.id,
      title: t.title,
      description: t.description,
      dueDate: t.dueDate,
      priority: t.priority,
      status: 'done',
      completedAt: '2026-07-18T00:00:00Z',
      assigneeId: t.assigneeId,
      apiaryId: t.apiaryId,
      organizationId: t.organizationId,
    );
    _controller.add(current);
  }

  @override
  Future<void> reopen(String id) async {
    if (throwOnReopen) throw Exception('boom-reopen');
    final t = current!;
    current = Todo(
      id: t.id,
      title: t.title,
      description: t.description,
      dueDate: t.dueDate,
      priority: t.priority,
      status: 'open',
      completedAt: null,
      assigneeId: t.assigneeId,
      apiaryId: t.apiaryId,
      organizationId: t.organizationId,
    );
    _controller.add(current);
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

const _apiaries = [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)];
const _memberNames = {'m1': 'Maria Silva'};

Widget _buildApp({required _FakeTodosRepository repo}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(_apiaries)),
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      todoByIdProvider.overrideWith((ref, id) => repo.liveStream),
      memberNamesProvider.overrideWith((ref) async => _memberNames),
      todosRepositoryProvider.overrideWith((ref) async => repo),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openDetail(
  WidgetTester tester, {
  required _FakeTodosRepository repo,
  String todoId = 't1',
}) async {
  await tester.pumpWidget(_buildApp(repo: repo));
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(AppShell)));
  router.go('/todos/$todoId');
  await tester.pumpAndSettle();
}

Todo _todo({
  String id = 't1',
  String title = 'Inspect hive 3',
  String? description,
  String priority = 'medium',
  String status = 'open',
  String? dueDate,
  String? completedAt,
  String? assigneeId,
  String? apiaryId,
}) => Todo(
  id: id,
  title: title,
  description: description,
  priority: priority,
  status: status,
  dueDate: dueDate,
  completedAt: completedAt,
  assigneeId: assigneeId,
  apiaryId: apiaryId,
  organizationId: 'test-org',
);

void main() {
  group('todo detail screen (#293, FR-TD-1)', () {
    testWidgets('renders every field read-only', (tester) async {
      final repo = _FakeTodosRepository(
        _todo(
          description: 'Check for mites',
          priority: 'high',
          dueDate: '2026-08-01',
          assigneeId: 'm1',
          apiaryId: 'a1',
        ),
      );
      await _openDetail(tester, repo: repo);

      expect(find.byKey(const Key('todo-detail-header')), findsOneWidget);
      expect(find.text('Inspect hive 3'), findsOneWidget);
      expect(find.text('Check for mites'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      expect(find.text('Maria Silva'), findsOneWidget);
      expect(find.text('Serra Norte'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      // No edit controls on this read-focused screen (edit lives on the
      // form, reached via the FAB).
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets(
      'an unset description/due date/assignee/apiary show their fallback '
      'text, not blank',
      (tester) async {
        final repo = _FakeTodosRepository(_todo());
        await _openDetail(tester, repo: repo);

        expect(find.text('No description'), findsOneWidget);
        expect(find.text('No due date'), findsOneWidget);
        expect(find.text('Unassigned'), findsOneWidget);
        expect(find.text('No apiary'), findsOneWidget);
      },
    );

    testWidgets(
      'an assignee id not in the roster falls back to a short id, not a '
      'blank row',
      (tester) async {
        final repo = _FakeTodosRepository(
          _todo(assigneeId: 'abcdefgh99999999'),
        );
        await _openDetail(tester, repo: repo);

        expect(find.text('Member 99999999'), findsOneWidget);
      },
    );

    testWidgets(
      'an apiary id no longer in the locally-synced set falls back to '
      'Unknown apiary',
      (tester) async {
        final repo = _FakeTodosRepository(_todo(apiaryId: 'gone'));
        await _openDetail(tester, repo: repo);

        expect(find.text('Unknown apiary'), findsOneWidget);
      },
    );

    testWidgets('a done todo shows the completed status and timestamp', (
      tester,
    ) async {
      final repo = _FakeTodosRepository(
        _todo(status: 'done', completedAt: '2026-07-01T10:00:00Z'),
      );
      await _openDetail(tester, repo: repo);

      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('Completed at'), findsOneWidget);
      // The complete/reopen action offers Reopen, not Mark as complete.
      expect(find.text('Reopen'), findsOneWidget);
    });

    group('complete/reopen toggle (in place, no navigation)', () {
      testWidgets('tapping the toggle on an open todo calls complete() and '
          'updates the screen in place', (tester) async {
        final repo = _FakeTodosRepository(_todo());
        await _openDetail(tester, repo: repo);

        expect(find.text('Mark as complete'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('todo-detail-complete-toggle-button')),
        );
        await tester.pumpAndSettle();

        expect(repo.completed, ['t1']);
        // Still on the detail screen (no navigation) — status flipped live.
        expect(find.byKey(const Key('todo-detail-header')), findsOneWidget);
        expect(find.text('Completed'), findsOneWidget);
        expect(find.text('Reopen'), findsOneWidget);
      });

      testWidgets('tapping the toggle on a done todo calls reopen() and '
          'updates the screen in place', (tester) async {
        final repo = _FakeTodosRepository(
          _todo(status: 'done', completedAt: '2026-07-01T10:00:00Z'),
        );
        await _openDetail(tester, repo: repo);

        await tester.tap(
          find.byKey(const Key('todo-detail-complete-toggle-button')),
        );
        await tester.pumpAndSettle();

        expect(repo.reopened, ['t1']);
        expect(find.text('Open'), findsOneWidget);
        expect(find.text('Mark as complete'), findsOneWidget);
      });

      testWidgets('a failing toggle shows an error and stays in place', (
        tester,
      ) async {
        final repo = _FakeTodosRepository(_todo(), throwOnComplete: true);
        await _openDetail(tester, repo: repo);

        await tester.tap(
          find.byKey(const Key('todo-detail-complete-toggle-button')),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('boom-complete'), findsOneWidget);
        expect(find.byKey(const Key('todo-detail-header')), findsOneWidget);
      });

      testWidgets(
        'a failing reopen toggle shows an error and stays in place',
        (tester) async {
          final repo = _FakeTodosRepository(
            _todo(status: 'done', completedAt: '2026-07-01T10:00:00Z'),
            throwOnReopen: true,
          );
          await _openDetail(tester, repo: repo);

          await tester.tap(
            find.byKey(const Key('todo-detail-complete-toggle-button')),
          );
          await tester.pumpAndSettle();

          expect(find.textContaining('boom-reopen'), findsOneWidget);
          expect(find.byKey(const Key('todo-detail-header')), findsOneWidget);
        },
      );
    });

    testWidgets('the edit FAB navigates to the edit form', (tester) async {
      final repo = _FakeTodosRepository(_todo());
      await _openDetail(tester, repo: repo);

      expect(find.byKey(const Key('todo-detail-edit-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('todo-detail-edit-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
      final titleField = tester.widget<TextFormField>(
        find.byKey(const Key('todo-title-field')),
      );
      expect(titleField.controller!.text, 'Inspect hive 3');
    });

    testWidgets('a deleted/unknown todo bounces back to the Todos tab', (
      tester,
    ) async {
      final repo = _FakeTodosRepository(null);
      await _openDetail(tester, repo: repo);

      expect(find.byKey(const Key('todo-detail-header')), findsNothing);
      expect(find.text('No todos yet.'), findsOneWidget);
    });
  });
}
