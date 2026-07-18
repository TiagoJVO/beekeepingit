import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:powersync/powersync.dart';
import 'package:uuid/uuid.dart';

import '../config/app_config.dart';
import 'local_store.dart';
import 'powersync_local_store.dart';
import 'powersync_schema.dart';
import 'sync_events.dart';

/// Bridges PowerSync to the BeekeepingIT backend (walking-skeleton.md §4.4):
///   - fetchCredentials → GET /v1/sync/token (the short-TTL sync token).
///   - uploadData       → POST /v1/sync/batch (the single write-back seam).
/// Both authenticate with the caller's OIDC access token.
class BeekeepingitConnector extends PowerSyncBackendConnector {
  BeekeepingitConnector({required this.getAccessToken, http.Client? client})
    : _http = client ?? http.Client();

  final Future<String?> Function() getAccessToken;
  final http.Client _http;
  static const _uuid = Uuid();

  /// Emits one event per op the server reports as `superseded` (sync.md
  /// §4.2/§8 — this offline edit lost a last-write-wins conflict). The shell
  /// listens to this to show a non-blocking "your change was overwritten"
  /// notification (#58's AC); nothing here decides *how* it's surfaced.
  final _superseded = StreamController<SupersededChange>.broadcast();
  Stream<SupersededChange> get supersededChanges => _superseded.stream;

  /// Emits one event per op in a push the server **permanently rejected** (a
  /// validation-class `4xx`; sync.md §8's `rejected` state, D-12). The op is
  /// also retained in the local `sync_rejected_ops` dead-letter
  /// (powersync_schema.dart) so it's recoverable — this stream is only the
  /// *notification* the shell (EPIC-06 #7) turns into a "needs fixing" notice.
  final _rejected = StreamController<RejectedChange>.broadcast();
  Stream<RejectedChange> get rejectedChanges => _rejected.stream;

  /// Per-delete-op device timestamps (MEDIUM finding: see [lwwTimestampFor]'s
  /// doc) — captured once per queued delete and reused across retries of the
  /// *same* op, cleared once that op leaves the upload queue
  /// ([_clearResolved]/[_retainRejected]).
  final _deleteTimestamps = <String, String>{};

  void dispose() {
    _superseded.close();
    _rejected.close();
    _http.close();
  }

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final token = await getAccessToken();
    if (token == null) return null; // logged out → stay disconnected

    final resp = await _http.get(
      Uri.parse(AppConfig.syncTokenUrl),
      headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
    );
    if (resp.statusCode != 200) {
      throw http.ClientException(
        'sync token request failed: ${resp.statusCode}',
      );
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return PowerSyncCredentials(
      endpoint: AppConfig.powerSyncUrl,
      token: json['token'] as String,
    );
  }

  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final tx = await database.getNextCrudTransaction();
    if (tx == null) return;

    final token = await getAccessToken();
    if (token == null) return; // will retry once authenticated

