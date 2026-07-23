import 'dart:async';

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixtures mirroring activities_list_screen_test.dart's own (file-private
/// there, so re-declared here).
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
final _yesterday = _today.subtract(const Duration(days: 1));
final _tomorrow = _today.add(const Duration(days: 1));

Todo _todo(
  String id, {
  String title = 'Todo',
  String priority = todoPriorityLow,
  String status = 'open',
  String? dueDate,
  String? completedAt,
  String? organizationId = 'test-org',
}) => Todo(
  id: id,
  title: title,
  priority: priority,
  status: status,
  dueDate: dueDate,
  completedAt: completedAt,
  organizationId: organizationId,
);

Widget _buildApp({required List<Todo> todos}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(const [])),
      todosStreamProvider.overrideWith((ref) => Stream.value(todos)),
      // The full create form's assignee picker (#293, reachable from the
      // FAB since #389 retired #52's quick-create sheet) watches
      // memberNamesProvider — overridden so it doesn't attempt a real
      // fetch.
      memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openTodosTab(
  WidgetTester tester, {
  required List<Todo> todos,
}) async {
  await tester.pumpWidget(_buildApp(todos: todos));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('shell-tab-todos')));
  await tester.pumpAndSettle();
}

/// A no-op [LocalStoreEngine] — [_FakeTodosRepository] overrides every
/// method the full create form touches, so the superclass's store is never
/// actually used. Mirrors todo_form_screen_test.dart's own identical
/// fixture (kept file-private per this suite's own convention).
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

/// A live [TodosRepository] fake (#52's own "appears immediately"
/// offline-first AC) — unlike the read-only fixed lists [_buildApp] above
/// overrides [todosStreamProvider] with directly, this one drives
/// [watchAll] off its own in-memory list, so a `create()` call (from the
/// full create form's save button, #389) is immediately reflected back
/// through the SAME [todosStreamProvider]/[todosViewModelProvider] chain
/// the real app uses — proving the new todo appears in the list without a
/// real PowerSync round-trip, exactly like the local-first write path it
/// mirrors (todos_repository.dart's own doc: every write is queued for
/// sync, but visible locally immediately).
class _FakeTodosRepository extends TodosRepository {
  _FakeTodosRepository() : super(_NoopLocalStore());

  final List<Todo> _created = [];
  final _controller = StreamController<List<Todo>>.broadcast();

  @override
  Future<String> create({
    required String title,
    required String priority,
    String? description,
    String? dueDate,
    String? assigneeId,
    String? apiaryId,
  }) async {
    final todo = Todo(
      id: 'fake-${_created.length}',
      title: title,
      priority: priority,
      status: 'open',
      dueDate: dueDate,
      apiaryId: apiaryId,
      organizationId: 'test-org',
    );
    _created.add(todo);
    _controller.add(List.of(_created));
    return todo.id;
  }

  @override
  Stream<List<Todo>> watchAll({required String? organizationId}) async* {
    yield List.of(_created);
    yield* _controller.stream;
  }
}

Widget _buildAppWithRepo({required _FakeTodosRepository repo}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(const [])),
      todosRepositoryProvider.overrideWith((ref) async => repo),
      // The full create form's assignee picker (#293, reachable from the
      // FAB since #389 retired #52's quick-create sheet) watches
      // memberNamesProvider — overridden so it doesn't attempt a real
      // fetch, matching this file's own `todoByIdProvider` test above.
      memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

