import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/sync/local_store.dart';
import '../../core/sync/lww_delete.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';

/// One apiary's contribution to a declaration, captured **at record time**
/// (FR-AP-10, #298).
///
/// A snapshot, not a live join: the whole point of a declaration is that it
/// still says what it said after the apiaries move on, so the apiary's name and
/// hive count are copied in rather than looked up later. [apiaryId] is kept for
/// deep-linking where the apiary still exists, but a declaration remains fully
/// readable after that apiary is renamed or deleted.
class StockDeclarationApiary {
  const StockDeclarationApiary({
    required this.apiaryId,
    required this.name,
    required this.hiveCount,
  });

  factory StockDeclarationApiary.fromJson(Map<String, dynamic> json) =>
      StockDeclarationApiary(
        apiaryId: json['apiary_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        hiveCount: (json['hive_count'] as num?)?.toInt() ?? 0,
      );

  final String apiaryId;
  final String name;
  final int hiveCount;

  Map<String, dynamic> toJson() => {
    'apiary_id': apiaryId,
    'name': name,
    'hive_count': hiveCount,
  };
}

/// A stock declaration — the `Declaração de Existências` record (FR-AP-10,
/// #298).
///
/// **Not the live hive counter.** `Apiary.hiveCount` (FR-AP-7, D-2, D-20) is
/// current state and moves with reality; this is what was declared to DGAV on
/// [declaredOn] and must stay that way afterwards.
///
/// Scoped to a [dgavRegistrationNumber] rather than to an apiary, because the
/// real declaration covers a beekeeper's whole holding and DGAV issues one
/// number per beekeeper (FR-AP-9). An organization covering several beekeepers
/// therefore keeps one declaration log per number.
class StockDeclaration {
  const StockDeclaration({
    required this.id,
    required this.dgavRegistrationNumber,
    required this.declaredOn,
    required this.totalHiveCount,
    this.breakdown = const [],
    this.notes,
  });

  final String id;
  final String dgavRegistrationNumber;
  final DateTime declaredOn;
  final int totalHiveCount;
  final List<StockDeclarationApiary> breakdown;
  final String? notes;
}

/// Reads and writes stock declarations against the local store (NFR-ARC-2,
/// #55: behind [LocalStoreEngine], never a concrete engine type, so the sync
/// engine can be swapped without rewriting this file).
///
/// Local-first like every other syncable entity (walking-skeleton.md §4.4): a
/// declaration recorded in the field with no connectivity is written locally and
/// uploaded later. `organization_id` is omitted — the server derives it from the
/// token.
///
/// `breakdown` is stored as JSON-encoded TEXT because PowerSync's local schema
/// has no JSON column type; the connector decodes it back to a JSON array on
/// upload via its `jsonColumnsByTable` seam, so the wire shape matches the
/// owning service's contract (services/apiaries/api/declarations.go).
class StockDeclarationsRepository {
  StockDeclarationsRepository(this._store);

  final LocalStoreEngine _store;
  static const _uuid = Uuid();

  static const _selectColumns =
      'id, dgav_registration_number, declared_on, total_hive_count, '
      'breakdown, notes';

  /// Every declaration in the organization, newest declaration date first (and
  /// newest-recorded first within a date, so two declarations filed on the same
  /// day still read in a stable, meaningful order).
  ///
  /// Returned across ALL registration numbers rather than filtered here: an
  /// organization covering several beekeepers needs them grouped, not
  /// re-queried per number, and grouping in Dart keeps this a single watch that
  /// the DGAV section rebuilds from.
  Stream<List<StockDeclaration>> watchAll() {
    return _store
        .watch(
          'SELECT $_selectColumns FROM $stockDeclarationsTable '
          'ORDER BY declared_on DESC, created_at DESC',
        )
        .map((rows) => rows.map(_fromRow).toList());
  }