    final ops = <Map<String, dynamic>>[
      for (final e in tx.crud) await _toOp(database, e),
    ];
    final resp = await _http.post(
      Uri.parse(AppConfig.syncBatchUrl),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'ops': ops}),
    );

    await handleUploadResponse(
      status: resp.statusCode,
      body: resp.body,
      ops: ops,
      store: PowerSyncLocalStore(database),
      complete: () => tx.complete(),
    );
  }

  /// Decides what to do with the batch-apply response and acts on it —
  /// extracted from [uploadData] so the whole decision is unit-testable
  /// **without a real PowerSync database** (the same reason `_toOp`'s pure
  /// helpers are split out): a test drives it with a fake [LocalStoreEngine]
  /// and a [complete] closure, no `getNextCrudTransaction()` needed.
  ///
  /// - **`200`** — the push applied. Notify any `superseded` LWW losses
  ///   (§4.2/§8) and clear any dead-letter rows for the entities in this batch
  ///   (**clear-on-success**: a corrected re-save uploads a fresh op for the
  ///   same record, which resolves its earlier rejection), then `complete()`.
  /// - **`400`/`422`** — a validation-class rejection the identical bytes can't
  ///   heal on retry. **Retain** every op of the (atomic, all-or-nothing)
  ///   rejected push in the local dead-letter, **surface** each via
  ///   [rejectedChanges], then `complete()` so the queue advances — the op is
  ///   recoverable, not dropped, and the queue doesn't wedge (D-12, sync.md §8).
  /// - **anything else** (other `4xx`, `5xx`, network) — transient: `throw` to
  ///   leave the push queued for PowerSync's idempotent forward-retry
  ///   (sync.md §6.2). This deliberately no longer discards a recoverable
  ///   `401`/`403` the way the walking-skeleton's blanket `4xx` drop did.
  @visibleForTesting
  Future<void> handleUploadResponse({
    required int status,
    required String body,
    required List<Map<String, dynamic>> ops,
    required LocalStoreEngine store,
    required Future<void> Function() complete,
  }) async {
    final outcome = classifyUploadOutcome(status, body);
    switch (outcome.disposition) {
      case UploadDisposition.completed:
        _notifySuperseded(body);
        await _clearResolved(store, ops);
        await complete();
      case UploadDisposition.retain:
        await _retainRejected(store, ops, outcome.problem!);
        await complete();
      case UploadDisposition.retry:
        throw http.ClientException('sync batch failed: $status');
    }
  }

  /// Writes one dead-letter row per op of a rejected push and emits a
  /// [RejectedChange] for each. REPLACEs by server identity (delete-then-insert
  /// keyed on [dedupKeyColumn]) so re-rejecting the same record keeps one live
  /// entry — PowerSync's local schema has no unique constraints, matching
  /// `apiaries_repository`'s counter-upsert shape. Every op of the atomic push
  /// is retained (not just the field-flagged ones): the whole push rolled back
  /// server-side, so a valid op batched with an invalid one would otherwise be
  /// lost when the transaction completes.
  Future<void> _retainRejected(
    LocalStoreEngine store,
    List<Map<String, dynamic>> ops,
    RejectedProblem problem,
  ) async {
    for (var i = 0; i < ops.length; i++) {
      final op = ops[i];
      final entityType = op['entity_type'] as String;
      final dedupKey = _dedupKeyFor(op);
      final fixApiaryId = _fixApiaryIdFor(op);
      final errors = problem.fieldErrors.where((f) => f.opIndex == i).toList();
      final detail = jsonEncode({
        'detail': problem.detail,
        'errors': [
          for (final e in errors)
            {'field': e.field, 'code': e.code, 'message': e.message},
        ],
      });
      await store.execute(
        'DELETE FROM $rejectedOpsTable WHERE $dedupKeyColumn = ?',
        [dedupKey],
      );
      await store.execute(
        'INSERT INTO $rejectedOpsTable '
        '(id, entity_type, $dedupKeyColumn, fix_apiary_id, op, payload, '
        'error_code, error_detail, rejected_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          _uuid.v4(),
          entityType,
          dedupKey,
          fixApiaryId,
          op['op'] as String,
          jsonEncode(op),
          problem.code,
          detail,
          _nowIso(),
        ],
      );
      _rejected.add(
        RejectedChange(
          entityType: entityType,
          entityId: fixApiaryId,
          errorCode: problem.code,
        ),
      );
      // The op leaves the upload queue here (handleUploadResponse calls
      // complete() right after) — drop its cached delete timestamp, if any,
      // so the cache never outlives the op it was captured for.
      _deleteTimestamps.remove(op['id'] as String);
    }
  }

  /// Clear-on-success: deletes any dead-letter row for a record that just
  /// uploaded cleanly, so a corrected re-save auto-resolves its earlier
  /// rejection without the user having to dismiss it.
  Future<void> _clearResolved(
    LocalStoreEngine store,
    List<Map<String, dynamic>> ops,
  ) async {
    for (final op in ops) {
      await store.execute(
        'DELETE FROM $rejectedOpsTable WHERE $dedupKeyColumn = ?',
        [_dedupKeyFor(op)],
      );
      // Same cleanup as _retainRejected — the op left the queue successfully.
      _deleteTimestamps.remove(op['id'] as String);
    }
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();

  Future<Map<String, dynamic>> _toOp(
    PowerSyncDatabase database,
    CrudEntry e,
  ) async {
    var data = e.opData;
    // apiary_counter identity enrichment (#256): a local counter-value
    // UPDATE queues a `patch` whose opData carries only the CHANGED columns
    // (value, updated_at) — but the server identifies a counter by
    // (apiary_id, counter_type), never by the client row id (two devices'
    // rows for the same counter collapse into one server row, so ids don't
    // correlate — services/apiaries/api/sync.go's applyCounterOp). Re-attach
    // the identity columns from the local row so every counter op is
    // self-describing. If the local row is somehow gone by upload time (a
    // pathological purge/race), the op goes out as-is and the server's
    // validation rejects it with field-level detail — surfaced through the
    // existing 4xx handling above, never a silent wrong-row write.
    if (e.table == apiaryCountersTable &&
        data != null &&
        (data['apiary_id'] == null || data['counter_type'] == null)) {
      final row = await database.getOptional(
        'SELECT apiary_id, counter_type FROM $apiaryCountersTable WHERE id = ?',
        [e.id],
      );
      if (row != null) {
        data = {
          ...data,
          'apiary_id': data['apiary_id'] ?? row['apiary_id'],
          'counter_type': data['counter_type'] ?? row['counter_type'],
        };
      }
    }
    // activities `attributes` is stored locally as JSON-encoded TEXT
    // (activities_repository.dart's jsonEncode; PowerSync's local schema has no
    // JSON column type, powersync_schema.dart's activities table doc). Left
    // as-is, the queued opData carries it as a JSON *string*, but the activities
    // sync-apply/validate contract (services/activities/api/sync.go's
    // activityData.Attributes, matching the REST create shape in write.go)
    // expects a nested JSON object — so every offline-created/edited activity
    // was rejected on upload with "attributes must be a JSON object" (found by
    // live E2E testing of M3, EPIC-03/#39). Decode it back to an object here so
    // the wire op matches the server contract.
    data = decodeActivityAttributes(e.table, data);
    // Device edit time is the LWW comparator (sync.md §4.3) — see
    // [lwwTimestampFor]'s doc for why DELETE needs a per-op cache rather than
    // a bare `DateTime.now()` fallback.
    final updatedAt = lwwTimestampFor(e.id, data, _deleteTimestamps);
    return {
      'op': _opName(e.op),
      'entity_type': entityTypeForTable(e.table),
      'id': e.id,
      'data': data,
      'updated_at': updatedAt,
    };
  }

  String _opName(UpdateType op) => switch (op) {
    UpdateType.put => 'put',
    UpdateType.patch => 'patch',
    UpdateType.delete => 'delete',
  };

  /// The dead-letter row's **server identity** key (powersync_schema.dart's
  /// [rejectedOpsTable] doc): an `apiary_counter` op is keyed by
  /// `(apiary_id, counter_type)` — its stable server identity — because its
  /// local row id changes across a reject→fix cycle; every other op is keyed by
  /// its own id (the apiary id). Reads the enriched op payload `_toOp` built,
  /// so a counter op's `apiary_id`/`counter_type` are present.
  String _dedupKeyFor(Map<String, dynamic> op) {
    if (op['entity_type'] == apiaryCounterEntityType) {
      final data = op['data'] as Map<String, dynamic>?;
      return '${data?['apiary_id']}:${data?['counter_type']}';
    }
    return op['id'] as String;
  }

  /// The apiary the needs-fix "Fix" action deep-links to: the owning apiary id
  /// for an `apiary_counter` op, else the op's own (apiary) id. Falls back to
  /// the op id if a counter op somehow reached upload without its `apiary_id`
  /// enriched (the pathological purge/race `_toOp` documents).
  String _fixApiaryIdFor(Map<String, dynamic> op) {
    if (op['entity_type'] == apiaryCounterEntityType) {
      final data = op['data'] as Map<String, dynamic>?;
      return (data?['apiary_id'] as String?) ?? (op['id'] as String);
    }
    return op['id'] as String;
  }

  // Best-effort: a malformed/unexpected body must never fail the upload
  // itself (the transaction already completed server-side), so parse errors
  // are swallowed here rather than propagated.
  void _notifySuperseded(String body) {
    for (final change in parseSupersededChanges(body)) {
      _superseded.add(change);
    }
  }
}

