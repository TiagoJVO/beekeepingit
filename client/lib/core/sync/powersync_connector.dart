import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:powersync/powersync.dart';

import '../config/app_config.dart';
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

  /// Emits one event per op the server reports as `superseded` (sync.md
  /// §4.2/§8 — this offline edit lost a last-write-wins conflict). The shell
  /// listens to this to show a non-blocking "your change was overwritten"
  /// notification (#58's AC); nothing here decides *how* it's surfaced.
  final _superseded = StreamController<SupersededChange>.broadcast();
  Stream<SupersededChange> get supersededChanges => _superseded.stream;

  void dispose() => _superseded.close();

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

    if (resp.statusCode == 200) {
      _notifySuperseded(resp.body);
      await tx.complete();
      return;
    }
    if (resp.statusCode == 422 ||
        (resp.statusCode >= 400 && resp.statusCode < 500)) {
      // A client/validation error can't heal on retry. The user-facing
      // notify-and-fix flow is EPIC-06 (#58); the skeleton drops the op so
      // the queue doesn't wedge, and lets it be re-observed via the logs.
      await tx.complete();
      return;
    }
    // 5xx / network: leave queued so PowerSync's idempotent forward-retry
    // rolls it forward (sync.md §6.2).
    throw http.ClientException('sync batch failed: ${resp.statusCode}');
  }

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
    // Device edit time is the LWW comparator (sync.md §4.3). PUT/PATCH carry
    // it in `updated_at`; DELETE has no payload, so fall back to now (the
    // skeleton doesn't preserve offline-delete time — offline edits, which the
    // e2e exercises, do carry it).
    final updatedAt =
        (data?['updated_at'] as String?) ??
        DateTime.now().toUtc().toIso8601String();
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

  // Best-effort: a malformed/unexpected body must never fail the upload
  // itself (the transaction already completed server-side), so parse errors
  // are swallowed here rather than propagated.
  void _notifySuperseded(String body) {
    for (final change in parseSupersededChanges(body)) {
      _superseded.add(change);
    }
  }
}

/// Maps a queued CRUD entry's source table to its wire entity_type (#256:
/// the queue now carries two tables' writes — [apiariesTable] rows and
/// [apiaryCountersTable] rows — where before #256 everything was an apiary).
/// Any unrecognized table defaults to the apiary entity type, preserving the
/// previous hardcoded behavior for safety; a genuinely new syncable table
/// must add its own mapping here alongside its schema entry
/// (powersync_schema.dart). Top-level + `@visibleForTesting` so the dispatch
/// is unit-testable without a real PowerSync database.
@visibleForTesting
String entityTypeForTable(String table) => switch (table) {
  apiaryCountersTable => apiaryCounterEntityType,
  _ => apiaryEntityType,
};

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
