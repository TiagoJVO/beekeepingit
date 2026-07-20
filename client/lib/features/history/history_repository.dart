import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/sync/local_store.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';

/// The kind of change one [HistoryEntry] records (history.md §3/§6).
///
/// [superseded] is not an `audit_log` row at all — it is a `sync_conflict_log`
/// LWW loss, folded into the same timeline ([supersededEventKind]). [unknown]
/// keeps this an *extensible* vocabulary rather than a closed enum, the same
/// D-20 convention `type`/`status`/`priority` already follow client-side: a
/// server that starts writing a new `change_type` must degrade to a generic
/// row here, never crash the timeline.
enum HistoryEventKind { created, updated, deleted, superseded, unknown }

/// Parses a server `event_kind` wire value. Unknown values map to
/// [HistoryEventKind.unknown] (see the enum's own doc) — never throw.
HistoryEventKind parseHistoryEventKind(String? raw) => switch (raw) {
  'create' => HistoryEventKind.created,
  'update' => HistoryEventKind.updated,
  'delete' => HistoryEventKind.deleted,
  supersededEventKind => HistoryEventKind.superseded,
  _ => HistoryEventKind.unknown,
};

/// One entry of a per-entity change timeline (FR-HIS-1, #60).
///
/// Deliberately source-agnostic: [HistoryRepository] builds the identical
/// shape from the local PowerSync tables (the offline path) and from the
/// owning service's REST history endpoint (the online fallback), so nothing
/// downstream — display helpers, widgets, tests — can tell the two apart.
///
/// [actorUserId] is an opaque internal user id, never a name: history rows
/// store no PII (history.md §7.3), so the display name is resolved
/// client-side against the org roster (`memberNamesProvider`) exactly as
/// activity attribution already is.
class HistoryEntry {
  const HistoryEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.kind,
    required this.recordedAt,
    this.actorUserId,
    this.occurredAt,
    this.changedFields = const [],
    this.change = const {},
  });

  final String id;
  final String entityType;
  final String entityId;
  final HistoryEventKind kind;

  /// Server time the change was committed — the timeline's ordering key
  /// (mirrors the owning services' `ListEntityTimeline` `ORDER BY`).
  final DateTime recordedAt;

  /// Device time of the change. Nullable: `sync_conflict_log.occurred_at` is
  /// a nullable column server-side (the losing edit may carry no device
  /// time), unlike `audit_log`'s.
  final DateTime? occurredAt;

  final String? actorUserId;

  /// Columns touched by an [HistoryEventKind.updated] row; empty for every
  /// other kind (the server writes NULL there).
  final List<String> changedFields;

  /// The raw payload, whose *shape depends on [kind]* (history.md §3 vs
  /// §4.2): a `{field: {from, to}}` delta for an audit row, and
  /// `{winning_payload, losing_payload, winner}` for a [superseded] one.
  /// Callers must branch on [kind] before interpreting it — [conflictWinner]
  /// is the one accessor that does so safely.
  final Map<String, dynamic> change;

  /// `'server'` or `'client'` for a [HistoryEventKind.superseded] row, else
  /// null — which side of the LWW comparison won (history.md §4.2).
  String? get conflictWinner {
    if (kind != HistoryEventKind.superseded) return null;
    final winner = change['winner'];
    return winner is String && winner.isNotEmpty ? winner : null;
  }
}

/// Reads per-entity history timelines (FR-HIS-1, #60, history.md §6/§8).
///
/// **Local-first, with an online fallback** — the two halves of this issue's
/// offline acceptance criterion, and the exact split the owning services'
/// `history.go` documents from the server side:
///
/// * [watchLocalTimeline] is the primary path. `audit_log` and
///   `sync_conflict_log` replicate down in full to every synced device
///   (infra/helm/beekeepingit/charts/powersync/values.yaml), so a synced
///   client renders history **offline**, live, with no network at all.
/// * [fetchRemoteTimeline] is the fallback for a device whose local slice is
///   empty — a fresh install, or one that has never synced. It is
///   best-effort by design (see its own doc).
///
/// The local read mirrors the server's `ListEntityTimeline` UNION query
/// rather than inventing a second shape, so both sources agree on ordering
/// and on what a "timeline" contains.
class HistoryRepository {
  HistoryRepository(this._store, this._api);

  final LocalStoreEngine _store;
  final ApiClient _api;

