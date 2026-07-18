import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
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

          final tiles = tester
              .widgetList<ListTile>(find.byType(ListTile))
              .toList();
          final titles = tiles.map((t) => (t.title! as Text).data).toList();
          expect(titles, ['High one', 'Low one']);
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

        final tiles = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .toList();
        final titles = tiles.map((t) => (t.title! as Text).data).toList();
        expect(titles, ['Low one', 'High one']);
      });
    });
  });
}
