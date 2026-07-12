import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:powersync/powersync.dart';
import 'package:powersync/sqlite3_common.dart';
import 'package:uuid/uuid.dart';

import '../../core/geo/distance.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';

/// A local apiary row (the slice's trivial record — name + hive count, plus
/// the optional location synced down for offline proximity ordering FR-AP-2,
/// #33). `locationLon`/`locationLat` are null exactly when the apiary has no
/// location set server-side (powersync_schema.dart's doc comment).
class Apiary {
  const Apiary({
    required this.id,
    required this.name,
    required this.hiveCount,
    this.locationLon,
    this.locationLat,
  });

  final String id;
  final String name;
  final int hiveCount;
  final double? locationLon;
  final double? locationLat;

  bool get hasLocation => locationLon != null && locationLat != null;
}

/// Reads and writes apiaries against the local PowerSync SQLite. Every write
/// is local-first and queued for the write-back seam (walking-skeleton.md
/// §4.4); the client never calls the apiaries REST write API directly. The
/// server derives `organization_id` from the token, so writes here omit it.
class ApiariesRepository {
  ApiariesRepository(this._db);

  final PowerSyncDatabase _db;
  static const _uuid = Uuid();

  Stream<List<Apiary>> watchAll() {
    return _db
        .watch(
          'SELECT id, name, hive_count, location_lon, location_lat FROM $apiariesTable '
          'ORDER BY created_at DESC, name',
        )
        .map((rs) => rs.map(_fromRow).toList());
  }

  Future<Apiary?> getById(String id) async {
    final row = await _db.getOptional(
      'SELECT id, name, hive_count, location_lon, location_lat FROM $apiariesTable WHERE id = ?',
      [id],
    );
    return row == null ? null : _fromRow(row);
  }

  Future<String> create({required String name, required int hiveCount}) async {
    final id = _uuid.v4();
    final now = _nowIso();
    await _db.execute(
      'INSERT INTO $apiariesTable (id, name, hive_count, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [id, name, hiveCount, now, now],
    );
    return id;
  }

  Future<void> update(String id, {String? name, int? hiveCount}) async {
    final current = await getById(id);
    if (current == null) return;
    await _db.execute(
      'UPDATE $apiariesTable SET name = ?, hive_count = ?, updated_at = ? WHERE id = ?',
      [name ?? current.name, hiveCount ?? current.hiveCount, _nowIso(), id],
    );
  }

  Future<void> delete(String id) =>
      _db.execute('DELETE FROM $apiariesTable WHERE id = ?', [id]);

  Apiary _fromRow(Row r) => Apiary(
    id: r['id'] as String,
    name: r['name'] as String,
    hiveCount: (r['hive_count'] as int?) ?? 0,
    locationLon: (r['location_lon'] as num?)?.toDouble(),
    locationLat: (r['location_lat'] as num?)?.toDouble(),
  );

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

final apiariesRepositoryProvider = FutureProvider<ApiariesRepository>((
  ref,
) async {
  final session = await ref.watch(powerSyncProvider.future);
  return ApiariesRepository(session.db);
});

/// Live list of the org's apiaries, straight from local SQLite (offline-first).
final apiariesStreamProvider = StreamProvider<List<Apiary>>((ref) async* {
  final repo = await ref.watch(apiariesRepositoryProvider.future);
  yield* repo.watchAll();
});

/// Client-side search over the locally-synced apiary set (FR-AP-6, D-17:
/// client-side, apiaries-only, matches on name and location). There is no
/// free-text location/address field on an apiary yet (just the GeoPoint,
/// #33's own scope) — the coordinates aren't meaningful to match against a
/// typed query, so "search by location" currently has nothing textual to
/// search against and this only matches [Apiary.name]. Case-insensitive,
/// substring match (not prefix-only) so "orte" matches "Encosta Norte".
/// An empty/whitespace-only query returns [apiaries] unfiltered.
List<Apiary> filterApiariesByQuery(List<Apiary> apiaries, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return apiaries;
  return apiaries.where((a) => a.name.toLowerCase().contains(needle)).toList();
}

/// Offline proximity ordering (FR-AP-2, #33 AC: "the list works offline
/// using the locally synced apiary set and an offline distance
/// computation"): sorts [apiaries] ascending by haversine distance
/// (core/geo/distance.dart, consistent with D-15/#37's approach) from
/// (originLon, originLat). Apiaries without a location sort after every
/// apiary that has one (mirrors the server's `near` ordering, NULLS LAST —
/// api/apiaries.go's ListApiariesByProximity), staying in their relative
/// (name) order among themselves.
List<Apiary> sortApiariesByDistance(
  List<Apiary> apiaries, {
  required double originLon,
  required double originLat,
}) {
  final withLocation = apiaries.where((a) => a.hasLocation).toList()
    ..sort(
      (a, b) =>
          haversineDistanceMeters(
            lon1: originLon,
            lat1: originLat,
            lon2: a.locationLon!,
            lat2: a.locationLat!,
          ).compareTo(
            haversineDistanceMeters(
              lon1: originLon,
              lat1: originLat,
              lon2: b.locationLon!,
              lat2: b.locationLat!,
            ),
          ),
    );
  final withoutLocation = apiaries.where((a) => !a.hasLocation).toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return [...withLocation, ...withoutLocation];
}

/// The deterministic fallback ordering (#33 AC: "when location is
/// unavailable or denied, the list falls back to a deterministic order
/// (e.g. by name)") — alphabetical by name, used when the device location
/// isn't available rather than leaving the (arbitrary, sync-order-dependent)
/// [ApiariesRepository.watchAll] ordering in place.
List<Apiary> sortApiariesByName(List<Apiary> apiaries) {
  return [...apiaries]..sort((a, b) => a.name.compareTo(b.name));
}
