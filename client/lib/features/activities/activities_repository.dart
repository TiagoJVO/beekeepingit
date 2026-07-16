import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/sync/local_store.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';

/// Writes activities against the local store (#39, FR-AC-2, FR-OF-1),
/// mirroring apiaries_repository.dart's own local-first convention: every
/// write is queued for the write-back seam (walking-skeleton.md §4.4, and —
/// for activities specifically — services/sync/api/coordinator.go's
/// entity_type routing to the activities service, services/activities/api/
/// sync.go) rather than calling a REST write endpoint directly.
///
/// `organization_id` and `performed_by` are deliberately NOT written here —
/// exactly like apiaries_repository's own omission of `organization_id` —
/// both are derived SERVER-SIDE from the authenticated caller's token on
/// write-back (FR-TEN-2: "each activity is recorded against the user who
/// performed it"), never from client-supplied data, so a spoofed attribution
/// is not even representable on the wire. `journey_id` is similarly omitted
/// (D-21/#46, unused until M4 — there is no journey to attach to yet).
class ActivitiesRepository {
  ActivitiesRepository(this._store);

  final LocalStoreEngine _store;
  static const _uuid = Uuid();

  /// Creates an activity for [apiaryId]. [attributes] must already be the
  /// exact per-[type] attribute bag (only that type's own keys — an extra
  /// key would be rejected server-side, api/types.go's ValidateActivity) —
  /// callers (add_activity_screen.dart) build it via
  /// activity_attributes.dart's schema and validate it with
  /// [validateActivityAttributes] BEFORE calling this, matching D-12's
  /// "client revalidates against the same rules the server will apply"
  /// requirement. [occurredAt] is a plain `YYYY-MM-DD` string, matching the
  /// server's `DATE` column (services/activities/api/validate.go's
  /// `dateLayout`) — no time-of-day component.
  Future<String> create({
    required String apiaryId,
    required String type,
    required String occurredAt,
    required Map<String, dynamic> attributes,
  }) async {
    final id = _uuid.v4();
    final now = _nowIso();
    await _store.execute(
      'INSERT INTO $activitiesTable '
      '(id, apiary_id, type, occurred_at, attributes, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [id, apiaryId, type, occurredAt, jsonEncode(attributes), now, now],
    );
    return id;
  }

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

final activitiesRepositoryProvider = FutureProvider<ActivitiesRepository>((
  ref,
) async {
  final session = await ref.watch(powerSyncProvider.future);
  return ActivitiesRepository(PowerSyncLocalStore(session.db));
});
