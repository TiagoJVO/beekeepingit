import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/home/home_summary.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/todos/todo_due.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// A fixed "now" for every test — 2026-06-10, mid-morning — so the
// date-relative assertions never depend on the wall clock the suite runs
// under (the same convention as apiary_visit_recency_test.dart's own `_now`).
final _now = DateTime(2026, 6, 10, 9, 30);

/// [d] as the plain `YYYY-MM-DD` string a `due_date`/`occurred_at` column
/// actually stores.
String _ymd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

String _daysFromNow(int days) => _ymd(_now.add(Duration(days: days)));

String _daysAgo(int days) => _daysFromNow(-days);

Todo _todo(
  String id, {
  String? dueDate,
  String priority = todoPriorityMedium,
  String status = 'open',
}) => Todo(
  id: id,
  title: 'Todo $id',
  priority: priority,
  status: status,
  dueDate: dueDate,
);

Journey _journey(String id, {String status = journeyStatusOpen}) => Journey(
  id: id,
  name: 'Journey $id',
  mainActivityType: 'inspection',
  status: status,
);

Apiary _apiary(String id, {String? name}) =>
    Apiary(id: id, name: name ?? 'Apiary $id', hiveCount: 0);

Activity _activity(String id, {required String apiaryId, required String on}) =>
    Activity(
      id: id,
      apiaryId: apiaryId,
      type: 'inspection',
      occurredAt: on,
      attributes: const {},
    );

HomeSummary _summary({
  List<Todo> todos = const [],
  List<Journey> journeys = const [],
  List<Apiary> apiaries = const [],
  List<Activity> activities = const [],
  DateTime? now,
  HomeDataReadiness readiness = HomeDataReadiness.ready,
}) => buildHomeSummary(
  todos: todos,
  journeys: journeys,
  apiaries: apiaries,
  activities: activities,
  readiness: readiness,
  now: now ?? _now,
);