/// The device-time LWW comparator a queued CRUD entry's wire op carries in
/// `updated_at` (sync.md §4.3). PUT/PATCH carry it in [data]'s own
/// `updated_at` (read straight through). DELETE has no payload
/// (`CrudEntry.opData` is null for a delete, per the `powersync` package's own
/// doc), so it falls back to a device timestamp — captured **once**, on the
/// first upload attempt of a given queued op, and **reused** on every later
/// call for that same still-queued op via [deleteTimestampCache] (keyed by
/// the CRUD entry's own id — a client-generated UUID, so it's stable and
/// unique across tables).
///
/// **MEDIUM finding this fixes:** the previous code recomputed
/// `DateTime.now()` on every call, including every retry of the *same*
/// queued delete (PowerSync's own idempotent forward-retry, sync.md §6.2)
/// — so a delete stuck retrying for a while kept getting an ever-later
/// timestamp purely from retry timing, which could let it spuriously "win" a
/// last-write-wins conflict against a genuinely newer concurrent edit.
/// Capturing the timestamp once and reusing it removes that drift.
///
/// **Scope of this fix:** [deleteTimestampCache] is owned by the connector
/// instance ([BeekeepingitConnector._deleteTimestamps]) and cleared once an
/// op leaves the upload queue ([BeekeepingitConnector._clearResolved]/
/// [BeekeepingitConnector._retainRejected]), so it fixes the realistic case —
/// the SDK's own fast in-session retry loop — without a local schema change.
/// It does **not** survive an app restart mid-retry (the cache is in-memory
/// only); the fully durable fix would persist the delete's device time on the
/// row itself at delete-time (e.g. via PowerSync's `Table.trackMetadata`
/// hidden `_metadata` column, captured before the row disappears) and read it
/// back here instead of a cache — tracked as a follow-up
/// (github.com/TiagoJVO/beekeepingit#276, under EPIC-06) rather than risked
/// in this PR, since it requires coordinated changes at every repository call
/// site that issues a delete.
///
/// `@visibleForTesting` and taking [deleteTimestampCache] as a parameter (not
/// reaching for connector state) so the once-per-id behavior is unit-testable
/// with a plain `Map`, no PowerSync database needed.
@visibleForTesting
String lwwTimestampFor(
  String entryId,
  Map<String, dynamic>? data,
  Map<String, String> deleteTimestampCache,
) {
  final fromPayload = data?['updated_at'] as String?;
  if (fromPayload != null) return fromPayload;
  return deleteTimestampCache.putIfAbsent(
    entryId,
    () => DateTime.now().toUtc().toIso8601String(),
  );
}

