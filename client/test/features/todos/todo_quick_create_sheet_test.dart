import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/features/todos/todo_quick_create_sheet.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/a11y_matchers.dart';

/// A no-op [LocalStoreEngine] — [_FakeTodosRepository] overrides every method
/// the sheet touches, so the superclass's store is never actually used.
/// Mirrors apiary_form_screen_test.dart's/add_activity_screen_test.dart's own
/// identical fixture (kept file-private per this suite's own convention).
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
    this.dueDate,
    this.apiaryId,
  });

  final String title;
  final String priority;
  final String? dueDate;
  final String? apiaryId;
}

/// Records `create()` calls so the sheet's save path can be asserted without
/// a real PowerSync backend — mirrors `_FakeActivitiesRepository`'s/
/// `_FakeJourneysRepository`'s own record-and-return convention
/// (add_activity_screen_test.dart), including the `throwOnCreate` flag
/// (HIGH-finding precedent: drive a failing create() without a real backend
/// to prove the sheet catches the error and resets its busy state instead of
/// hanging or crashing).
class _FakeTodosRepository extends TodosRepository {
  _FakeTodosRepository({this.throwOnCreate = false}) : super(_NoopLocalStore());

  final bool throwOnCreate;
  final List<_CreatedTodo> created = [];

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
        dueDate: dueDate,
        apiaryId: apiaryId,
      ),
    );
    return 'fake-${created.length - 1}';
  }
}

