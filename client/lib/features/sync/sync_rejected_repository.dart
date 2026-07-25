import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/sync/local_store.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';

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
    required this.fieldErrors,
    required this.detail,
    this.displayName,
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

  /// RFC 9457 problem `code` (e.g. `validation.failed`), or `''`.
  final String errorCode;

  /// Field-level messages the server returned for this op, in order — what the
  /// user actually has to fix. Empty when the op was collateral in an atomic
  /// push (valid itself, rolled back because a sibling op failed) or the body
  /// carried no field detail.
  final List<String> fieldErrors;

  /// The problem's human `detail`, shown when there are no field-level messages.
  final String detail;

  /// The single most useful raw server line for this rejection: the first field
  /// error if any, else the problem detail. May be empty.
  ///
  /// **Diagnostics only — never render this to the user (#426).** It is the
  /// server's English-only validation text and can embed internal DB
  /// field/column names (e.g. "default_attributes must be a JSON object"),
  /// which both breaks EN/PT i18n and leaks technical terms into the UI. The
  /// needs-fix screen shows a localized, non-technical message instead; this
  /// getter is kept for logs/diagnostics (the raw detail also stays persisted
  /// in the dead-letter row's `error_detail` column).
  String get primaryMessage =>
      fieldErrors.isNotEmpty ? fieldErrors.first : detail;

  /// The record's own name/title, read from the rejected op's stored
  /// `payload` (#379, fix plan item 4): `name` for a journey (and apiary),
  /// `title` for a todo, `type` for an activity. Null when the payload
  /// carried no such field (or, for `journey_plan_item`, never — a plan item
  /// has no name of its own) — the needs-fix row then shows just the plain
  /// entity label.
  final String? displayName;

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
    final parsed = _parseDetail(r['error_detail'] as String?);
    final entityType = r['entity_type'] as String;
    final payloadData = _parsePayloadData(r['payload'] as String?);
    return RejectedOp(
      id: r['id'] as String,
      entityType: entityType,
      fixApiaryId: r['fix_apiary_id'] as String,
      op: r['op'] as String,
      errorCode: r['error_code'] as String? ?? '',
      fieldErrors: parsed.$1,
      detail: parsed.$2,
      displayName: _displayNameFor(entityType, payloadData),
      journeyId: payloadData?['journey_id'] as String?,
    );
  }

  /// Reads the op's own `data` (the record's field values at rejection time)
  /// out of the connector's stored `payload` column — the full JSON-encoded
  /// wire op (powersync_connector.dart's `_toOp` shape:
  /// `{op, entity_type, id, data, updated_at}`), so the interesting fields
  /// live one level down under `data`. Tolerant of a missing/malformed
  /// value, matching [_parseDetail]'s own best-effort parsing — a
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
  /// 4): `name` for a journey or apiary, `title` for a todo, `type` for an
  /// activity. `journey_plan_item` has no name of its own, so it's excluded
  /// (falls through to null). Only ever returns a non-empty [String] — a
  /// missing/wrong-typed/blank field yields null, so the caller can treat
  /// "has a display name" as a simple null check.
  String? _displayNameFor(String entityType, Map<String, dynamic>? data) {
    if (data == null) return null;
    final value = switch (entityType) {
      apiaryEntityType || journeyEntityType => data['name'],
      todoEntityType => data['title'],
      activityEntityType => data['type'],
      _ => null,
    };
    return (value is String && value.isNotEmpty) ? value : null;
  }

  /// Parses the connector's stored `error_detail` JSON
  /// (`{ detail, errors: [{field, code, message}] }`) into (field messages,
  /// detail). Tolerant of a malformed/absent value — the row must still render
  /// (with a generic message) rather than throw, matching the connector's own
  /// best-effort parsing.
  (List<String>, String) _parseDetail(String? raw) {
    if (raw == null || raw.isEmpty) return (const [], '');
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final errors = json['errors'] as List<dynamic>?;
      final messages = <String>[
        for (final e in errors ?? const [])
          if (e is Map<String, dynamic> && (e['message'] as String?) != null)
            e['message'] as String,
      ];
      return (messages, (json['detail'] as String?) ?? '');
    } catch (_) {
      return (const [], '');
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