/// Maps a queued CRUD entry's source table to its wire entity_type (#256:
/// the queue now carries two tables' writes — [apiariesTable] rows and
/// [apiaryCountersTable] rows — where before #256 everything was an apiary;
/// #39 added a THIRD, [activitiesTable], and #50 a FOURTH, [todosTable],
/// each routed by services/sync/api/coordinator.go's groupOpsByOwner to a
/// DIFFERENT owning service (activities/todos, not apiaries) — getting this
/// mapping wrong would silently misroute every offline-created todo to
/// apiaries, which doesn't own that table and would reject it). Any
/// unrecognized table defaults to the apiary entity type, preserving the
/// previous hardcoded behavior for safety; a genuinely new syncable table
/// must add its own mapping here alongside its schema entry
/// (powersync_schema.dart). Top-level + `@visibleForTesting` so the
/// dispatch is unit-testable without a real PowerSync database.
@visibleForTesting
String entityTypeForTable(String table) => switch (table) {
  apiaryCountersTable => apiaryCounterEntityType,
  activitiesTable => activityEntityType,
  todosTable => todoEntityType,
  _ => apiaryEntityType,
};

/// Normalizes an [activitiesTable] op's `attributes` back to a nested JSON
/// object before it goes on the wire (#39, EPIC-03). The client stores
/// `attributes` as JSON-encoded TEXT (activities_repository.dart's `jsonEncode`
/// — PowerSync's local schema has no JSON column type, powersync_schema.dart's
/// activities table doc), so a queued CRUD op's `data['attributes']` is a
/// String. The activities sync-apply/validate contract expects an *object*
/// (services/activities/api/sync.go's `activityData.Attributes`, matching the
/// REST create shape in write.go) — uploaded as a string it was rejected with
/// "attributes must be a JSON object", so no offline activity ever reached the
/// server via the normal offline-first path (found by live E2E testing of M3).
///
/// Only rewrites when the value is actually a String, so it is a safe no-op for:
/// every non-activities table (apiaries/counters), a `delete` op (null [data]),
/// and a `patch` that didn't touch `attributes` (the column is simply absent
/// from opData). A `put` (full row) and a `patch` that changed `attributes`
/// both carry the String and get decoded. Top-level + `@visibleForTesting` so
/// the rewrite is unit-testable without a real PowerSync database, matching this
/// file's other pure seams ([entityTypeForTable]/[lwwTimestampFor]).
@visibleForTesting
Map<String, dynamic>? decodeActivityAttributes(
  String table,
  Map<String, dynamic>? data,
) {
  if (table != activitiesTable || data == null) return data;
  final attrs = data['attributes'];
  if (attrs is! String) return data;
  return {...data, 'attributes': jsonDecode(attrs)};
}

