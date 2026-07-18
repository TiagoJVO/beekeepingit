import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/sync/local_store.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';

/// A local todo row (#50, FR-TD-1, FR-TEN-2, D-20, D-23): the client mirror
/// of one `todos.todos` row replicated down by the org-scoped PowerSync Sync
/// Rule.
///
/// [organizationId] is nullable — NOT because the server column is optional
/// (it isn't, FR-TEN-2), but because [TodosRepository.create] deliberately
/// never writes it locally (mirrors activities_repository.dart's own
/// [organizationId] doc): a freshly-created, not-yet-uploaded row has it
/// NULL until the write round-trips through sync. [assigneeId] is the
/// opposite case (D-23) — it IS written locally, since the user genuinely
/// picks who to assign.
class Todo {
  const Todo({
    required this.id,
    required this.title,
    required this.priority,
    required this.status,
    this.description,
    this.dueDate,
    this.completedAt,
    this.assigneeId,
    this.organizationId,
  });

  final String id;
  final String title;
  final String? description;

  /// Plain `YYYY-MM-DD` (no time-of-day), matching the server's `DATE`
  /// column, or null — a todo may legitimately have none (FR-TD-1).
  final String? dueDate;
  final String priority;
  final String status;

  /// ISO-8601 device timestamp, or null when the todo isn't completed.
  final String? completedAt;
  final String? assigneeId;
  final String? organizationId;

  bool get isDone => status == 'done';
}

/// Writes todos against the local store (#50, FR-TD-1, FR-OF-1), mirroring
/// activities_repository.dart's local-first convention: every write is
/// queued for the write-back seam (walking-skeleton.md §4.4 — for todos
/// specifically, services/sync/api/coordinator.go's entity_type routing to
/// the todos service, services/todos/api/sync.go) rather than calling a REST
/// write endpoint directly.
///
/// `organization_id` is deliberately NOT written here — exactly like
/// activities_repository's own omission — it is derived SERVER-SIDE from the
/// authenticated caller's token on write-back (FR-TEN-2), never from
/// client-supplied data. `assignee_id` is the opposite case (D-23): it IS
/// written locally, since the user genuinely picks who to assign — the
/// server still re-verifies it belongs to an active member of the caller's
/// org before accepting the write (services/todos/api/members_client.go),
/// so a spoofed/foreign assignment is rejected server-side regardless of
/// what this repository queues.
///
/// [update] always resubmits the COMPLETE current state (title/description/
/// due_date/priority/assignee_id) in one SQL UPDATE, matching
/// services/todos/api/sync.go's own "an edit patch always carries all of
/// these together" convention. [complete]/[reopen] are DELIBERATELY separate
/// UPDATEs touching only status/completed_at(/updated_at), so an offline
/// complete/reopen queues as its own narrow patch rather than resubmitting
/// the whole row — mirroring the server's own complete-via-patch design
/// (services/todos/README.md's "no bespoke wire op" section). An optional
/// field cleared via [update] (or left unset via [create]) is passed as `''`
/// rather than `null` to the underlying store: the server treats `''` and
/// "column absent from this op" identically as "no value"
/// (services/todos/api/common.go's textOf/dateOf/uuidOf convention), so a
/// caller passing `null` here has the exact same on-the-wire effect as `''`.
class TodosRepository {
  TodosRepository(this._store);

  final LocalStoreEngine _store;
  static const _uuid = Uuid();

