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
  });

  /// The dead-letter row id — the handle the "Dismiss" action deletes by.
  final String id;

  /// `apiary` | `apiary_counter` — drives the entity label the list shows.
  final String entityType;

  /// The apiary the "Fix" action deep-links to (`/apiaries/<id>/edit`): the
  /// apiary id for an `apiary` rejection, the owning apiary's id for an
  /// `apiary_counter` one (powersync_schema.dart's `fix_apiary_id`).
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

  /// The single most useful human line for the list row: the first field error
  /// if any, else the problem detail. May be empty (the screen falls back to a
  /// generic localized message then).
  String get primaryMessage =>
      fieldErrors.isNotEmpty ? fieldErrors.first : detail;
}

/// Reads and dismisses rejected-op dead-letter rows against the local store
/// (NFR-ARC-2, #55: behind [LocalStoreEngine], never a concrete engine type).
/// Mirrors `ApiariesRepository`'s shape — a thin watch/list/delete surface over
/// the same `sync_rejected_ops` table the connector writes.
class SyncRejectedRepository {
  SyncRejectedRepository(this._store);

  final LocalStoreEngine _store;

  static const _columns =
      'id, entity_type, fix_apiary_id, op, error_code, error_detail';

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
    return RejectedOp(
      id: r['id'] as String,
      entityType: r['entity_type'] as String,
      fixApiaryId: r['fix_apiary_id'] as String,
      op: r['op'] as String,
      errorCode: r['error_code'] as String? ?? '',
      fieldErrors: parsed.$1,
      detail: parsed.$2,
    );
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
