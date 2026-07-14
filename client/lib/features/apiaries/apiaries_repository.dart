import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/geo/distance.dart';
import '../../core/l10n/diacritics.dart';
import '../../core/sync/local_store.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';
import 'counter_types.dart';

/// A local apiary row (name + hive count + optional free-text notes,
/// FR-AP-8/#196 + optional location + optional place label, #252).
/// Location is nullable (#33/#34/#37, FR-AP-2/FR-AP-3/FR-AP-5):
/// older/incomplete records or apiaries created without a map pin have no
/// coordinates, and callers (offline proximity ordering, the map screen, the
/// offline distance calculation) must skip/handle that case rather than
/// assume every apiary is located. `locationLon`/`locationLat` are null
/// exactly when the apiary has no location set server-side
/// (powersync_schema.dart's doc comment). `placeLabel` (#252) is an
/// independent optional free-text place name (e.g. "Montargil") — unrelated
/// to the coordinates and to the apiary's own [name]; used by the detail
/// screen and by #254's search.
///
/// [hiveCount] (#256) is no longer a column on the local apiaries table — it
/// is resolved from the apiary's `hive` counter row (apiary_counters, the
/// typed 1-N counters table) at read time, defaulting to 0 when no row
/// exists. The model keeps the plain field so every consumer (list row,
/// detail badge, map marker) is untouched by the decoupling.
class Apiary {
  const Apiary({
    required this.id,
    required this.name,
    required this.hiveCount,
    this.locationLon,
    this.locationLat,
    this.placeLabel,
    this.notes,
  });

  final String id;
  final String name;
  final int hiveCount;
  final double? locationLon;
  final double? locationLat;
  final String? placeLabel;
  final String? notes;

  bool get hasLocation => locationLon != null && locationLat != null;
}

/// One typed counter row of an apiary (#256, FR-AP-7): the client-side
/// mirror of `apiaries.apiary_counters`. [counterType] is one of
/// [knownCounterTypes] for rows this client writes; rows replicated from a
/// newer server may carry types this version doesn't know yet — consumers
/// (the detail screen's generic counters rendering) skip those rather than
/// fail (counter_types.dart's [counterValueLabel]).
class ApiaryCounter {
  const ApiaryCounter({
    required this.apiaryId,
    required this.counterType,
    required this.value,
  });

  final String apiaryId;
  final String counterType;
  final int value;
}

/// Reads and writes apiaries against the local store (NFR-ARC-2, #55: behind
/// [LocalStoreEngine], never a concrete engine type like `PowerSyncDatabase`
/// directly, so the sync engine can be swapped without rewriting this file).
/// Every write is local-first and queued for the write-back seam
/// (walking-skeleton.md §4.4); the client never calls the apiaries REST
/// write API directly. The server derives `organization_id` from the token,
/// so writes here omit it.
///
/// hive count (#256): reads resolve it via a correlated subquery over the
/// local apiary_counters table (0 when no `hive` row exists — the #256
/// "always displays, 0 default" rule at the data layer); writes go to the
/// counter row (insert-or-update by (apiary_id, counter_type), the client
/// half of the server's upsert semantics), never to an apiaries column.
/// A subquery rather than a LEFT JOIN keeps the result one-row-per-apiary
/// even during the brief optimistic window where a locally-created counter
/// row and its server-authoritative replacement (different row id, same
/// (apiary_id, counter_type)) can coexist before PowerSync reconciles —
/// `ORDER BY updated_at DESC LIMIT 1` deterministically prefers the newest.
class ApiariesRepository {
  ApiariesRepository(this._store);

  final LocalStoreEngine _store;
  static const _uuid = Uuid();

  static const _hiveCountSubquery =
      '(SELECT hc.value FROM $apiaryCountersTable hc '
      'WHERE hc.apiary_id = a.id AND hc.counter_type = \'$counterTypeHive\' '
      'ORDER BY hc.updated_at DESC LIMIT 1)';

  Stream<List<Apiary>> watchAll() {
    return _store
        .watch(
          'SELECT a.id, a.name, a.notes, a.place_label, a.location_lon, a.location_lat, '
          'COALESCE($_hiveCountSubquery, 0) AS hive_count '
          'FROM $apiariesTable a ORDER BY a.created_at DESC, a.name',
        )
        .map((rows) => rows.map(_fromRow).toList());
  }

  Future<Apiary?> getById(String id) async {
    final row = await _store.getOptional(
      'SELECT a.id, a.name, a.notes, a.place_label, a.location_lon, a.location_lat, '
      'COALESCE($_hiveCountSubquery, 0) AS hive_count '
      'FROM $apiariesTable a WHERE a.id = ?',
      [id],
    );
    return row == null ? null : _fromRow(row);
  }