void main() {
  group('kHomePreviewLimit', () {
    test('is 3 — three sections plus headers fit above the fold at 375px', () {
      expect(kHomePreviewLimit, 3);
    });
  });

  group('attention todos', () {
    test('is every todo todoDueBucket() buckets, and nothing else', () {
      final overdue = _todo('overdue', dueDate: _daysAgo(1));
      final dueToday = _todo('today', dueDate: _daysFromNow(0));
      final farOut = _todo(
        'far',
        dueDate: _daysFromNow(9),
        priority: todoPriorityHigh,
      );
      final noDueDate = _todo('none');

      final summary = _summary(
        todos: [overdue, dueToday, farOut, noDueDate],
        apiaries: [_apiary('A')],
        activities: [_activity('x', apiaryId: 'A', on: _daysAgo(1))],
      );

      expect(summary.attentionTodos.preview.map((t) => t.todo.id), [
        'overdue',
        'today',
      ]);
      expect(summary.attentionTodos.count, 2);
    });

    test('excludes done todos even when their due date has passed', () {
      final summary = _summary(
        todos: [_todo('done', dueDate: _daysAgo(5), status: 'done')],
        apiaries: [_apiary('A')],
        activities: [_activity('x', apiaryId: 'A', on: _daysAgo(1))],
      );

      expect(summary.attentionTodos.count, 0);
      expect(summary.attentionTodos.preview, isEmpty);
    });

    test('carries each bucket, so no widget re-reads the clock', () {
      final summary = _summary(
        todos: [
          _todo('a', dueDate: _daysAgo(1)),
          _todo('b', dueDate: _daysFromNow(0)),
        ],
      );

      expect(summary.attentionTodos.preview.map((t) => t.bucket), [
        TodoDueBucket.overdue,
        TodoDueBucket.dueSoon,
      ]);
    });

    test('orders overdue before due-soon, then by due date ascending', () {
      final summary = _summary(
        todos: [
          _todo(
            'soon-later',
            dueDate: _daysFromNow(2),
            priority: todoPriorityHigh,
          ),
          _todo('soon-sooner', dueDate: _daysFromNow(0)),
          _todo('overdue-recent', dueDate: _daysAgo(1)),
          _todo('overdue-oldest', dueDate: _daysAgo(30)),
        ],
      );

      expect(summary.attentionTodos.preview.map((t) => t.todo.id), [
        'overdue-oldest',
        'overdue-recent',
        'soon-sooner',
      ]);
      expect(summary.attentionTodos.count, 4);
    });

    test('breaks a same-due-date tie by priority, most urgent first', () {
      final summary = _summary(
        todos: [
          _todo('low', dueDate: _daysAgo(1), priority: todoPriorityLow),
          _todo('high', dueDate: _daysAgo(1), priority: todoPriorityHigh),
          _todo('medium', dueDate: _daysAgo(1), priority: todoPriorityMedium),
        ],
      );

      expect(summary.attentionTodos.preview.map((t) => t.todo.id), [
        'high',
        'medium',
        'low',
      ]);
    });

    test('counts the full match set while the preview caps at 3', () {
      final summary = _summary(
        todos: [
          for (var i = 0; i < 5; i++) _todo('t$i', dueDate: _daysAgo(10 - i)),
        ],
      );

      expect(summary.attentionTodos.count, 5);
      expect(summary.attentionTodos.preview, hasLength(kHomePreviewLimit));
      expect(summary.attentionTodos.preview.map((t) => t.todo.id), [
        't0',
        't1',
        't2',
      ]);
      expect(summary.attentionTodos.hasMore, isTrue);
    });
  });

  group('open journeys', () {
    test('excludes closed journeys', () {
      final summary = _summary(
        journeys: [
          _journey('open'),
          _journey('closed', status: journeyStatusClosed),
        ],
      );

      expect(summary.openJourneys.preview.map((j) => j.id), ['open']);
      expect(summary.openJourneys.count, 1);
    });

    test(
      'preserves the incoming order — already newest-first from watchAll',
      () {
        final summary = _summary(
          journeys: [
            _journey('newest'),
            _journey('middle'),
            _journey('oldest'),
          ],
        );

        expect(summary.openJourneys.preview.map((j) => j.id), [
          'newest',
          'middle',
          'oldest',
        ]);
      },
    );

    test('counts the full match set while the preview caps at 3', () {
      final summary = _summary(
        journeys: [for (var i = 0; i < 5; i++) _journey('j$i')],
      );

      expect(summary.openJourneys.count, 5);
      expect(summary.openJourneys.preview.map((j) => j.id), ['j0', 'j1', 'j2']);
      expect(summary.openJourneys.hasMore, isTrue);
    });
  });

  group('stale apiaries', () {
    test('keeps apiariesNotVisitedSince order: never-visited first', () {
      final summary = _summary(
        apiaries: [
          _apiary('stale', name: 'Stale'),
          _apiary('never', name: 'Never'),
          _apiary('fresh', name: 'Fresh'),
        ],
        activities: [
          _activity('a1', apiaryId: 'stale', on: _daysAgo(40)),
          _activity('a2', apiaryId: 'fresh', on: _daysAgo(2)),
        ],
      );

      expect(summary.staleApiaries.preview.map((a) => a.apiary.id), [
        'never',
        'stale',
      ]);
      expect(summary.staleApiaries.count, 2);
      expect(summary.staleApiaries.preview.first.neverVisited, isTrue);
      expect(summary.staleApiaries.preview.last.daysSinceLastVisit, 40);
    });

    test('counts the full match set while the preview caps at 3', () {
      final summary = _summary(
        apiaries: [for (var i = 0; i < 5; i++) _apiary('ap$i', name: 'Ap $i')],
      );

      expect(summary.staleApiaries.count, 5);
      expect(summary.staleApiaries.preview, hasLength(kHomePreviewLimit));
      expect(summary.staleApiaries.hasMore, isTrue);
    });
  });

  // The overdue half of the tasks section, counted over the full match set.
  // The section is the UNION of overdue and due-soon, but its "view all"
  // link opens only `/todos?status=overdue` until #661 lets the Todos tab
  // express the union — so the link is labelled from this, not from
  // `attentionTodos.count`.
  group('overdueTodoCount (#658 review, #661)', () {
    test('is zero when every attention todo is merely due soon', () {
      final summary = _summary(
        todos: [
          _todo('a', dueDate: _daysFromNow(0), priority: todoPriorityHigh),
          _todo('b', dueDate: _daysFromNow(1), priority: todoPriorityHigh),
        ],
      );

      expect(summary.attentionTodos.count, 2);
      expect(summary.overdueTodoCount, 0);
    });

    test('counts only the overdue half of a mixed section', () {
      final summary = _summary(
        todos: [
          _todo('late-1', dueDate: _daysAgo(2)),
          _todo('late-2', dueDate: _daysAgo(8)),
          _todo('soon', dueDate: _daysFromNow(0), priority: todoPriorityHigh),
        ],
      );

      expect(summary.attentionTodos.count, 3);
      expect(summary.overdueTodoCount, 2);
    });

    test('counts past the preview cap, not just the rendered rows', () {
      final summary = _summary(
        todos: [
          for (var i = 1; i <= 6; i++) _todo('late-$i', dueDate: _daysAgo(i)),
        ],
      );

      expect(summary.attentionTodos.preview.length, kHomePreviewLimit);
      expect(summary.overdueTodoCount, 6);
    });
  });

  group('state', () {
    test('firstRun when the org has nothing at all', () {
      final summary = _summary();

      expect(summary.state, HomeSummaryState.firstRun);
      expect(summary.attentionTodos.count, 0);
      expect(summary.openJourneys.count, 0);
      expect(summary.staleApiaries.count, 0);
    });

    test('allClear with one recently-visited apiary and nothing due', () {
      final summary = _summary(
        apiaries: [_apiary('A')],
        activities: [_activity('x', apiaryId: 'A', on: _daysAgo(1))],
      );

      expect(summary.state, HomeSummaryState.allClear);
    });

    test('allClear when the only data is done todos and closed journeys', () {
      final summary = _summary(
        todos: [_todo('t', dueDate: _daysAgo(3), status: 'done')],
        journeys: [_journey('j', status: journeyStatusClosed)],
      );

      expect(summary.state, HomeSummaryState.allClear);
    });

    test('needsAttention from the todos section alone', () {
      final summary = _summary(todos: [_todo('t', dueDate: _daysAgo(1))]);

      expect(summary.state, HomeSummaryState.needsAttention);
    });

    test('needsAttention from the journeys section alone', () {
      final summary = _summary(journeys: [_journey('j')]);

      expect(summary.state, HomeSummaryState.needsAttention);
    });

    test('needsAttention from the apiaries section alone', () {
      final summary = _summary(apiaries: [_apiary('A')]);

      expect(summary.state, HomeSummaryState.needsAttention);
    });

    test('a due-today todo is dueSoon, so needsAttention — not allClear', () {
      final summary = _summary(
        todos: [_todo('t', dueDate: _daysFromNow(0))],
        apiaries: [_apiary('A')],
        activities: [_activity('x', apiaryId: 'A', on: _daysAgo(1))],
      );

      expect(
        summary.attentionTodos.preview.single.bucket,
        TodoDueBucket.dueSoon,
      );
      expect(summary.state, HomeSummaryState.needsAttention);
    });

    test('the three states are mutually exclusive across the fixtures', () {
      final states = <HomeSummaryState>{
        _summary().state,
        _summary(
          apiaries: [_apiary('A')],
          activities: [_activity('x', apiaryId: 'A', on: _daysAgo(1))],
        ).state,
        _summary(todos: [_todo('t', dueDate: _daysAgo(1))]).state,
      };

      expect(states, {
        HomeSummaryState.firstRun,
        HomeSummaryState.allClear,
        HomeSummaryState.needsAttention,
      });
    });
  });

  group('a single now drives every section', () {
    // The midnight-straddle guard: this fixture answers DIFFERENTLY on
    // 2026-06-10 than on 2026-06-11 in BOTH the todos and the apiaries
    // section, so two separate clock reads either side of midnight would
    // produce a self-contradictory summary.
    final todos = [
      // Due 06-10: dueSoon on the 10th, overdue on the 11th.
      _todo('due-today', dueDate: '2026-06-10', priority: todoPriorityLow),
      // Due 06-12, low priority (1-day window): out of window on the 10th,
      // dueSoon on the 11th.
      _todo('due-friday', dueDate: '2026-06-12', priority: todoPriorityLow),
    ];
    final apiaries = [_apiary('A', name: 'A')];
    // Last visited 2026-05-12: 29 days before the 10th (fresh), exactly 30
    // before the 11th (stale — the recency boundary is inclusive).
    final activities = [_activity('x', apiaryId: 'A', on: '2026-05-12')];

    test('carries the now it was built from', () {
      final now = DateTime(2026, 6, 10, 23, 59, 59);
      final summary = _summary(
        todos: todos,
        apiaries: apiaries,
        activities: activities,
        now: now,
      );

      expect(summary.now, now);
    });

    test('a second before midnight, every section reads 2026-06-10', () {
      final summary = _summary(
        todos: todos,
        apiaries: apiaries,
        activities: activities,
        now: DateTime(2026, 6, 10, 23, 59, 59),
      );

      expect(summary.attentionTodos.preview.map((t) => t.todo.id), [
        'due-today',
      ]);
      expect(
        summary.attentionTodos.preview.single.bucket,
        TodoDueBucket.dueSoon,
      );
      expect(summary.staleApiaries.count, 0);
    });

    test('a second after midnight, every section reads 2026-06-11', () {
      final summary = _summary(
        todos: todos,
        apiaries: apiaries,
        activities: activities,
        now: DateTime(2026, 6, 11, 0, 0, 1),
      );

      expect(summary.attentionTodos.preview.map((t) => t.todo.id), [
        'due-today',
        'due-friday',
      ]);
      expect(
        summary.attentionTodos.preview.first.bucket,
        TodoDueBucket.overdue,
      );
      expect(summary.attentionTodos.preview.last.bucket, TodoDueBucket.dueSoon);
      expect(summary.staleApiaries.preview.single.daysSinceLastVisit, 30);
    });
  });
}
