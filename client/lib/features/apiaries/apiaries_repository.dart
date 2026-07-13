import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/geo/distance.dart';
import '../../core/sync/local_store.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';

/// A local apiary row (name + hive count + optional free-text notes,
/// FR-AP-8/#196 + optional location). Location is nullable (#33/#34/#37,
/// FR-AP-2/FR-AP-3/FR-AP-5): older/incomplete records or apiaries created
/// without a map pin have no coordinates, and callers (offline proximity
/// ordering, the map screen, the offline distance calculation) must
/// skip/handle that case rather than assume every apiary is located.
/// `locationLon`/`locationLat` are null exactly when the apiary has no
/// location set server-side (powersync_schema.dart's doc comment).
class Apiary {
  const Apiary({
    required this.id,
    required this.name,
    required this.hiveCount,
    this.locationLon,
    this.locationLat,
    this.notes,
  });

  final String id;
  final String name;
  final int hiveCount;
  final double? locationLon;
  final double? locationLat;
  final String? notes;

  bool get hasLocation => locationLon != null && locationLat != null;
}

/// Reads and writes apiaries against the local store (NFR-ARC-2, #55: behind
/// [LocalStoreEngine], never a concrete engine type like `PowerSyncDatabase`
/// directly, so the sync engine can be swapped without rewriting this file).
/// Every write is local-first and queued for the write-back seam
/// (walking-skeleton.md §4.4); the client never calls the apiaries REST
/// write API directly. The server derives `organization_id` from the token,
/// so writes here omit it.
class ApiariesRepository {
  ApiariesRepository(this._store);

  final LocalStoreEngine _store;
  static const _uuid = Uuid();

  Stream<List<Apiary>> watchAll() {
    return _store
        .watch(
          'SELECT id, name, hive_count, notes, location_lon, location_lat '
          'FROM $apiariesTable ORDER BY created_at DESC, name',
        )
        .map((rows) => rows.map(_fromRow).toList());
  }

  Future<Apiary?> getById(String id) async {
    final row = await _store.getOptional(
      'SELECT id, name, hive_count, notes, location_lon, location_lat '
      'FROM $apiariesTable WHERE id = ?',
      [id],
    );
    return row == null ? null : _fromRow(row);
  }

  Future<String> create({
    required String name,
    required int hiveCount,
    String? notes,
  }) async {
    final id = _uuid.v4();
    final now = _nowIso();
    await _store.execute(
      'INSERT INTO $apiariesTable (id, name, hive_count, notes, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [id, name, hiveCount, notes, now, now],
    );
    return id;
  }

  /// Updates the given fields of an existing apiary. `notes` uses a
  /// present-vs-absent sentinel via [notesProvided] (rather than treating
  /// null as "leave unchanged") so a caller can explicitly clear notes back
  /// to empty — mirroring the server's PATCH semantics (write.go's
  /// `notesSet`/`fields["notes"]` presence check).
  Future<void> update(
    String id, {
    String? name,
    int? hiveCount,
    String? notes,
    bool notesProvided = false,
  }) async {
    final current = await getById(id);
    if (current == null) return;
    await _store.execute(
      'UPDATE $apiariesTable SET name = ?, hive_count = ?, notes = ?, updated_at = ? WHERE id = ?',
      [
        name ?? current.name,
        hiveCount ?? current.hiveCount,
        notesProvided ? notes : current.notes,
        _nowIso(),
        id,
      ],
    );
  }

  Future<void> delete(String id) =>
      _store.execute('DELETE FROM $apiariesTable WHERE id = ?', [id]);

  Apiary _fromRow(Map<String, Object?> r) => Apiary(
    id: r['id'] as String,
    name: r['name'] as String,
    hiveCount: (r['hive_count'] as int?) ?? 0,
    locationLon: (r['location_lon'] as num?)?.toDouble(),
    locationLat: (r['location_lat'] as num?)?.toDouble(),
    notes: r['notes'] as String?,
  );

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

final apiariesRepositoryProvider = FutureProvider<ApiariesRepository>((
  ref,
) async {
  final session = await ref.watch(powerSyncProvider.future);
  return ApiariesRepository(PowerSyncLocalStore(session.db));
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
