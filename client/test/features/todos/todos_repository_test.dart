import 'dart:async';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalStoreEngine] fake purpose-built to interpret the exact
/// SQL shapes [TodosRepository] issues — mirrors
/// activities_repository_test.dart's own `FakeLocalStore` convention
/// (NFR-ARC-2's seam: testable against a plain Dart fake, no PowerSync/
/// platform channel involved).
class FakeLocalStore implements LocalStoreEngine {
  final List<Map<String, Object?>> rows = [];
  final _watchController = StreamController<void>.broadcast();

  void _notify() => _watchController.add(null);

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) async* {
    yield _select(sql, args);
    yield* _watchController.stream.map((_) => _select(sql, args));
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final results = _select(sql, args);
    return results.isEmpty ? null : results.first;
  }

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => _select(sql, args);

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    final normalized = sql.trim().toUpperCase();
    if (normalized.startsWith('INSERT INTO TODOS')) {
      // (id, title, description, due_date, priority, status, completed_at,
      // assignee_id, apiary_id, created_at, updated_at) — create() never
      // sets organization_id (todos_repository.dart's own doc: server-derived,
      // populated only once the write round-trips through sync).
      rows.add({
        'id': args[0],
        'organization_id': null,
        'title': args[1],
        'description': args[2],
        'due_date': args[3],
        'priority': args[4],
        'status': args[5],
        'completed_at': args[6],
        'assignee_id': args[7],
        'apiary_id': args[8],
        'created_at': args[9],
        'updated_at': args[10],
      });
    } else if (normalized.startsWith(
      'UPDATE TODOS SET TITLE = ?, DESCRIPTION = ?',
    )) {
      // update(): title, description, due_date, priority, assignee_id,
      // apiary_id, updated_at WHERE id — a full resubmit, organization_id
      // untouched.
      final id = args[7];
      final row = rows.firstWhere((r) => r['id'] == id);
      row['title'] = args[0];
      row['description'] = args[1];
      row['due_date'] = args[2];
      row['priority'] = args[3];
      row['assignee_id'] = args[4];
      row['apiary_id'] = args[5];
      row['updated_at'] = args[6];
    } else if (normalized.startsWith(
      'UPDATE TODOS SET STATUS = ?, COMPLETED_AT = ?',
    )) {
      // complete()/reopen(): status, completed_at, updated_at WHERE id.
      final id = args[3];
      final row = rows.firstWhere((r) => r['id'] == id);
      row['status'] = args[0];
      row['completed_at'] = args[1];
      row['updated_at'] = args[2];
    } else if (normalized.startsWith('DELETE FROM TODOS')) {
      rows.removeWhere((r) => r['id'] == args[0]);
    } else {
      throw UnsupportedError('FakeLocalStore.execute: unhandled SQL: $sql');
    }
    _notify();
  }

  @override
  Future<void> clear() async {
    rows.clear();
    _notify();
  }

  List<Map<String, Object?>> _select(String sql, List<Object?> args) {
    final normalized = sql.toUpperCase();
    var results = List<Map<String, Object?>>.from(rows);
    if (normalized.contains('WHERE ID = ?')) {
      results = results.where((r) => r['id'] == args[0]).toList();
    } else if (normalized.contains(
      'ORGANIZATION_ID = ? OR ORGANIZATION_ID IS NULL',
    )) {
      // watchAll's defense-in-depth org filter (#53, mirrors
      // activities_repository_test.dart's own FakeLocalStore convention).
      final orgId = args[0];
      results = results
          .where(
            (r) =>
                r['organization_id'] == orgId || r['organization_id'] == null,
          )
          .toList();
    }
    if (normalized.contains('ORDER BY CREATED_AT DESC')) {
      results.sort(
        (a, b) =>
            (b['created_at'] as String).compareTo(a['created_at'] as String),
      );
    }
    return results;
  }

  void dispose() => _watchController.close();
}