/// Wraps a plain button that opens [showTodoQuickCreateSheet] on tap — the
/// sheet is a function, not a route, so tests drive it the same way a real
/// caller (the shell FAB / apiary detail FAB) would: call the function with
/// a live [BuildContext], not mount the sheet's private widget directly.
Widget _buildHost({
  required _FakeTodosRepository repo,
  String? initialApiaryId,
  String? initialApiaryName,
}) {
  return ProviderScope(
    overrides: [todosRepositoryProvider.overrideWith((ref) async => repo)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('open-quick-create-button'),
              onPressed: () => showTodoQuickCreateSheet(
                context,
                initialApiaryId: initialApiaryId,
                initialApiaryName: initialApiaryName,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(
  WidgetTester tester, {
  required _FakeTodosRepository repo,
  String? initialApiaryId,
  String? initialApiaryName,
}) async {
  await tester.pumpWidget(
    _buildHost(
      repo: repo,
      initialApiaryId: initialApiaryId,
      initialApiaryName: initialApiaryName,
    ),
  );
  await tester.tap(find.byKey(const Key('open-quick-create-button')));
  await tester.pumpAndSettle();
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  group('fields (#52 AC: minimal field set for field use)', () {
    testWidgets(
      'renders only title, priority and due-date fields — no description, '
      'assignee or apiary picker',
      (tester) async {
        final repo = _FakeTodosRepository();
        await _openSheet(tester, repo: repo);

        expect(
          find.byKey(const Key('todo-quick-create-title-field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('todo-quick-create-priority-field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('todo-quick-create-due-date-field')),
          findsOneWidget,
        );
        expect(find.textContaining('Description'), findsNothing);
        expect(find.textContaining('Assignee'), findsNothing);
        expect(
          find.byKey(const Key('todo-quick-create-apiary-chip')),
          findsNothing,
        );
      },
    );

    testWidgets('priority defaults to Medium', (tester) async {
      final repo = _FakeTodosRepository();
      await _openSheet(tester, repo: repo);

      await tester.enterText(
        find.byKey(const Key('todo-quick-create-title-field')),
        'Inspect hive 3',
      );
      await tester.tap(find.byKey(const Key('todo-quick-create-save-button')));
      await tester.pumpAndSettle();

      expect(repo.created.single.priority, todoPriorityMedium);
    });
  });

  group('validation', () {
    testWidgets('an empty title blocks save — create() is never called', (
      tester,
    ) async {
      final repo = _FakeTodosRepository();
      await _openSheet(tester, repo: repo);

      await tester.tap(find.byKey(const Key('todo-quick-create-save-button')));
      await tester.pumpAndSettle();

      expect(repo.created, isEmpty);
      expect(find.text('Title is required'), findsOneWidget);
    });
  });

  group('save (offline-first: goes through TodosRepository.create())', () {
    testWidgets(
      'a valid save with no due date calls create() with apiaryId: null, '
      'dueDate: null',
      (tester) async {
        final repo = _FakeTodosRepository();
        await _openSheet(tester, repo: repo);

        await tester.enterText(
          find.byKey(const Key('todo-quick-create-title-field')),
          'Inspect hive 3',
        );
        await tester.tap(
          find.byKey(const Key('todo-quick-create-save-button')),
        );
        await tester.pumpAndSettle();

        expect(repo.created, hasLength(1));
        expect(repo.created.single.title, 'Inspect hive 3');
        expect(repo.created.single.dueDate, isNull);
        expect(repo.created.single.apiaryId, isNull);
      },
    );

    testWidgets('picking a due date passes it as plain YYYY-MM-DD', (
      tester,
    ) async {
      final repo = _FakeTodosRepository();
      await _openSheet(tester, repo: repo);

      await tester.enterText(
        find.byKey(const Key('todo-quick-create-title-field')),
        'Order syrup',
      );
      await tester.tap(
        find.byKey(const Key('todo-quick-create-due-date-field')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('todo-quick-create-save-button')));
      await tester.pumpAndSettle();

      expect(repo.created, hasLength(1));
      expect(repo.created.single.dueDate, _isoDate(DateTime.now()));
    });

    testWidgets('clearing a picked due date drops it back to null on save', (
      tester,
    ) async {
      final repo = _FakeTodosRepository();
      await _openSheet(tester, repo: repo);

      await tester.enterText(
        find.byKey(const Key('todo-quick-create-title-field')),
        'Order syrup',
      );
      await tester.tap(
        find.byKey(const Key('todo-quick-create-due-date-field')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('todo-quick-create-due-date-clear-button')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('todo-quick-create-due-date-clear-button')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('todo-quick-create-save-button')));
      await tester.pumpAndSettle();

      expect(repo.created.single.dueDate, isNull);
    });

    testWidgets(
      'a pre-filled apiary shows the "For {name}" chip and create() is '
      'called with that apiaryId (#52, FR-UX-2 contextual create)',
      (tester) async {
        final repo = _FakeTodosRepository();
        await _openSheet(
          tester,
          repo: repo,
          initialApiaryId: 'a1',
          initialApiaryName: 'Serra Norte',
        );

        expect(
          find.byKey(const Key('todo-quick-create-apiary-chip')),
          findsOneWidget,
        );
        expect(find.textContaining('Serra Norte'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('todo-quick-create-title-field')),
          'Check queen',
        );
        await tester.tap(
          find.byKey(const Key('todo-quick-create-save-button')),
        );
        await tester.pumpAndSettle();

        expect(repo.created, hasLength(1));
        expect(repo.created.single.apiaryId, 'a1');
      },
    );
  });

  group('error handling', () {
    testWidgets(
      'a failing create() shows an error SnackBar and keeps the sheet open, '
      'not an indefinite spinner',
      (tester) async {
        final repo = _FakeTodosRepository(throwOnCreate: true);
        await _openSheet(tester, repo: repo);

        await tester.enterText(
          find.byKey(const Key('todo-quick-create-title-field')),
          'Doomed todo',
        );
        await tester.tap(
          find.byKey(const Key('todo-quick-create-save-button')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(repo.created, isEmpty);
        expect(
          find.byKey(const Key('todo-quick-create-save-button')),
          findsOneWidget,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining("Couldn't save the todo"), findsOneWidget);
      },
    );
  });

  group('cancel', () {
    testWidgets('tapping cancel pops the sheet and create() is never called', (
      tester,
    ) async {
      final repo = _FakeTodosRepository();
      await _openSheet(tester, repo: repo);

      await tester.tap(
        find.byKey(const Key('todo-quick-create-cancel-button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('todo-quick-create-title-field')),
        findsNothing,
      );
      expect(repo.created, isEmpty);
    });
  });

  group('accessibility (FR-UX-1: large, gloves-friendly tap targets)', () {
    testWidgets(
      'the save button is the 56px field-action height and the cancel '
      'button meets the 44px minimum',
      (tester) async {
        final repo = _FakeTodosRepository();
        await _openSheet(tester, repo: repo);

        final saveSize = tester.getSize(
          find.byKey(const Key('todo-quick-create-save-button')),
        );
        expect(saveSize.height, greaterThanOrEqualTo(56));

        expectMinTapTarget(
          tester,
          find.byKey(const Key('todo-quick-create-cancel-button')),
        );
      },
    );
  });
}
