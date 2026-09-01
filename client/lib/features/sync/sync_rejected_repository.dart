import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync/local_store.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';
import 'sync_rejection_messages.dart';

/// One rejected offline write held in the local `sync_rejected_ops` dead-letter
/// (powersync_schema.dart) — the read model behind the needs-fix list
/// (sync.md §8 notify-and-fix, D-12, EPIC-06 #7). The connector
/// (`powersync_connector.dart`'s `handleUploadResponse`) writes these; this is
/// the client-side, only place a permanently-rejected edit still exists, so the
/// user can fix and re-queue it rather than lose it.
class RejectedOp {
  const RejectedOp({
    required this.id,
    required this.entityType,
    required this.fixApiaryId,
    required this.op,
    required this.errorCode,
    required this.fieldIssues,
    this.displayName,
    this.activityType,
    this.journeyId,
  });

  /// The dead-letter row id — the handle the "Dismiss" action deletes by.
  /// For every entity type EXCEPT `apiary_counter` this is also the queued
  /// op's own id (powersync_connector.dart's `_toOp`), which
  /// [fixApiaryId] happens to duplicate for those types — see that field's
  /// own doc.
  final String id;

  /// `apiary` | `apiary_counter` | `activity` | `journey` |
  /// `journey_plan_item` | `todo` (powersync_schema.dart's entity-type
  /// constants) — drives both the entity label and the "Fix" deep-link the
  /// list row shows (#379).
  final String entityType;

  /// Despite its name (kept for backward compatibility with the dead-letter
  /// row's `fix_apiary_id` column, still literally an apiary id for the two
  /// apiary-owned entity types), this is the id the "Fix" action deep-links
  /// with: the owning apiary's id for `apiary`/`apiary_counter`, or the op's
  /// own row id for every other entity type (powersync_connector.dart's
  /// `_fixApiaryIdFor` returns the op's own id for anything but a counter) —
  /// i.e. the journey id for a `journey` rejection, the todo id for a `todo`
  /// one. NOT useful for `journey_plan_item` (whose own id is the plan-item
  /// row, not the journey) — see [journeyId] for that case instead.
  final String fixApiaryId;

  /// `put` | `patch` | `delete`.
  final String op;

  /// RFC 9457 problem `code` (e.g. `validation.failed`), or `''` when the
  /// problem body couldn't be parsed.
  ///
  /// **Not usable as UI copy (#443).** It is the same value for effectively
  /// every retained rejection: the connector only dead-letters a `422`/`400`
  /// (`classifyUploadOutcome`), and the sync endpoints answer those solely
  /// with `problem.ValidationFailed` — `auth.forbidden`/`resource.conflict`
  /// are `403`/`409`, which the connector treats as transient and leaves
  /// queued. The user-facing copy therefore comes from the per-field codes
  /// ([fieldIssues]) alone; this stays for logs and for the day a new
  /// rejection class is actually retained.
  final String errorCode;

  /// The **machine-readable** field errors the server returned for this op:
  /// `(field, code)` pairs, with none of the accompanying server prose (#443).
  /// This is the only part of the problem body the UI reads — it goes through
  /// `sync_rejection_messages.dart`'s allow-listed EN/PT mapping.
  ///
  /// The raw `errors[].message` and `detail` are deliberately **not** carried
  /// on this model at all: they are English-only and can embed internal DB
  /// column names ("default_attributes must be a JSON object"), so #426 stopped
  /// rendering them and nothing has read them since. They remain available for
  /// diagnostics where they belong — the connector logs the whole problem body
  /// (`powersync_connector.dart`'s `_retainRejected`) and the row keeps it in
  /// its `error_detail` column — rather than sitting on a UI read model where
  /// a future caller could render one by accident.
  ///
  /// Empty when the op was collateral in an atomic push (valid itself, rolled
  /// back because a sibling op failed), when the body carried no field detail,
  /// or when `error_detail` was malformed.
  final List<RejectedFieldIssue> fieldIssues;

  /// The record's own name/title, read from the rejected op's stored
  /// `payload` (#379, fix plan item 4): `name` for a journey (and apiary),
  /// `title` for a todo. Null when the payload carried no such field (or, for
  /// `journey_plan_item`, never — a plan item has no name of its own) — the
  /// needs-fix row then shows just the plain entity label.
  ///
  /// Always an **already-human** string: an activity has no name of its own,
  /// only a wire type enum, which lives in [activityType] instead precisely so
  /// that a raw identifier can never reach the row title through this field.
  final String? displayName;

  /// An `activity` rejection's raw wire type (`harvest`, `feeding`, ... —
  /// `services/activities/api/types.go`), read from the stored payload. Null
  /// for every other entity type, and when the payload carried none.
  ///
  /// **Never render this directly** — it is an untranslated internal
  /// identifier. The needs-fix row resolves it through `activity_types.dart`'s
  /// `activityTypeLabel`, which degrades to no name at all for a type this
  /// client version doesn't know (#443).
  final String? activityType;

  /// The owning journey's id, read from a `journey_plan_item` rejection's
  /// stored payload (`data.journey_id`) — used to route that entity type's
  /// "Fix" action to the journey detail screen, since [fixApiaryId] for this
  /// entity type is the plan item's own (not useful) row id. Null for every
  /// other entity type, and null if the payload is missing/malformed or
  /// predates this field (a pre-existing dead-letter row).
  final String? journeyId;
}

/// Reads and dismisses rejected-op dead-letter rows against the local store
/// (NFR-ARC-2, #55: behind [LocalStoreEngine], never a concrete engine type).
/// Mirrors `ApiariesRepository`'s shape — a thin watch/list/delete surface over
/// the same `sync_rejected_ops` table the connector writes.
class SyncRejectedRepository {
  SyncRejectedRepository(this._store);