/// Every rendered todo row's title, in the order the list lays them out —
/// the branded row cards (`BrandCard`, todo_list_widgets.dart) carry their
/// title as a plain descendant [Text] rather than a `ListTile.title`, so
/// render order is read off each row's vertical offset. Replaces the old
/// `widgetList<ListTile>(...).map((t) => t.title)` sort assertion; the intent
/// (which todo renders before which) is unchanged.
List<String> _rowTitlesInOrder(WidgetTester tester) {
  final titles = <(double, String)>[];
  for (final element
      in find
          .descendant(
            of: find.byKey(const Key('todo-list')),
            matching: find.byType(Text),
          )
          .evaluate()) {
    final text = (element.widget as Text).data;
    if (text == null) continue;
    // Titles are bold (w700); the due-date/priority subtitle is not.
    if ((element.widget as Text).style?.fontWeight != FontWeight.w700) continue;
    titles.add((tester.getTopLeft(find.byWidget(element.widget)).dy, text));
  }
  titles.sort((a, b) => a.$1.compareTo(b.$1));
  return titles.map((e) => e.$2).toList();
}

void main() {
  group('main Todos tab (#53, FR-TD-1)', () {
    testWidgets('lists every todo in the org', (tester) async {
      await _openTodosTab(
        tester,
        todos: [
          _todo('1', title: 'Inspect hive 3'),
          _todo('2', title: 'Order syrup'),
        ],
      );

      expect(find.byKey(const Key('todo-1')), findsOneWidget);
      expect(find.byKey(const Key('todo-2')), findsOneWidget);
      expect(find.text('Inspect hive 3'), findsOneWidget);
      expect(find.text('Order syrup'), findsOneWidget);
    });

    testWidgets('shows the empty state when the org has no todos at all', (
      tester,
    ) async {
      await _openTodosTab(tester, todos: const []);

      expect(find.text('No todos yet.'), findsOneWidget);
    });

    testWidgets('tapping a todo row navigates to its detail (#293)', (
      tester,
    ) async {
      final todo = _todo('1', title: 'Inspect hive 3');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            apiariesStreamProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
            todosStreamProvider.overrideWith((ref) => Stream.value([todo])),
            todoByIdProvider.overrideWith(
              (ref, id) => Stream.value(id == todo.id ? todo : null),
            ),
            memberNamesProvider.overrideWith(
              (ref) async => const <String, String>{},
            ),
            profileProvider.overrideWith(_CompleteProfileController.new),
            organizationProvider.overrideWith(
              _ExistingOrganizationController.new,
            ),
          ],
          child: const BeekeepingitApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-tab-todos')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('todo-1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-detail-header')), findsOneWidget);
      expect(find.text('Inspect hive 3'), findsOneWidget);
    });

    testWidgets('shows an error state when the todos stream errors', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            apiariesStreamProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
            todosStreamProvider.overrideWith(
              (ref) => Stream<List<Todo>>.error('boom'),
            ),
            profileProvider.overrideWith(_CompleteProfileController.new),
            organizationProvider.overrideWith(
              _ExistingOrganizationController.new,
            ),
          ],
          child: const BeekeepingitApp(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-tab-todos')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not load todos'), findsOneWidget);
    });

    testWidgets(
      'renders offline: a not-yet-synced local row (null organizationId) '
      'still appears (FR-OF-1)',
      (tester) async {
        await _openTodosTab(
          tester,
          todos: [
            _todo('offline-1', title: 'Created offline', organizationId: null),
          ],
        );

        expect(find.byKey(const Key('todo-offline-1')), findsOneWidget);
        expect(find.text('Created offline'), findsOneWidget);
      },
    );

    group(
      'status distinction (#53 AC: distinguishes open/completed/overdue)',
      () {
        testWidgets('an overdue todo shows the Overdue badge', (tester) async {
          await _openTodosTab(
            tester,
            todos: [
              _todo('od', title: 'Late task', dueDate: _isoDate(_yesterday)),
            ],
          );

          expect(find.text('Overdue'), findsOneWidget);
        });

        testWidgets('a done todo shows a strikethrough title and no Overdue '
            'badge, even with a past due date', (tester) async {
          await _openTodosTab(
            tester,
            todos: [
              _todo(
                'done-1',
                title: 'Finished task',
                status: 'done',
                dueDate: _isoDate(_yesterday),
                completedAt: '2026-01-01T00:00:00Z',
              ),
            ],
          );

          final titleText = tester.widget<Text>(
            find.descendant(
              of: find.byKey(const Key('todo-done-1')),
              matching: find.text('Finished task'),
            ),
          );
          expect(titleText.style?.decoration, TextDecoration.lineThrough);
          expect(find.text('Overdue'), findsNothing);
        });

        testWidgets('an open, not-yet-due todo shows neither the Overdue '
            'badge nor a strikethrough title', (tester) async {
          await _openTodosTab(
            tester,
            todos: [
              _todo(
                'open-1',
                title: 'Future task',
                dueDate: _isoDate(_tomorrow),
              ),
            ],
          );

          expect(find.text('Overdue'), findsNothing);
          final titleText = tester.widget<Text>(
            find.descendant(
              of: find.byKey(const Key('todo-open-1')),
              matching: find.text('Future task'),
            ),
          );
          expect(
            titleText.style?.decoration,
            isNot(TextDecoration.lineThrough),
          );
        });
      },
    );

    group('status filter', () {
      testWidgets('selecting "Overdue" shows only overdue todos', (
        tester,
      ) async {
        await _openTodosTab(
          tester,
          todos: [
            _todo('od', title: 'Overdue one', dueDate: _isoDate(_yesterday)),
            _todo('open', title: 'Open one', dueDate: _isoDate(_tomorrow)),
          ],
        );

        await tester.tap(find.byKey(const Key('todo-filter-status-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Overdue').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('todo-od')), findsOneWidget);
        expect(find.byKey(const Key('todo-open')), findsNothing);
      });
    });

    group('priority filter', () {
      testWidgets('selecting "High" shows only high-priority todos', (
        tester,
      ) async {
        await _openTodosTab(
          tester,
          todos: [
            _todo('hi', title: 'Urgent', priority: todoPriorityHigh),
            _todo('lo', title: 'Whenever', priority: todoPriorityLow),
          ],
        );

        await tester.tap(find.byKey(const Key('todo-filter-priority-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('High').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('todo-hi')), findsOneWidget);
        expect(find.byKey(const Key('todo-lo')), findsNothing);
      });
    });

    group('due-date filter', () {
      testWidgets('selecting "Due today" shows only todos due today', (
        tester,
      ) async {
        await _openTodosTab(
          tester,
          todos: [
            _todo('today', title: 'Today task', dueDate: _isoDate(_today)),
            _todo(
              'tomorrow',
              title: 'Tomorrow task',
              dueDate: _isoDate(_tomorrow),
            ),
          ],
        );

        await tester.tap(find.byKey(const Key('todo-filter-due-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Due today').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('todo-today')), findsOneWidget);
        expect(find.byKey(const Key('todo-tomorrow')), findsNothing);
      });
    });

    testWidgets(
      'status, priority and due filters combine and the no-results state '
      'shows when nothing matches',
      (tester) async {
        await _openTodosTab(
          tester,
          todos: [
            _todo(
              'match',
              title: 'Match',
              priority: todoPriorityHigh,
              dueDate: _isoDate(_yesterday),
            ),
            _todo(
              'wrong-priority',
              title: 'Wrong priority',
              priority: todoPriorityLow,
              dueDate: _isoDate(_yesterday),
            ),
          ],
        );

        await tester.tap(find.byKey(const Key('todo-filter-status-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Overdue').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('todo-filter-priority-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('High').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('todo-match')), findsOneWidget);
        expect(find.byKey(const Key('todo-wrong-priority')), findsNothing);

        // Narrow further so nothing matches — the no-results state, not the
        // "org has zero todos" empty state.
        await tester.tap(find.byKey(const Key('todo-filter-priority-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Medium').last);
        await tester.pumpAndSettle();

        expect(find.text('No todos match your filters.'), findsOneWidget);
        expect(find.text('No todos yet.'), findsNothing);
      },
    );

    testWidgets('the clear-filters button resets status/priority/due but '
        'not the sort selection', (tester) async {
      await _openTodosTab(
        tester,
        todos: [
          _todo('hi', title: 'Urgent', priority: todoPriorityHigh),
          _todo('lo', title: 'Whenever', priority: todoPriorityLow),
        ],
      );

      await tester.tap(find.byKey(const Key('todo-filter-priority-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('High').last);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('todo-lo')), findsNothing);

      await tester.tap(find.byKey(const Key('todo-filter-clear-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-hi')), findsOneWidget);
      expect(find.byKey(const Key('todo-lo')), findsOneWidget);
    });

    group('sort (#53 AC: sortable by due date, priority, and status)', () {
      testWidgets(
        'sorting by priority (descending default) orders high before low',
        (tester) async {
          await _openTodosTab(
            tester,
            todos: [
              _todo('lo', title: 'Low one', priority: todoPriorityLow),
              _todo('hi', title: 'High one', priority: todoPriorityHigh),
            ],
          );

          await tester.tap(find.byKey(const Key('todo-sort-field-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Priority').last);
          await tester.pumpAndSettle();

          // Rows are branded cards (BrandCard), not ListTiles, so the render
          // order is asserted by each keyed row's vertical position rather
          // than by reading ListTile.title — same intent: high before low.
          expect(_rowTitlesInOrder(tester), ['High one', 'Low one']);
        },
      );

      testWidgets('toggling the sort direction reverses the order', (
        tester,
      ) async {
        await _openTodosTab(
          tester,
          todos: [
            _todo('lo', title: 'Low one', priority: todoPriorityLow),
            _todo('hi', title: 'High one', priority: todoPriorityHigh),
          ],
        );

        await tester.tap(find.byKey(const Key('todo-sort-field-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Priority').last);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('todo-sort-direction-button')));
        await tester.pumpAndSettle();

        expect(_rowTitlesInOrder(tester), ['Low one', 'High one']);
      });
    });
  });

  group('create (#52/#389, FR-TD-1, FR-UX-1)', () {
    testWidgets('the Todos tab shows a FAB labeled "New todo"', (tester) async {
      await _openTodosTab(tester, todos: const []);

      expect(find.byKey(const Key('shell-fab')), findsOneWidget);
      expect(find.text('New todo'), findsOneWidget);
    });

    testWidgets('tapping the FAB routes to the full create form (#389)', (
      tester,
    ) async {
      await _openTodosTab(tester, todos: const []);

      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
    });

    testWidgets(
      'completing create through the full form makes the new todo appear '
      'back in the list immediately (offline/local-store AC)',
      (tester) async {
        final repo = _FakeTodosRepository();
        await tester.pumpWidget(_buildAppWithRepo(repo: repo));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-tab-todos')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('shell-fab')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('todo-title-field')),
          'Inspect hive 3',
        );
        await tester.pump();
        // The full form's content exceeds the default 800x600 test
        // viewport (todo_form_screen_test.dart's own note) — scroll the
        // save button into view rather than resizing the viewport, since
        // this suite's other tests share the same default size.
        await tester.ensureVisible(find.byKey(const Key('todo-save-button')));
        await tester.tap(find.byKey(const Key('todo-save-button')));
        // Not pumpAndSettle: a successful save navigates to the new todo's
        // own detail route, whose `todoByIdProvider` watch never resolves
        // in this PowerSync-less environment (this fake repository doesn't
        // override `watchById`) — mirrors todo_form_screen_test.dart's own
        // documented `_pumpBounded` workaround.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        // The shell's own back button pops from the detail route back to
        // the list — independent of the detail screen's own (still
        // loading) data watch, same as the header-back test elsewhere in
        // this suite.
        await tester.tap(find.byKey(const Key('shell-back-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('todo-fake-0')), findsOneWidget);
        expect(find.text('Inspect hive 3'), findsOneWidget);
      },
    );
  });
}