  /// Maps an `entity_type` to its owning service's REST history path prefix.
  ///
  /// Only entity types with a history **read endpoint** appear here (#60
  /// shipped apiaries' and activities'). An absent type simply has no online
  /// fallback — [fetchRemoteTimeline] returns empty rather than guessing a
  /// URL, so adding e.g. journeys (#315) or todos means adding its route
  /// here alongside the server endpoint, not changing this class's logic.
  static const _remotePathPrefix = <String, String>{
    apiaryEntityType: '/apiaries',
    activityEntityType: '/activities',
  };

  /// The combined local timeline for one entity, newest first.
  ///
  /// UNION ALL of the two local logs, mirroring the owning services'
  /// `ListEntityTimeline` query — including its synthetic
  /// [supersededEventKind] for conflict rows. Two differences from the
  /// server query, both deliberate:
  ///
  /// 1. **Newest first** (`recorded_at DESC`), where the REST endpoint
  ///    returns oldest-first. The detail-screen section renders a *capped*
  ///    preview (history_section.dart), so it must show the most recent
  ///    entries — an oldest-first cap would pin the view to the entity's
  ///    creation forever. [fetchRemoteTimeline] re-sorts to match.
  /// 2. The conflict payload is **not** assembled in SQL (the server uses
  ///    `jsonb_build_object`): its three columns are selected raw and
  ///    combined in [_fromRow], so this query needs no SQLite JSON
  ///    extension. The resulting [HistoryEntry.change] is identical either
  ///    way.
  ///
  /// Not org-scoped in SQL, matching `watchByApiary`'s convention in
  /// activities_repository.dart: the Sync Rule bucket is already org-scoped,
  /// so only this org's rows exist locally at all.
  Stream<List<HistoryEntry>> watchLocalTimeline({
    required String entityType,
    required String entityId,
  }) {
    return _store
        .watch(_timelineSql, [entityType, entityId, entityType, entityId])
        .map((rows) => rows.map(_fromRow).toList());
  }

  static const _timelineSql =
      'SELECT id, entity_type, entity_id, change_type AS event_kind, '
      'actor_user_id, occurred_at, recorded_at, changed_fields, change, '
      'NULL AS winning_payload, NULL AS losing_payload, NULL AS winner '
      'FROM $auditLogTable WHERE entity_type = ? AND entity_id = ? '
      'UNION ALL '
      "SELECT id, entity_type, entity_id, '$supersededEventKind' AS event_kind, "
      'actor_user_id, occurred_at, recorded_at, NULL AS changed_fields, '
      'NULL AS change, winning_payload, losing_payload, winner '
      'FROM $syncConflictLogTable WHERE entity_type = ? AND entity_id = ? '
      'ORDER BY recorded_at DESC, id DESC';

  /// One-shot online read of the deep timeline (history.md §6 "deep history
  /// is an online query"), newest first to match [watchLocalTimeline].
  ///
  /// **Best-effort**: any API or network failure yields an empty list rather
  /// than an error, the same deliberate convention `memberNamesProvider`
  /// uses. This is a *fallback* for a device with no local slice — an
  /// offline device legitimately has neither source, and that is an empty
  /// history, not a broken screen.
  Future<List<HistoryEntry>> fetchRemoteTimeline({
    required String entityType,
    required String entityId,
  }) async {
    final prefix = _remotePathPrefix[entityType];
    if (prefix == null) return const [];
    try {
      final json = await _api.getJson('$prefix/$entityId/history');
      final data = json['data'];
      if (data is! List) return const [];
      final entries = data
          .whereType<Map<String, dynamic>>()
          .map(_fromRow)
          .toList();
      entries.sort((a, b) => b.recordedAt.compareTo(a.recordedAt));
      return entries;
    } on ApiException {
      return const [];
    } on ApiNetworkException {
      return const [];
    }
  }