  /// The apiary's counter rows (#256), newest-per-type (deduplicated the
  /// same way [_hiveCountSubquery] resolves the hive value, for the same
  /// optimistic-window reason), ordered with [knownCounterTypes] first (in
  /// that list's order) and any unknown newer-server types after. The detail
  /// screen renders these generically — hive always (0 default via
  /// [Apiary.hiveCount]), other known types only when a row exists here.
  Stream<List<ApiaryCounter>> watchCountersFor(String apiaryId) {
    return _store
        .watch(
          'SELECT apiary_id, counter_type, value, updated_at '
          'FROM $apiaryCountersTable WHERE apiary_id = ? '
          'ORDER BY updated_at DESC',
          [apiaryId],
        )
        .map(_countersFromRows);
  }

  /// Creates an apiary. [locationLon]/[locationLat] (#252) are both-or-
  /// neither — a location-less create passes both null (the pre-#252
  /// default), matching the server's REST/sync-apply "both valid or both
  /// NULL" convention (api/geo.go's geoPointInput, api/sync.go's
  /// apiaryData doc comment) so the queued op never carries a lone lon or
  /// lat. [placeLabel] (#252) is independent free-text, alongside [notes].
  Future<String> create({
    required String name,
    required int hiveCount,
    String? notes,
    String? placeLabel,
    double? locationLon,
    double? locationLat,
  }) async {
    final id = _uuid.v4();
    final now = _nowIso();
    // Apiary row first, its hive counter second: PowerSync uploads queued
    // ops in local write order, and the server's counter apply references
    // the apiary row (FK) — this ordering guarantees the parent exists by
    // the time the counter op applies.
    await _store.execute(
      'INSERT INTO $apiariesTable '
      '(id, name, notes, place_label, location_lon, location_lat, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [id, name, notes, placeLabel, locationLon, locationLat, now, now],
    );
    await _insertCounter(id, counterTypeHive, hiveCount, now);
    return id;
  }

  /// Updates the given fields of an existing apiary. `notes`/`placeLabel`
  /// use a present-vs-absent sentinel via [notesProvided]/[placeLabelProvided]
  /// (rather than treating null as "leave unchanged") so a caller can
  /// explicitly clear either back to empty — mirroring the server's PATCH
  /// semantics (write.go's `notesSet`/`fields["notes"]` presence check,
  /// mirrored for `place_label`).
  ///
  /// Location (#252) uses its own [locationProvided] sentinel rather than a
  /// plain nullable pair: `null` lon/lat is itself a meaningful value
  /// ("clear the location", the form's own clear affordance), so "the
  /// caller didn't touch location at all" needs a THIRD state a bare
  /// nullable pair can't express — the same reason [notesProvided] exists
  /// for `notes` rather than treating its own null as ambiguous.
  ///
  /// Writes are change-scoped (#256): the apiaries row is written only when
  /// name/notes/place_label/location actually change, and the hive counter
  /// row only when [hiveCount] is provided and differs — so a hive-only edit
  /// queues one counter op (and never bumps the apiary row's LWW stamp), and
  /// a name-only edit never touches the counter (whose own LWW stamp would
  /// otherwise supersede another device's pending offline hive edit). This
  /// is the client half of what decoupling the counter buys: name and hive
  /// edits from different devices no longer collide on one record
  /// (sync.md §4.4's lossy case, resolved for hive by #256).
  Future<void> update(
    String id, {
    String? name,
    int? hiveCount,
    String? notes,
    bool notesProvided = false,
    String? placeLabel,
    bool placeLabelProvided = false,
    double? locationLon,
    double? locationLat,
    bool locationProvided = false,
  }) async {
    final current = await getById(id);
    if (current == null) return;

    final newName = name ?? current.name;
    final newNotes = notesProvided ? notes : current.notes;
    final newPlaceLabel = placeLabelProvided ? placeLabel : current.placeLabel;
    final newLon = locationProvided ? locationLon : current.locationLon;
    final newLat = locationProvided ? locationLat : current.locationLat;
    if (newName != current.name ||
        newNotes != current.notes ||
        newPlaceLabel != current.placeLabel ||
        newLon != current.locationLon ||
        newLat != current.locationLat) {
      await _store.execute(
        'UPDATE $apiariesTable SET name = ?, notes = ?, place_label = ?, '
        'location_lon = ?, location_lat = ?, updated_at = ? WHERE id = ?',
        [newName, newNotes, newPlaceLabel, newLon, newLat, _nowIso(), id],
      );
    }

    if (hiveCount != null && hiveCount != current.hiveCount) {
      await _upsertCounter(id, counterTypeHive, hiveCount);
    }
  }