  /// Records a declaration. [declaredOn] is stored as a plain `YYYY-MM-DD`
  /// calendar date, matching the server's DATE column — a declaration is filed
  /// ON a day, and a timezone-bearing instant would make "is this inside the
  /// September window" depend on the reader's zone.
  Future<String> create({
    required String dgavRegistrationNumber,
    required DateTime declaredOn,
    required int totalHiveCount,
    List<StockDeclarationApiary> breakdown = const [],
    String? notes,
  }) async {
    final id = _uuid.v4();
    final now = _nowIso();
    await _store.execute(
      'INSERT INTO $stockDeclarationsTable '
      '(id, dgav_registration_number, declared_on, total_hive_count, '
      'breakdown, notes, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        dgavRegistrationNumber,
        formatDeclaredOn(declaredOn),
        totalHiveCount,
        jsonEncode([for (final entry in breakdown) entry.toJson()]),
        notes,
        now,
        now,
      ],
    );
    return id;
  }

  /// Deletes a declaration — a local delete, which PowerSync queues as a
  /// `delete` op the owning service turns into a tombstone.
  ///
  /// Unlike an apiary counter (which the server refuses to delete, having no
  /// lifecycle of its own), a declaration IS an independent record: a
  /// mis-entered one must be removable, and the tombstone must reach the
  /// beekeeper's other devices.
  ///
  /// Issued through [deleteWithLwwStamp] (#276) like every other synced delete,
  /// so the op's LWW comparator is the moment the user deleted — captured here
  /// and persisted with the queued op — rather than whenever it happens to
  /// upload, which drifts later on every retry and every app restart.
  Future<void> delete(String id) =>
      deleteWithLwwStamp(_store, stockDeclarationsTable, id);

  StockDeclaration _fromRow(Map<String, Object?> r) => StockDeclaration(
    id: r['id'] as String,
    dgavRegistrationNumber: r['dgav_registration_number'] as String? ?? '',
    declaredOn: parseDeclaredOn(r['declared_on'] as String?),
    totalHiveCount: (r['total_hive_count'] as num?)?.toInt() ?? 0,
    breakdown: _decodeBreakdown(r['breakdown'] as String?),
    notes: r['notes'] as String?,
  );

  /// Decodes the stored snapshot, tolerating anything that isn't the expected
  /// array shape by yielding an empty breakdown.
  ///
  /// Deliberately forgiving rather than throwing: the breakdown is supporting
  /// detail, while the declared date and total are the record itself. A row
  /// written by a newer client (or corrupted) must not make the whole
  /// declaration — and with it the whole DGAV section — unreadable.
  static List<StockDeclarationApiary> _decodeBreakdown(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const [];
    }
    if (decoded is! List) return const [];
    return [
      for (final entry in decoded)
        if (entry is Map<String, dynamic>)
          StockDeclarationApiary.fromJson(entry),
    ];
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

/// Renders a declaration date in the `YYYY-MM-DD` form the local column and the
/// server's DATE column both use. Top-level so the repository and its tests
/// agree on one formatting rule rather than two.
String formatDeclaredOn(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// Parses a stored `YYYY-MM-DD` value back to a local [DateTime] at midnight.
///
/// Falls back to the Unix epoch for a null/unparseable value rather than
/// throwing, for the same reason [StockDeclarationsRepository._decodeBreakdown]
/// is forgiving: one malformed row must not take the whole log with it. Such a
/// row sorts to the bottom and is visibly wrong, which is the honest outcome.
DateTime parseDeclaredOn(String? value) {
  if (value == null) return DateTime.fromMillisecondsSinceEpoch(0);
  return DateTime.tryParse(value) ?? DateTime.fromMillisecondsSinceEpoch(0);
}

/// The org's stock declarations, newest first (FR-AP-10, #298) — the DGAV
/// section's single source of data.
final stockDeclarationsRepositoryProvider =
    FutureProvider<StockDeclarationsRepository>((ref) async {
      final session = await ref.watch(powerSyncProvider.future);
      return StockDeclarationsRepository(PowerSyncLocalStore(session.db));
    });

final stockDeclarationsStreamProvider = StreamProvider<List<StockDeclaration>>((
  ref,
) async* {
  final repo = await ref.watch(stockDeclarationsRepositoryProvider.future);
  yield* repo.watchAll();
});