void main() {
  late FakeLocalStore store;
  late TodosRepository repo;

  setUp(() {
    store = FakeLocalStore();
    repo = TodosRepository(store);
  });

  tearDown(() => store.dispose());

  group('TodosRepository.create()', () {
    test('inserts a local row with the given fields, defaulting to open, '
        'unassigned (D-23) and no apiary association (#51, FR-TD-1)',
        () async {
      final id = await repo.create(title: 'Inspect hive 3', priority: 'medium');

      expect(id, isNotEmpty);
      expect(store.rows, hasLength(1));
      final row = store.rows.single;
      expect(row['title'], 'Inspect hive 3');
      expect(row['priority'], 'medium');
      expect(row['status'], 'open');
      expect(row['completed_at'], '');
      expect(row['assignee_id'], '');
      expect(row['apiary_id'], '');
      // Never set locally (server-derived) — see the class doc.
      expect(row['organization_id'], isNull);
    });

    test('stores description/due_date/assignee_id/apiary_id when provided',
        () async {
      await repo.create(
        title: 'Check varroa',
        priority: 'high',
        description: 'count mite drop',
        dueDate: '2026-08-01',
        assigneeId: 'user-1',
        apiaryId: 'apiary-1',
      );

      final row = store.rows.single;
      expect(row['description'], 'count mite drop');
      expect(row['due_date'], '2026-08-01');
      expect(row['assignee_id'], 'user-1');
      expect(row['apiary_id'], 'apiary-1');
    });
  });

  group('TodosRepository.getById()/watchById()', () {
    test('getById returns the created todo, mapping "" back to null', () async {
      final id = await repo.create(title: 'x', priority: 'low');

      final todo = await repo.getById(id);

      expect(todo, isNotNull);
      expect(todo!.title, 'x');
      expect(todo.priority, 'low');
      expect(todo.status, 'open');
      expect(todo.description, isNull);
      expect(todo.dueDate, isNull);
      expect(todo.assigneeId, isNull);
      expect(todo.apiaryId, isNull);
      expect(todo.completedAt, isNull);
      expect(todo.isDone, isFalse);
    });

    test('getById returns null for an unknown id', () async {
      expect(await repo.getById('missing'), isNull);
    });

    test('watchById re-emits after a write to that todo', () async {
      final id = await repo.create(title: 'x', priority: 'low');
      final emissions = <String?>[];
      final sub = repo.watchById(id).listen((t) => emissions.add(t?.status));
      addTearDown(sub.cancel);

      await pumpEventQueue();
      expect(emissions, ['open']);

      await repo.complete(id);
      await pumpEventQueue();

      expect(emissions.last, 'done');
    });
  });

  group('TodosRepository.update() — full resubmit', () {
    test(
        'changes title/description/due_date/priority/assignee_id/apiary_id '
        'together', () async {
      final id = await repo.create(title: 'old title', priority: 'low');

      await repo.update(
        id,
        title: 'new title',
        priority: 'high',
        description: 'now with detail',
        dueDate: '2026-09-01',
        assigneeId: 'user-2',
        apiaryId: 'apiary-2',
      );

      final todo = await repo.getById(id);
      expect(todo!.title, 'new title');
      expect(todo.priority, 'high');
      expect(todo.description, 'now with detail');
      expect(todo.dueDate, '2026-09-01');
      expect(todo.assigneeId, 'user-2');
      expect(todo.apiaryId, 'apiary-2');
    });

    test(
        'clears description/due_date/assignee_id/apiary_id when omitted '
        '(both null and "" mean "no value")', () async {
      final id = await repo.create(
        title: 'x',
        priority: 'low',
        description: 'has notes',
        dueDate: '2026-08-01',
        assigneeId: 'user-1',
        apiaryId: 'apiary-1',
      );

      await repo.update(id, title: 'x', priority: 'low');

      final todo = await repo.getById(id);
      expect(todo!.description, isNull);
      expect(todo.dueDate, isNull);
      expect(todo.assigneeId, isNull);
      expect(todo.apiaryId, isNull);
    });

    test('never touches status/completed_at', () async {
      final id = await repo.create(title: 'x', priority: 'low');
      await repo.complete(id);

      await repo.update(id, title: 'edited', priority: 'medium');

      final todo = await repo.getById(id);
      expect(todo!.status, 'done');
      expect(todo.completedAt, isNotNull);
    });

    test('changes only apiary_id — the association can be set, changed or '
        'cleared independently of every other field (#51 AC)', () async {
      final id = await repo.create(
        title: 'x',
        priority: 'low',
        description: 'keep me',
        dueDate: '2026-08-01',
        assigneeId: 'user-1',
        apiaryId: 'apiary-1',
      );

      // Set → changed.
      await repo.update(
        id,
        title: 'x',
        priority: 'low',
        description: 'keep me',
        dueDate: '2026-08-01',
        assigneeId: 'user-1',
        apiaryId: 'apiary-2',
      );
      var todo = await repo.getById(id);
      expect(todo!.apiaryId, 'apiary-2');
      expect(todo.description, 'keep me');
      expect(todo.assigneeId, 'user-1');

      // Changed → cleared (a general, org-level todo again).
      await repo.update(
        id,
        title: 'x',
        priority: 'low',
        description: 'keep me',
        dueDate: '2026-08-01',
        assigneeId: 'user-1',
      );
      todo = await repo.getById(id);
      expect(todo!.apiaryId, isNull);
      expect(todo.description, 'keep me');
      expect(todo.assigneeId, 'user-1');
    });
  });

  group('TodosRepository.complete()/reopen() — narrow status-only patch', () {
    test('complete() sets status=done and completed_at', () async {
      final id = await repo.create(title: 'x', priority: 'low');

      await repo.complete(id);

      final todo = await repo.getById(id);
      expect(todo!.status, 'done');
      expect(todo.isDone, isTrue);
      expect(todo.completedAt, isNotNull);
    });

    test('complete() preserves title/description/due_date/priority/'
        'assignee_id/apiary_id', () async {
      final id = await repo.create(
        title: 'Inspect hive 3',
        priority: 'high',
        description: 'double check frames',
        dueDate: '2026-08-01',
        assigneeId: 'user-1',
        apiaryId: 'apiary-1',
      );

      await repo.complete(id);

      final todo = await repo.getById(id);
      expect(todo!.title, 'Inspect hive 3');
      expect(todo.priority, 'high');
      expect(todo.description, 'double check frames');
      expect(todo.dueDate, '2026-08-01');
      expect(todo.assigneeId, 'user-1');
      expect(todo.apiaryId, 'apiary-1');
    });

    test('reopen() clears completed_at and sets status=open', () async {
      final id = await repo.create(title: 'x', priority: 'low');
      await repo.complete(id);

      await repo.reopen(id);

      final todo = await repo.getById(id);
      expect(todo!.status, 'open');
      expect(todo.isDone, isFalse);
      expect(todo.completedAt, isNull);
    });
  });

  group('TodosRepository.delete()', () {
    test('removes the local row', () async {
      final id = await repo.create(title: 'x', priority: 'low');

      await repo.delete(id);

      expect(await repo.getById(id), isNull);
    });
  });

  group('organization_id invariant (FR-TEN-2) — never written locally', () {
    test(
      'stays null through create(), update(), complete() and reopen()',
      () async {
        final id = await repo.create(title: 'x', priority: 'low');
        expect(store.rows.single['organization_id'], isNull);

        await repo.update(id, title: 'y', priority: 'medium');
        expect(store.rows.single['organization_id'], isNull);

        await repo.complete(id);
        expect(store.rows.single['organization_id'], isNull);

        await repo.reopen(id);
        expect(store.rows.single['organization_id'], isNull);
      },
    );
  });

  group('TodosRepository.watchAll() org-scoping (#53, FR-TD-1/FR-TEN-2)', () {
    test('returns an empty stream when the organization id is null (not yet '
        'loaded)', () async {
      final todos = await repo.watchAll(organizationId: null).first;
      expect(todos, isEmpty);
    });

    test('excludes another organization\'s todos — never leaks cross-tenant '
        'data even if it were somehow present locally (#53 AC)', () async {
      store.rows.addAll([
        {
          'id': 'own-1',
          'organization_id': 'org-a',
          'title': 'Mine',
          'description': '',
          'due_date': '',
          'priority': 'low',
          'status': 'open',
          'completed_at': '',
          'assignee_id': '',
          'created_at': '2026-06-01T00:00:00Z',
          'updated_at': '2026-06-01T00:00:00Z',
        },
        {
          'id': 'foreign-1',
          'organization_id': 'org-b',
          'title': 'Not mine',
          'description': '',
          'due_date': '',
          'priority': 'low',
          'status': 'open',
          'completed_at': '',
          'assignee_id': '',
          'created_at': '2026-06-02T00:00:00Z',
          'updated_at': '2026-06-02T00:00:00Z',
        },
      ]);

      final todos = await repo.watchAll(organizationId: 'org-a').first;

      expect(todos.map((t) => t.id).toList(), ['own-1']);
      expect(
        todos.any((t) => t.organizationId == 'org-b'),
        isFalse,
        reason: 'org-a caller must never see org-b\'s todos',
      );
    });

    test('still shows a freshly-created, not-yet-synced local row (null '
        'organization_id) — offline-first: your own just-added todo must not '
        'disappear from the list until it round-trips (FR-OF-1)', () async {
      await repo.create(title: 'Inspect hive 3', priority: 'medium');

      final todos = await repo.watchAll(organizationId: 'org-a').first;

      expect(todos, hasLength(1));
      expect(todos.single.organizationId, isNull);
    });

    test(
      'includes only the caller\'s own org id or null, newest-created-first',
      () async {
        store.rows.addAll([
          {
            'id': 'older',
            'organization_id': 'org-a',
            'title': 'Older',
            'description': '',
            'due_date': '',
            'priority': 'low',
            'status': 'open',
            'completed_at': '',
            'assignee_id': '',
            'created_at': '2026-05-01T00:00:00Z',
            'updated_at': '2026-05-01T00:00:00Z',
          },
          {
            'id': 'newer',
            'organization_id': 'org-a',
            'title': 'Newer',
            'description': '',
            'due_date': '',
            'priority': 'high',
            'status': 'open',
            'completed_at': '',
            'assignee_id': '',
            'created_at': '2026-06-01T00:00:00Z',
            'updated_at': '2026-06-01T00:00:00Z',
          },
        ]);

        final todos = await repo.watchAll(organizationId: 'org-a').first;

        expect(todos.map((t) => t.id).toList(), ['newer', 'older']);
      },
    );

    test('watchAll re-emits after a write affecting the local set', () async {
      final emissions = <int>[];
      final sub = repo
          .watchAll(organizationId: 'org-a')
          .listen((todos) => emissions.add(todos.length));
      addTearDown(sub.cancel);

      await pumpEventQueue();
      expect(emissions, [0]);

      await repo.create(title: 'x', priority: 'low');
      await pumpEventQueue();

      expect(emissions.last, 1);
    });
  });
}