  /// Deletes the apiary row only. Its local counter rows are deliberately
  /// left in place: counters have no delete op (the owning service rejects
  /// one — a counter has no lifecycle apart from its apiary), so deleting
  /// them locally would queue ops the server refuses, wedging the batch.
  /// They become invisible immediately (every read resolves counters
  /// through the apiary row, which is gone) and inert — mirroring the
  /// server's own soft-delete treatment, where a tombstoned apiary's
  /// counter rows survive unreferenced.
  Future<void> delete(String id) =>
      _store.execute('DELETE FROM $apiariesTable WHERE id = ?', [id]);

  /// Insert-or-update of one counter row by (apiary_id, counter_type) — the
  /// client half of #256's "enforce the uniqueness by upsert semantics".
  /// PowerSync's local schema has no unique constraints, so the uniqueness
  /// is maintained by this look-up-then-write shape (single-writer local UI,
  /// no concurrency to race) and authoritatively by the server's ON CONFLICT
  /// upsert keyed the same way.
  Future<void> _upsertCounter(
    String apiaryId,
    String counterType,
    int value,
  ) async {
    final existing = await _store.getOptional(
      'SELECT id FROM $apiaryCountersTable WHERE apiary_id = ? AND counter_type = ? '
      'ORDER BY updated_at DESC LIMIT 1',
      [apiaryId, counterType],
    );
    final now = _nowIso();
    if (existing == null) {
      await _insertCounter(apiaryId, counterType, value, now);
      return;
    }
    await _store.execute(
      'UPDATE $apiaryCountersTable SET value = ?, updated_at = ? WHERE id = ?',
      [value, now, existing['id']],
    );
  }

  Future<void> _insertCounter(
    String apiaryId,
    String counterType,
    int value,
    String nowIso,
  ) {
    return _store.execute(
      'INSERT INTO $apiaryCountersTable '
      '(id, apiary_id, counter_type, value, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [_uuid.v4(), apiaryId, counterType, value, nowIso, nowIso],
    );
  }

  Apiary _fromRow(Map<String, Object?> r) => Apiary(
    id: r['id'] as String,
    name: r['name'] as String,
    hiveCount: (r['hive_count'] as int?) ?? 0,
    locationLon: (r['location_lon'] as num?)?.toDouble(),
    locationLat: (r['location_lat'] as num?)?.toDouble(),
    placeLabel: r['place_label'] as String?,
    notes: r['notes'] as String?,
  );

  /// Maps counter rows (already newest-first by updated_at) to one
  /// [ApiaryCounter] per counter_type (first — i.e. newest — occurrence
  /// wins), ordered [knownCounterTypes]-first so the detail screen renders
  /// known types in their canonical order.
  List<ApiaryCounter> _countersFromRows(List<Map<String, Object?>> rows) {
    final byType = <String, ApiaryCounter>{};
    for (final r in rows) {
      final type = r['counter_type'] as String;
      byType.putIfAbsent(
        type,
        () => ApiaryCounter(
          apiaryId: r['apiary_id'] as String,
          counterType: type,
          value: (r['value'] as int?) ?? 0,
        ),
      );
    }
    return [
      for (final type in knownCounterTypes)
        if (byType.containsKey(type)) byType.remove(type)!,
      ...byType.values,
    ];
  }

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

/// Live counter rows for one apiary (#256) — what the detail screen's
/// generic counters section watches. Family-keyed by apiary id; overridable
/// in widget tests the same way [apiariesStreamProvider] already is.
final apiaryCountersProvider = StreamProvider.autoDispose
    .family<List<ApiaryCounter>, String>((ref, apiaryId) async* {
      final repo = await ref.watch(apiariesRepositoryProvider.future);
      yield* repo.watchCountersFor(apiaryId);
    });

/// Client-side search over the locally-synced apiary set (FR-AP-6, D-17:
/// client-side, apiaries-only, matches on name and location). Originally
/// name-only: there was no free-text location/address field on an apiary
/// (just the GeoPoint, #33's own scope), so "search by location" had
/// nothing textual to search against. #252/#254 add [Apiary.placeLabel] —
/// the place NAME a beekeeper can now attach independent of the map pin —
/// so this now also matches that field, closing D-17's original gap.
/// Case-insensitive AND diacritic-insensitive (#254 AC: PT "São" matches
/// "sao" — [normalizeForSearch] folds both the query and the candidate text
/// the same way before comparing), substring match (not prefix-only) so
/// "orte" matches "Encosta Norte". An empty/whitespace-only query returns
/// [apiaries] unfiltered.
List<Apiary> filterApiariesByQuery(List<Apiary> apiaries, String query) {
  final needle = normalizeForSearch(query.trim());
  if (needle.isEmpty) return apiaries;
  return apiaries
      .where(
        (a) =>
            normalizeForSearch(a.name).contains(needle) ||
            (a.placeLabel != null &&
                normalizeForSearch(a.placeLabel!).contains(needle)),
      )
      .toList();
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