  /// Maps one row — local SQL or decoded REST JSON, whose column/field names
  /// are the same by construction — to a [HistoryEntry].
  ///
  /// Every field is read defensively. The two sources render the same server
  /// types differently (a local `TEXT[]`/`JSONB` column arrives as
  /// JSON-encoded text, while REST delivers a real list/object), and an
  /// unparseable value must degrade that one field, never drop the entry: a
  /// history row the user cannot fully interpret still tells them *that*
  /// something changed, and when.
  static HistoryEntry _fromRow(Map<String, Object?> r) {
    final kind = parseHistoryEventKind(r['event_kind'] as String?);
    return HistoryEntry(
      id: r['id'] as String? ?? '',
      entityType: r['entity_type'] as String? ?? '',
      entityId: r['entity_id'] as String? ?? '',
      kind: kind,
      recordedAt:
          _dateTime(r['recorded_at']) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      occurredAt: _dateTime(r['occurred_at']),
      actorUserId: _optional(r['actor_user_id'] as String?),
      changedFields: _stringList(r['changed_fields']),
      change: kind == HistoryEventKind.superseded
          ? _conflictChange(r)
          : _jsonMap(r['change']),
    );
  }

  /// Rebuilds the `{winning_payload, losing_payload, winner}` shape the
  /// server's `ListEntityTimeline` assembles in SQL, so a locally-read
  /// conflict row is indistinguishable from a REST-read one. When the row
  /// already carries a `change` object (the REST source), that wins.
  static Map<String, dynamic> _conflictChange(Map<String, Object?> r) {
    final existing = _jsonMap(r['change']);
    if (existing.isNotEmpty) return existing;
    return {
      'winning_payload': _jsonMap(r['winning_payload']),
      'losing_payload': _jsonMap(r['losing_payload']),
      if (r['winner'] != null) 'winner': r['winner'],
    };
  }

  static String? _optional(String? v) => (v == null || v.isEmpty) ? null : v;

  static DateTime? _dateTime(Object? v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toLocal();
  }

  /// A server `TEXT[]`: a real `List` over REST, JSON-encoded text locally.
  static List<String> _stringList(Object? v) {
    if (v is List) return v.whereType<String>().toList();
    if (v is! String || v.isEmpty) return const [];
    final decoded = _tryDecode(v);
    return decoded is List ? decoded.whereType<String>().toList() : const [];
  }

  /// A server `JSONB`: a real `Map` over REST, JSON-encoded text locally.
  static Map<String, dynamic> _jsonMap(Object? v) {
    if (v is Map<String, dynamic>) return v;
    if (v is Map) return v.map((k, val) => MapEntry('$k', val));
    if (v is! String || v.isEmpty) return const {};
    final decoded = _tryDecode(v);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) return decoded.map((k, val) => MapEntry('$k', val));
    return const {};
  }

  static Object? _tryDecode(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}

/// Identifies the entity whose timeline to read — the family key for
/// [entityHistoryProvider].
///
/// A value class (not a bare record) so it carries the equality a Riverpod
/// `family` needs to dedupe/cache per target: two watches of the same
/// entity must share one subscription.
class HistoryTarget {
  const HistoryTarget({required this.entityType, required this.entityId});

  final String entityType;
  final String entityId;

  @override
  bool operator ==(Object other) =>
      other is HistoryTarget &&
      other.entityType == entityType &&
      other.entityId == entityId;

  @override
  int get hashCode => Object.hash(entityType, entityId);
}

final historyRepositoryProvider = FutureProvider<HistoryRepository>((
  ref,
) async {
  final session = await ref.watch(powerSyncProvider.future);
  return HistoryRepository(
    PowerSyncLocalStore(session.db),
    ref.watch(apiClientProvider),
  );
});

/// The per-entity timeline, local-first with a one-shot online fallback.
///
/// The local stream always wins while it has rows. Only when it is empty —
/// a device that has not synced this entity's history — does this fetch the
/// REST timeline, and only **once** per provider lifetime: the result is
/// cached so a later empty local emission re-yields it instead of
/// re-querying the network on every change notification.
final entityHistoryProvider = StreamProvider.autoDispose
    .family<List<HistoryEntry>, HistoryTarget>((ref, target) async* {
      final repo = await ref.watch(historyRepositoryProvider.future);
      var triedRemote = false;
      var remote = const <HistoryEntry>[];
      await for (final local in repo.watchLocalTimeline(
        entityType: target.entityType,
        entityId: target.entityId,
      )) {
        if (local.isNotEmpty) {
          yield local;
          continue;
        }
        if (!triedRemote) {
          triedRemote = true;
          remote = await repo.fetchRemoteTimeline(
            entityType: target.entityType,
            entityId: target.entityId,
          );
        }
        yield remote;
      }
    });