/// Parses the apply endpoint's `{"results": [{"id","op","result"}]}` body
/// (services/apiaries/api/sync.go's `ApplyResponse`) and returns one
/// [SupersededChange] per op the server reports as `superseded` (sync.md
/// §4.2/§8 — an offline edit that lost a last-write-wins conflict). A pure
/// function (no I/O) so it's unit-testable without a real HTTP call or
/// PowerSync database; returns an empty list for a malformed/unexpected body
/// rather than throwing, matching [BeekeepingitConnector.uploadData]'s
/// best-effort handling of this response.
///
/// entityType approximation (#256): the per-op result carries no entity_type
/// of its own, so a superseded `apiary_counter` op is also labeled with the
/// apiary entity type here. Today that distinction is invisible — the only
/// consumer (app_shell.dart's listener on supersededNotificationProvider)
/// shows one generic "your change was overwritten" toast regardless of
/// entity — so no extra response plumbing is warranted yet; when a
/// notify-and-fix UI needs per-entity fidelity (EPIC-06), add entity_type to
/// the server's OpResult (additive) and read it here.
@visibleForTesting
List<SupersededChange> parseSupersededChanges(String body) {
  try {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final results = json['results'] as List<dynamic>?;
    if (results == null) return const [];
    return [
      for (final r in results)
        if ((r as Map<String, dynamic>)['result'] == 'superseded')
          SupersededChange(
            entityType: apiaryEntityType,
            entityId: r['id'] as String,
          ),
    ];
  } catch (_) {
    return const [];
  }
}

/// What [BeekeepingitConnector.handleUploadResponse] should do with a batch
/// response: [completed] (applied — clear + complete), [retain] (a
/// validation-class rejection — dead-letter + surface + complete), or [retry]
/// (transient — leave queued).
enum UploadDisposition { completed, retain, retry }

