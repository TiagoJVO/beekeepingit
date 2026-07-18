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
      // assignee_id, created_at, updated_at) — create() never sets
      // organization_id (todos_repository.dart's own doc: server-derived,
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
        'created_at': args[8],
        'updated_at': args[9],
      });
    } else if (normalized.startsWith(
      'UPDATE TODOS SET TITLE = ?, DESCRIPTION = ?',
    )) {
      // update(): title, description, due_date, priority, assignee_id,
      // updated_at WHERE id — a full resubmit, organization_id untouched.
      final id = args[6];
      final row = rows.firstWhere((r) => r['id'] == id);
      row['title'] = args[0];
      row['description'] = args[1];
      row['due_date'] = args[2];
      row['priority'] = args[3];
      row['assignee_id'] = args[4];
      row['updated_at'] = args[5];
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
    test('inserts a local row with the given fields, defaulting to open '
        'and unassigned (D-23)', () async {
      final id = await repo.create(title: 'Inspect hive 3', priority: 'medium');

      expect(id, isNotEmpty);
      expect(store.rows, hasLength(1));
      final row = store.rows.single;
      expect(row['title'], 'Inspect hive 3');
      expect(row['priority'], 'medium');
      expect(row['status'], 'open');
      expect(row['completed_at'], '');
      expect(row['assignee_id'], '');
      // Never set locally (server-derived) — see the class doc.
      expect(row['organization_id'], isNull);
    });

    test('stores description/due_date/assignee_id when provided', () async {
      await repo.create(
        title: 'Check varroa',
        priority: 'high',
        description: 'count mite drop',
        dueDate: '2026-08-01',
        assigneeId: 'user-1',
      );

      final row = store.rows.single;
      expect(row['description'], 'count mite drop');
      expect(row['due_date'], '2026-08-01');
      expect(row['assignee_id'], 'user-1');
    });
  });

  group('TodosRepository.getById()/watchById()', () {
    test('getById returns the created todo, mapping "" back to null',
        () async {
      final id = await repo.create(title: 'x', priority: 'low');

      final todo = await repo.getById(id);

      expect(todo, isNotNull);
      expect(todo!.title, 'x');
      expect(todo.priority, 'low');
      expect(todo.status, 'open');
      expect(todo.description, isNull);
      expect(todo.dueDate, isNull);
      expect(todo.assigneeId, isNull);
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
    test('changes title/description/due_date/priority/assignee_id together',
        () async {
      final id = await repo.create(title: 'old title', priority: 'low');

      await repo.update(
        id,
        title: 'new title',
        priority: 'high',
        description: 'now with detail',
        dueDate: '2026-09-01',
        assigneeId: 'user-2',
      );

      final todo = await repo.getById(id);
      expect(todo!.title, 'new title');
      expect(todo.priority, 'high');
      expect(todo.description, 'now with detail');
      expect(todo.dueDate, '2026-09-01');
      expect(todo.assigneeId, 'user-2');
    });

    test('clears description/due_date/assignee_id when omitted (both null '
        'and "" mean "no value")', () async {
      final id = await repo.create(
        title: 'x',
        priority: 'low',
        description: 'has notes',
        dueDate: '2026-08-01',
        assigneeId: 'user-1',
      );

      await repo.update(id, title: 'x', priority: 'low');

      final todo = await repo.getById(id);
      expect(todo!.description, isNull);
      expect(todo.dueDate, isNull);
      expect(todo.assigneeId, isNull);
    });

    test('never touches status/completed_at', () async {
      final id = await repo.create(title: 'x', priority: 'low');
      await repo.complete(id);

      await repo.update(id, title: 'edited', priority: 'medium');

      final todo = await repo.getById(id);
      expect(todo!.status, 'done');
      expect(todo.completedAt, isNotNull);
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
        'assignee_id', () async {
      final id = await repo.create(
        title: 'Inspect hive 3',
        priority: 'high',
        description: 'double check frames',
        dueDate: '2026-08-01',
        assigneeId: 'user-1',
      );

      await repo.complete(id);

      final todo = await repo.getById(id);
      expect(todo!.title, 'Inspect hive 3');
      expect(todo.priority, 'high');
      expect(todo.description, 'double check frames');
      expect(todo.dueDate, '2026-08-01');
      expect(todo.assigneeId, 'user-1');
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
    test('stays null through create(), update(), complete() and reopen()',
        () async {
      final id = await repo.create(title: 'x', priority: 'low');
      expect(store.rows.single['organization_id'], isNull);

      await repo.update(id, title: 'y', priority: 'medium');
      expect(store.rows.single['organization_id'], isNull);

      await repo.complete(id);
      expect(store.rows.single['organization_id'], isNull);

      await repo.reopen(id);
      expect(store.rows.single['organization_id'], isNull);
    });
  });
}