  /// Creates a todo. [priority] must already be one of the known values
  /// (`low`/`medium`/`high`, mirroring services/todos/api/types.go's own
  /// vocabulary, D-20). Every new todo starts `status='open'` with no
  /// `completed_at` (D-23's default) and, absent [assigneeId], unassigned.
  Future<String> create({
    required String title,
    required String priority,
    String? description,
    String? dueDate,
    String? assigneeId,
  }) async {
    final id = _uuid.v4();
    final now = _nowIso();
    await _store.execute(
      'INSERT INTO $todosTable '
      '(id, title, description, due_date, priority, status, completed_at, '
      'assignee_id, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        title,
        description ?? '',
        dueDate ?? '',
        priority,
        'open',
        '',
        assigneeId ?? '',
        now,
        now,
      ],
    );
    return id;
  }

  /// One-shot read of a todo by id, or null if it doesn't (or no longer)
  /// exist — mirrors [ActivitiesRepository.getById].
  Future<Todo?> getById(String id) async {
    final row = await _store.getOptional(
      'SELECT id, organization_id, title, description, due_date, priority, '
      'status, completed_at, assignee_id FROM $todosTable WHERE id = ?',
      [id],
    );
    return row == null ? null : _fromRow(row);
  }

  /// Live single-row watch for one todo by id — mirrors
  /// [ActivitiesRepository.watchById]'s per-id pattern.
  Stream<Todo?> watchById(String id) {
    return _store
        .watch(
          'SELECT id, organization_id, title, description, due_date, '
          'priority, status, completed_at, assignee_id FROM $todosTable '
          'WHERE id = ?',
          [id],
        )
        .map((rows) => rows.isEmpty ? null : _fromRow(rows.first));
  }

  /// Updates an existing todo's title/description/due_date/priority/
  /// assignee_id — a FULL resubmit in one SQL UPDATE (this class's own doc
  /// comment), matching the server's own PATCH semantics. Never touches
  /// status/completed_at — [complete]/[reopen] own that transition
  /// exclusively.
  Future<void> update(
    String id, {
    required String title,
    required String priority,
    String? description,
    String? dueDate,
    String? assigneeId,
  }) {
    return _store.execute(
      'UPDATE $todosTable SET title = ?, description = ?, due_date = ?, '
      'priority = ?, assignee_id = ?, updated_at = ? WHERE id = ?',
      [
        title,
        description ?? '',
        dueDate ?? '',
        priority,
        assigneeId ?? '',
        _nowIso(),
        id,
      ],
    );
  }

  /// Marks the todo done (FR-TD-1). A narrow UPDATE touching only
  /// status/completed_at(/updated_at) — queued offline as a status-only
  /// patch (this class's own doc comment), never resubmitting title/
  /// description/due_date/priority/assignee_id.
  Future<void> complete(String id) {
    final now = _nowIso();
    return _store.execute(
      'UPDATE $todosTable SET status = ?, completed_at = ?, updated_at = ? '
      'WHERE id = ?',
      ['done', now, now, id],
    );
  }

  /// Reopens a done todo (FR-TD-1): clears `completed_at`, sets status back
  /// to open. Same narrow-UPDATE shape as [complete].
  Future<void> reopen(String id) {
    final now = _nowIso();
    return _store.execute(
      'UPDATE $todosTable SET status = ?, completed_at = ?, updated_at = ? '
      'WHERE id = ?',
      ['open', '', now, id],
    );
  }

  /// Deletes the todo row (FR-TD-1). A plain local DELETE — PowerSync's CRUD
  /// queue observes it as a `delete` op regardless (mirrors
  /// [ActivitiesRepository.delete]'s own doc comment), routed to the todos
  /// service's sync-apply endpoint, where it is applied as a server-side
  /// tombstone.
  Future<void> delete(String id) =>
      _store.execute('DELETE FROM $todosTable WHERE id = ?', [id]);

  Todo _fromRow(Map<String, Object?> r) => Todo(
    id: r['id'] as String,
    organizationId: r['organization_id'] as String?,
    title: r['title'] as String,
    description: _optional(r['description'] as String?),
    dueDate: _optional(r['due_date'] as String?),
    priority: r['priority'] as String,
    status: r['status'] as String,
    completedAt: _optional(r['completed_at'] as String?),
    assigneeId: _optional(r['assignee_id'] as String?),
  );

  /// `''` and `null` both mean "no value" (this class's own convention,
  /// mirroring the server's own textOf/dateOf/uuidOf "" sentinel) — surfaced
  /// to callers as a genuine `null` rather than an empty string.
  String? _optional(String? v) => (v == null || v.isEmpty) ? null : v;

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

final todosRepositoryProvider = FutureProvider<TodosRepository>((ref) async {
  final session = await ref.watch(powerSyncProvider.future);
  return TodosRepository(PowerSyncLocalStore(session.db));
});

/// Live single todo by id — mirrors [activityByIdProvider]'s family +
/// autoDispose pattern (activities_repository.dart).
final todoByIdProvider = StreamProvider.autoDispose.family<Todo?, String>((
  ref,
  todoId,
) async* {
  final repo = await ref.watch(todosRepositoryProvider.future);
  yield* repo.watchById(todoId);
});
