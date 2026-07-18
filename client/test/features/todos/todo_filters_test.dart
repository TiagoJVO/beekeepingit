import 'package:beekeepingit_client/features/todos/todo_filters.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// A fixed "today" for every test — Wednesday, 2026-06-10 — so date-relative
// assertions (overdue/due-today/due-this-week/due-this-month) never depend
// on the wall clock the suite happens to run under.
final _today = DateTime(2026, 6, 10);

Todo _todo(
  String id, {
  String title = 'x',
  String priority = todoPriorityLow,
  String status = 'open',
  String? dueDate,
  String? completedAt,
}) => Todo(
  id: id,
  title: title,
  priority: priority,
  status: status,
  dueDate: dueDate,
  completedAt: completedAt,
);

void main() {
  group('isOverdue (#53 AC: distinguishes open, completed, overdue)', () {
    test('an open todo with a past due date is overdue', () {
      final todo = _todo('1', status: 'open', dueDate: '2026-06-01');
      expect(isOverdue(todo, _today), isTrue);
    });

    test('a done todo is never overdue, regardless of due date', () {
      final todo = _todo(
        '1',
        status: 'done',
        dueDate: '2026-06-01',
        completedAt: '2026-06-05T00:00:00Z',
      );
      expect(isOverdue(todo, _today), isFalse);
    });

    test('an open todo due exactly today is not overdue', () {
      final todo = _todo('1', status: 'open', dueDate: '2026-06-10');
      expect(isOverdue(todo, _today), isFalse);
    });

    test('an open todo due in the future is not overdue', () {
      final todo = _todo('1', status: 'open', dueDate: '2026-06-11');
      expect(isOverdue(todo, _today), isFalse);
    });

    test('an open todo with no due date is not overdue', () {
      final todo = _todo('1', status: 'open', dueDate: null);
      expect(isOverdue(todo, _today), isFalse);
    });
  });

  group('filterTodosByStatus (#53 AC: filterable by status)', () {
    final open = _todo('open', status: 'open', dueDate: '2026-06-20');
    final overdue = _todo('overdue', status: 'open', dueDate: '2026-06-01');
    final done = _todo(
      'done',
      status: 'done',
      dueDate: '2026-06-01',
      completedAt: '2026-06-05T00:00:00Z',
    );
    final todos = [open, overdue, done];

    test('TodoStatusFilter.all is a passthrough', () {
      expect(filterTodosByStatus(todos, TodoStatusFilter.all, _today), todos);
    });

    test('TodoStatusFilter.open keeps only non-overdue, non-done todos', () {
      final result = filterTodosByStatus(todos, TodoStatusFilter.open, _today);
      expect(result.map((t) => t.id).toList(), ['open']);
    });

    test('TodoStatusFilter.overdue keeps only overdue todos', () {
      final result = filterTodosByStatus(
        todos,
        TodoStatusFilter.overdue,
        _today,
      );
      expect(result.map((t) => t.id).toList(), ['overdue']);
    });

    test('TodoStatusFilter.done keeps only done todos, even ones with a '
        'past due date', () {
      final result = filterTodosByStatus(todos, TodoStatusFilter.done, _today);
      expect(result.map((t) => t.id).toList(), ['done']);
    });
  });

  group('filterTodosByPriority (#53 AC: filterable by priority level)', () {
    test('a null priority is a passthrough (the "all priorities" default)', () {
      final todos = [
        _todo('1', priority: todoPriorityHigh),
        _todo('2', priority: todoPriorityLow),
      ];
      expect(filterTodosByPriority(todos, null), todos);
    });

    test('keeps only todos of the given priority', () {
      final todos = [
        _todo('1', priority: todoPriorityHigh),
        _todo('2', priority: todoPriorityLow),
        _todo('3', priority: todoPriorityHigh),
      ];
      final result = filterTodosByPriority(todos, todoPriorityHigh);
      expect(result.map((t) => t.id).toList(), ['1', '3']);
    });

    test('a priority matching nothing returns an empty list', () {
      final todos = [_todo('1', priority: todoPriorityLow)];
      expect(filterTodosByPriority(todos, todoPriorityHigh), isEmpty);
    });
  });

  group('filterTodosByDue (#53 AC: filterable by due date)', () {
    final noDue = _todo('no-due', dueDate: null);
    final dueToday = _todo('due-today', dueDate: '2026-06-10');
    final dueTomorrow = _todo('due-tomorrow', dueDate: '2026-06-11');
    // 2026-06-10 is a Wednesday; the containing week is Mon 2026-06-08 ..
    // Sun 2026-06-14.
    final dueEndOfWeek = _todo('due-end-of-week', dueDate: '2026-06-14');
    final dueNextWeek = _todo('due-next-week', dueDate: '2026-06-16');
    final dueEndOfMonth = _todo('due-end-of-month', dueDate: '2026-06-30');
    final dueNextMonth = _todo('due-next-month', dueDate: '2026-07-01');
    final overdueEarlierThisWeek = _todo(
      'overdue-this-week',
      dueDate: '2026-06-09',
    );
    final todos = [
      noDue,
      dueToday,
      dueTomorrow,
      dueEndOfWeek,
      dueNextWeek,
      dueEndOfMonth,
      dueNextMonth,
      overdueEarlierThisWeek,
    ];

    test('TodoDueFilter.any is a passthrough', () {
      expect(filterTodosByDue(todos, TodoDueFilter.any, _today), todos);
    });

    test('TodoDueFilter.today keeps only todos due exactly today', () {
      final result = filterTodosByDue(todos, TodoDueFilter.today, _today);
      expect(result.map((t) => t.id).toList(), ['due-today']);
    });

    test('TodoDueFilter.thisWeek keeps todos due within the current calendar '
        'week (Monday-Sunday), including an already-overdue one earlier this '
        'week, excluding a null due date', () {
      final result = filterTodosByDue(todos, TodoDueFilter.thisWeek, _today);
      expect(result.map((t) => t.id).toSet(), {
        'due-today',
        'due-tomorrow',
        'due-end-of-week',
        'overdue-this-week',
      });
    });

    test('TodoDueFilter.thisMonth keeps todos due within the current calendar '
        'month, excluding a null due date', () {
      final result = filterTodosByDue(todos, TodoDueFilter.thisMonth, _today);
      expect(result.map((t) => t.id).toSet(), {
        'due-today',
        'due-tomorrow',
        'due-end-of-week',
        'due-next-week',
        'due-end-of-month',
        'overdue-this-week',
      });
    });

    test('a null due date never matches any preset', () {
      expect(filterTodosByDue([noDue], TodoDueFilter.today, _today), isEmpty);
      expect(
        filterTodosByDue([noDue], TodoDueFilter.thisWeek, _today),
        isEmpty,
      );
      expect(
        filterTodosByDue([noDue], TodoDueFilter.thisMonth, _today),
        isEmpty,
      );
    });
  });

  group('filterTodos — combined (#53 AC: filterable by due date, priority and '
      'status)', () {
    test('applies status, priority and due filters together', () {
      final todos = [
        _todo(
          'match',
          status: 'open',
          priority: todoPriorityHigh,
          dueDate: '2026-06-10',
        ),
        // Right priority/due, wrong status (overdue, not "open" bucket).
        _todo(
          'wrong-status',
          status: 'open',
          priority: todoPriorityHigh,
          dueDate: '2026-06-01',
        ),
        // Right status/due, wrong priority.
        _todo(
          'wrong-priority',
          status: 'open',
          priority: todoPriorityLow,
          dueDate: '2026-06-10',
        ),
      ];

      final result = filterTodos(
        todos,
        status: TodoStatusFilter.open,
        priority: todoPriorityHigh,
        due: TodoDueFilter.today,
        today: _today,
      );

      expect(result.map((t) => t.id).toList(), ['match']);
    });

    test('with every filter left at its default, returns every todo '
        'unchanged', () {
      final todos = [
        _todo('1', dueDate: '2026-06-10'),
        _todo('2', dueDate: '2020-01-01'),
      ];
      expect(filterTodos(todos, today: _today), todos);
    });

    test('a combination matching nothing returns an empty list (no-results '
        'state)', () {
      final todos = [_todo('1', status: 'open', priority: todoPriorityHigh)];
      final result = filterTodos(
        todos,
        status: TodoStatusFilter.done,
        today: _today,
      );
      expect(result, isEmpty);
    });
  });

  group('sortTodos — due date (#53 AC: sortable by due date)', () {
    test('ascending: soonest/overdue first, null due dates last', () {
      final todos = [
        _todo('no-due', dueDate: null),
        _todo('later', dueDate: '2026-06-20'),
        _todo('overdue', dueDate: '2026-06-01'),
        _todo('sooner', dueDate: '2026-06-11'),
      ];

      final result = sortTodos(
        todos,
        field: TodoSortField.dueDate,
        direction: SortDirection.ascending,
        today: _today,
      );

      expect(result.map((t) => t.id).toList(), [
        'overdue',
        'sooner',
        'later',
        'no-due',
      ]);
    });

    test('descending: latest first, null due dates still last', () {
      final todos = [
        _todo('no-due', dueDate: null),
        _todo('later', dueDate: '2026-06-20'),
        _todo('overdue', dueDate: '2026-06-01'),
        _todo('sooner', dueDate: '2026-06-11'),
      ];

      final result = sortTodos(
        todos,
        field: TodoSortField.dueDate,
        direction: SortDirection.descending,
        today: _today,
      );

      expect(result.map((t) => t.id).toList(), [
        'later',
        'sooner',
        'overdue',
        'no-due',
      ]);
    });
  });

  group('sortTodos — priority (#53 AC: sortable by priority level)', () {
    test('descending (the field\'s own default direction): high -> low', () {
      final todos = [
        _todo('low', priority: todoPriorityLow),
        _todo('high', priority: todoPriorityHigh),
        _todo('medium', priority: todoPriorityMedium),
      ];

      final result = sortTodos(
        todos,
        field: TodoSortField.priority,
        direction: SortDirection.descending,
        today: _today,
      );

      expect(result.map((t) => t.id).toList(), ['high', 'medium', 'low']);
    });

    test('ascending: low -> high', () {
      final todos = [
        _todo('low', priority: todoPriorityLow),
        _todo('high', priority: todoPriorityHigh),
        _todo('medium', priority: todoPriorityMedium),
      ];

      final result = sortTodos(
        todos,
        field: TodoSortField.priority,
        direction: SortDirection.ascending,
        today: _today,
      );

      expect(result.map((t) => t.id).toList(), ['low', 'medium', 'high']);
    });
  });

  group('sortTodos — status (#53 AC: sortable by status)', () {
    test('ascending (the field\'s own default direction) follows the fixed '
        'lifecycle order: overdue -> open -> done', () {
      final todos = [
        _todo(
          'done',
          status: 'done',
          dueDate: '2026-06-01',
          completedAt: '2026-06-05T00:00:00Z',
        ),
        _todo('open', status: 'open', dueDate: '2026-06-20'),
        _todo('overdue', status: 'open', dueDate: '2026-06-01'),
      ];

      final result = sortTodos(
        todos,
        field: TodoSortField.status,
        direction: SortDirection.ascending,
        today: _today,
      );

      expect(result.map((t) => t.id).toList(), ['overdue', 'open', 'done']);
    });

    test(
      'descending reverses the lifecycle order: done -> open -> overdue',
      () {
        final todos = [
          _todo(
            'done',
            status: 'done',
            dueDate: '2026-06-01',
            completedAt: '2026-06-05T00:00:00Z',
          ),
          _todo('open', status: 'open', dueDate: '2026-06-20'),
          _todo('overdue', status: 'open', dueDate: '2026-06-01'),
        ];

        final result = sortTodos(
          todos,
          field: TodoSortField.status,
          direction: SortDirection.descending,
          today: _today,
        );

        expect(result.map((t) => t.id).toList(), ['done', 'open', 'overdue']);
      },
    );
  });

  group('defaultSortDirectionFor (#53 — per-field sensible defaults)', () {
    test('due date defaults to ascending (soonest/overdue first)', () {
      expect(
        defaultSortDirectionFor(TodoSortField.dueDate),
        SortDirection.ascending,
      );
    });

    test('priority defaults to descending (high -> low)', () {
      expect(
        defaultSortDirectionFor(TodoSortField.priority),
        SortDirection.descending,
      );
    });

    test('status defaults to ascending (overdue -> open -> done)', () {
      expect(
        defaultSortDirectionFor(TodoSortField.status),
        SortDirection.ascending,
      );
    });
  });

  group('TodosViewModel construction (#53 — empty vs. no-results states)', () {
    test('hasAnyTodos/filtered/today are independently settable', () {
      final vm = TodosViewModel(
        hasAnyTodos: true,
        filtered: const [],
        today: _today,
      );
      expect(vm.hasAnyTodos, isTrue);
      expect(vm.filtered, isEmpty);
      expect(vm.today, _today);
    });
  });
}
