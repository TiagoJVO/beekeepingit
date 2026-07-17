import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/sync/local_store.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';

/// A local activity row (#39/#40/#41, FR-AC-1..4): the client-side mirror of
/// `activities.activities`, read back for the edit form's pre-fill
/// ([ActivitiesRepository.getById]/[watchById]) — mirrors apiaries_repository
/// .dart's own [Apiary] read model. `attributes` is decoded from its
/// JSON-encoded local text column (the same encoding [create]/[update]
/// write it with) back into a plain map, matching the server's own
/// `map[string]any` shape (api/write.go's `toActivityDTO`).
class Activity {
  const Activity({
    required this.id,
    required this.apiaryId,
    required this.type,
    required this.occurredAt,
    required this.attributes,
  });

  final String id;
  final String apiaryId;
  final String type;
  final String occurredAt;
  final Map<String, dynamic> attributes;
}

/// Writes activities against the local store (#39/#40/#41, FR-AC-2/3/4,
/// FR-OF-1), mirroring apiaries_repository.dart's own local-first
/// convention: every write is queued for the write-back seam
/// (walking-skeleton.md §4.4, and — for activities specifically —
/// services/sync/api/coordinator.go's entity_type routing to the activities
/// service, services/activities/api/sync.go) rather than calling a REST
/// write endpoint directly.
///
/// `organization_id` and `performed_by` are deliberately NOT written here —
/// exactly like apiaries_repository's own omission of `organization_id` —
/// both are derived SERVER-SIDE from the authenticated caller's token on
/// write-back (FR-TEN-2: "each activity is recorded against the user who
/// performed it"), never from client-supplied data, so a spoofed attribution
/// is not even representable on the wire. `journey_id` is similarly omitted
/// (D-21/#46, unused until M4 — there is no journey to attach to yet).
///
/// `apiary_id` is likewise never written by [update] (#40): the edit UI
/// never exposes moving an activity to a different apiary, so every local
/// UPDATE this repository issues touches only type/occurred_at/attributes —
/// matching services/activities/api/sync.go's own "apiary_id is optional on
/// an edit op, unchanged when absent" convention on the server side.
class ActivitiesRepository {
  ActivitiesRepository(this._store);

  final LocalStoreEngine _store;
  static const _uuid = Uuid();

  /// Creates an activity for [apiaryId]. [attributes] must already be the
  /// exact per-[type] attribute bag (only that type's own keys — an extra
  /// key would be rejected server-side, api/types.go's ValidateActivity) —
  /// callers (add_activity_screen.dart) build it via
  /// activity_attributes.dart's schema and validate it with
  /// [validateActivityAttributes] BEFORE calling this, matching D-12's
  /// "client revalidates against the same rules the server will apply"
  /// requirement. [occurredAt] is a plain `YYYY-MM-DD` string, matching the
  /// server's `DATE` column (services/activities/api/validate.go's
  /// `dateLayout`) — no time-of-day component.
  Future<String> create({
    required String apiaryId,
    required String type,
    required String occurredAt,
    required Map<String, dynamic> attributes,
  }) async {
    final id = _uuid.v4();
    final now = _nowIso();
    await _store.execute(
      'INSERT INTO $activitiesTable '
      '(id, apiary_id, type, occurred_at, attributes, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [id, apiaryId, type, occurredAt, jsonEncode(attributes), now, now],
    );
    return id;
  }

  /// One-shot read of an activity by id, or null if it doesn't (or no
  /// longer) exist — mirrors [ApiariesRepository.getById]. Used by the edit
  /// form's initial load (add_activity_screen.dart's `_loadExisting`).
  Future<Activity?> getById(String id) async {
    final row = await _store.getOptional(
      'SELECT id, apiary_id, type, occurred_at, attributes '
      'FROM $activitiesTable WHERE id = ?',
      [id],
    );
    return row == null ? null : _fromRow(row);
  }

  /// Live single-row watch for one activity by id — mirrors
  /// [ApiariesRepository.watchById]'s per-id pattern (not currently
  /// consumed by a screen yet, added alongside [getById] for the same
  /// reason that one exists: a future edit-screen provider can watch
  /// rather than one-shot load without a second read path being added
  /// later).
  Stream<Activity?> watchById(String id) {
    return _store
        .watch(
          'SELECT id, apiary_id, type, occurred_at, attributes '
          'FROM $activitiesTable WHERE id = ?',
          [id],
        )
        .map((rows) => rows.isEmpty ? null : _fromRow(rows.first));
  }

  /// Updates an existing activity's type/date/attributes (#40, FR-AC-3).
  /// [attributes] must already be the exact per-[type] attribute bag,
  /// validated client-side the same way [create]'s callers do (D-12) — the
  /// edit form always resubmits the COMPLETE current state (never a sparse
  /// per-field diff), so this always sets every mutable column in one SQL
  /// UPDATE — matching services/activities/api/sync.go's own "put/patch are
  /// both a full resubmit" convention for this table (mergeActivityOp's doc
  /// comment). apiary_id is deliberately excluded from the SET clause (this
  /// class's own doc comment).
  Future<void> update(
    String id, {
    required String type,
    required String occurredAt,
    required Map<String, dynamic> attributes,
  }) {
    return _store.execute(
      'UPDATE $activitiesTable SET type = ?, occurred_at = ?, attributes = ?, updated_at = ? '
      'WHERE id = ?',
      [type, occurredAt, jsonEncode(attributes), _nowIso(), id],
    );
  }

  /// Deletes the activity row (#41, FR-AC-4). A plain local DELETE —
  /// PowerSync's CRUD queue observes it as a `delete` op regardless (the
  /// same mechanism [ApiariesRepository.delete]'s own doc comment
  /// describes), which the connector (powersync_connector.dart's
  /// `entityTypeForTable`) routes to the activities service's sync-apply
  /// endpoint, where it is applied as a server-side tombstone
  /// (services/activities/api/sync.go's applyActivityOp) — the row is
  /// removed from THIS device immediately and propagates to every other
  /// device on their next sync via the PowerSync Sync Rules'
  /// `deleted_at IS NULL` filter.
  Future<void> delete(String id) =>
      _store.execute('DELETE FROM $activitiesTable WHERE id = ?', [id]);

  Activity _fromRow(Map<String, Object?> r) {
    final rawAttrs = r['attributes'] as String?;
    Map<String, dynamic> attrs = const {};
    if (rawAttrs != null && rawAttrs.isNotEmpty) {
      final decoded = jsonDecode(rawAttrs);
      if (decoded is Map<String, dynamic>) attrs = decoded;
    }
    return Activity(
      id: r['id'] as String,
      apiaryId: r['apiary_id'] as String,
      type: r['type'] as String,
      occurredAt: r['occurred_at'] as String,
      attributes: attrs,
    );
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

final activitiesRepositoryProvider = FutureProvider<ActivitiesRepository>((
  ref,
) async {
  final session = await ref.watch(powerSyncProvider.future);
  return ActivitiesRepository(PowerSyncLocalStore(session.db));
});

/// Live single activity by id (#40/#41) — the edit screen's read path,
/// mirroring [apiaryByIdProvider]'s family + autoDispose pattern
/// (apiaries_repository.dart).
final activityByIdProvider = StreamProvider.autoDispose.family<Activity?, String>((
  ref,
  activityId,
) async* {
  final repo = await ref.watch(activitiesRepositoryProvider.future);
  yield* repo.watchById(activityId);
});
