import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:powersync/powersync.dart';

import '../config/app_config.dart';
import 'powersync_schema.dart';

/// Bridges PowerSync to the BeekeepingIT backend (walking-skeleton.md §4.4):
///   - fetchCredentials → GET /v1/sync/token (the short-TTL sync token).
///   - uploadData       → POST /v1/sync/batch (the single write-back seam).
/// Both authenticate with the caller's Keycloak access token.
class BeekeepingitConnector extends PowerSyncBackendConnector {
  BeekeepingitConnector({required this.getAccessToken, http.Client? client})
    : _http = client ?? http.Client();

  final Future<String?> Function() getAccessToken;
  final http.Client _http;

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

    final ops = tx.crud.map(_toOp).toList();
    final resp = await _http.post(
      Uri.parse(AppConfig.syncBatchUrl),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'ops': ops}),
    );

    if (resp.statusCode == 200) {
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

  Map<String, dynamic> _toOp(CrudEntry e) {
    final data = e.opData;
    // Device edit time is the LWW comparator (sync.md §4.3). PUT/PATCH carry
    // it in `updated_at`; DELETE has no payload, so fall back to now (the
    // skeleton doesn't preserve offline-delete time — offline edits, which the
    // e2e exercises, do carry it).
    final updatedAt =
        (data?['updated_at'] as String?) ??
        DateTime.now().toUtc().toIso8601String();
    return {
      'op': _opName(e.op),
      'entity_type': apiaryEntityType,
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
}