/// The classified batch-upload outcome: a [disposition] plus, for [retain]
/// only, the parsed [RejectedProblem].
@immutable
class UploadOutcome {
  const UploadOutcome(this.disposition, [this.problem]);

  final UploadDisposition disposition;

  /// The parsed rejection detail — non-null iff [disposition] is
  /// [UploadDisposition.retain].
  final RejectedProblem? problem;
}

/// Classifies a batch-apply HTTP response into an [UploadOutcome]. Pure (no
/// I/O) and `@visibleForTesting` so the whole 4xx decision — the crux of the
/// data-loss fix — is unit-testable without a PowerSync database:
///
/// - `200` → [UploadDisposition.completed].
/// - `400`/`422` → [UploadDisposition.retain]: a validation-class client error
///   the identical bytes can't heal on retry (RFC 9457 `422` from the sync
///   coordinator's validate step, or a `400` malformed op). The offline edit is
///   retained + surfaced, not dropped (D-12, sync.md §8).
/// - **everything else** (other `4xx`, `5xx`, network) → [UploadDisposition.retry]:
///   transient — left queued for idempotent forward-retry (sync.md §6.2). A
///   `401`/`403` heals once a fresh token/permission arrives, so — unlike the
///   walking-skeleton's blanket-`4xx` drop — it is never discarded here.
@visibleForTesting
UploadOutcome classifyUploadOutcome(int status, String body) {
  if (status == 200) return const UploadOutcome(UploadDisposition.completed);
  if (status == 422 || status == 400) {
    return UploadOutcome(UploadDisposition.retain, parseRejectedProblem(body));
  }
  return const UploadOutcome(UploadDisposition.retry);
}

/// The parsed RFC 9457 problem body of a rejected push (services/servicetemplate/
/// problem's `Problem` shape): the machine [code], human [detail], and
/// per-field [fieldErrors].
@immutable
class RejectedProblem {
  const RejectedProblem({
    required this.code,
    required this.detail,
    required this.fieldErrors,
  });

  final String code;
  final String detail;
  final List<RejectedFieldError> fieldErrors;
}

/// One RFC 9457 field error, with the batch op it refers to resolved from the
/// server's `ops[<i>].<field>` field path ([opIndex] = `i`, [field] = the rest).
/// [opIndex] is null for a non-op-scoped field the client can't attribute.
@immutable
class RejectedFieldError {
  const RejectedFieldError({
    required this.opIndex,
    required this.field,
    required this.code,
    required this.message,
  });

  final int? opIndex;
  final String field;
  final String code;
  final String message;
}

/// Parses a `422`/`400` problem+json body into a [RejectedProblem]. Pure and
/// `@visibleForTesting`. Best-effort like [parseSupersededChanges]: a
/// malformed/unexpected body yields an **empty-detail** problem rather than
/// throwing — the op is still retained and surfaced (needs fixing), never lost
/// to a parse error.
@visibleForTesting
RejectedProblem parseRejectedProblem(String body) {
  try {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final rawErrors = json['errors'] as List<dynamic>?;
    return RejectedProblem(
      code: (json['code'] as String?) ?? '',
      detail: (json['detail'] as String?) ?? (json['title'] as String?) ?? '',
      fieldErrors: [
        for (final e in rawErrors ?? const [])
          if (e is Map<String, dynamic>) _rejectedFieldError(e),
      ],
    );
  } catch (_) {
    return const RejectedProblem(code: '', detail: '', fieldErrors: []);
  }
}

final _opFieldPrefix = RegExp(r'^ops\[(\d+)\]\.?(.*)$');

RejectedFieldError _rejectedFieldError(Map<String, dynamic> e) {
  final field = (e['field'] as String?) ?? '';
  final match = _opFieldPrefix.firstMatch(field);
  return RejectedFieldError(
    opIndex: match == null ? null : int.parse(match.group(1)!),
    field: match == null ? field : match.group(2)!,
    code: (e['code'] as String?) ?? '',
    message: (e['message'] as String?) ?? '',
  );
}