  final LocalStoreEngine _store;

  static const _columns =
      'id, entity_type, fix_apiary_id, op, error_code, error_detail, payload';

  /// Live list of pending rejections, newest first.
  Stream<List<RejectedOp>> watchAll() {
    return _store
        .watch(
          'SELECT $_columns FROM $rejectedOpsTable ORDER BY rejected_at DESC',
        )
        .map((rows) => rows.map(_fromRow).toList());
  }

  /// Live count of pending rejections — drives the "N need fixing" badge/entry.
  Stream<int> watchCount() {
    return _store
        .watch('SELECT count(*) AS c FROM $rejectedOpsTable')
        .map((rows) => (rows.first['c'] as int?) ?? 0);
  }

  /// Dismisses one rejection (the user gives up on that edit) — deletes the
  /// dead-letter row by id. A *fixed* rejection clears itself instead, via the
  /// connector's clear-on-success when the corrected re-save uploads.
  Future<void> dismiss(String id) {
    return _store.execute('DELETE FROM $rejectedOpsTable WHERE id = ?', [id]);
  }

  RejectedOp _fromRow(Map<String, Object?> r) {
    final entityType = r['entity_type'] as String;
    final payloadData = _parsePayloadData(r['payload'] as String?);
    return RejectedOp(
      id: r['id'] as String,
      entityType: entityType,
      fixApiaryId: r['fix_apiary_id'] as String,
      op: r['op'] as String,
      errorCode: r['error_code'] as String? ?? '',
      fieldIssues: _parseFieldIssues(r['error_detail'] as String?),
      displayName: _displayNameFor(entityType, payloadData),
      activityType: entityType == activityEntityType
          ? _nonEmptyString(payloadData?['type'])
          : null,
      journeyId: payloadData?['journey_id'] as String?,
    );
  }

  /// Reads the op's own `data` (the record's field values at rejection time)
  /// out of the connector's stored `payload` column — the full JSON-encoded
  /// wire op (powersync_connector.dart's `_toOp` shape:
  /// `{op, entity_type, id, data, updated_at}`), so the interesting fields
  /// live one level down under `data`. Tolerant of a missing/malformed
  /// value, matching [_parseFieldIssues]'s own best-effort parsing — a
  /// pre-existing dead-letter row from before this column was read, or any
  /// unexpected shape, just yields no display name/journey id rather than
  /// throwing.
  Map<String, dynamic>? _parsePayloadData(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return json['data'] as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  /// The record's own name/title for the needs-fix row (#379, fix plan item
  /// 4): `name` for a journey or apiary, `title` for a todo.
  /// `journey_plan_item` has no name of its own, so it's excluded (falls
  /// through to null); `activity` is excluded too — it has only a wire type
  /// enum, which must be localized before it is shown and so travels as
  /// [RejectedOp.activityType] rather than as a display name (#443).
  String? _displayNameFor(String entityType, Map<String, dynamic>? data) {
    if (data == null) return null;
    return _nonEmptyString(switch (entityType) {
      apiaryEntityType || journeyEntityType => data['name'],
      todoEntityType => data['title'],
      _ => null,
    });
  }

  /// A payload value narrowed to a non-empty [String], else null — so callers
  /// can treat "the payload carried this" as a simple null check regardless of
  /// a missing, wrong-typed or blank stored value.
  String? _nonEmptyString(Object? value) =>
      (value is String && value.isNotEmpty) ? value : null;

  /// Parses the machine-readable `(field, code)` pairs out of the connector's
  /// stored `error_detail` JSON (`{ detail, errors: [{field, code, message}] }`)
  /// — the only part of it the UI reads (#443). The server's prose (`message`,
  /// `detail`) is deliberately dropped here rather than carried onto
  /// [RejectedOp]; see that class's [RejectedOp.fieldIssues] doc.
  ///
  /// Tolerant of a malformed/absent value at every level — a row must still
  /// render (with the generic message) rather than throw, matching the
  /// connector's own best-effort parsing. An entry missing either half is
  /// skipped rather than defaulted, so it can't masquerade as a real issue and
  /// can't take the whole row's detail down with it.
  List<RejectedFieldIssue> _parseFieldIssues(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return <RejectedFieldIssue>[
        for (final e in (json['errors'] as List<dynamic>?) ?? const [])
          if (e is Map<String, dynamic>)
            if (e['field'] case final String field)
              if (e['code'] case final String code)
                RejectedFieldIssue(field: field, code: code),
      ];
    } catch (_) {
      return const [];
    }
  }
}

final syncRejectedRepositoryProvider = FutureProvider<SyncRejectedRepository>((
  ref,
) async {
  final session = await ref.watch(powerSyncProvider.future);
  return SyncRejectedRepository(PowerSyncLocalStore(session.db));
});

/// Live list of offline writes that need fixing (the needs-fix screen).
final syncRejectedOpsProvider = StreamProvider<List<RejectedOp>>((ref) async* {
  final repo = await ref.watch(syncRejectedRepositoryProvider.future);
  yield* repo.watchAll();
});

/// Live count of rejections — the header badge and the account-screen entry
/// watch this. Defaults to 0 while the sync engine is still opening (or on
/// error), so callers can treat it as plain always-available state.
final syncNeedsFixCountProvider = StreamProvider<int>((ref) async* {
  final repo = await ref.watch(syncRejectedRepositoryProvider.future);
  yield* repo.watchCount();
});
