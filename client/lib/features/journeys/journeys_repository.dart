import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/sync/local_store.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';
import '../organization/organization_repository.dart';
import 'journey_status.dart';

/// A local journey row (#45, EPIC-04 M4, FR-JO-4, FR-TEN-2, D-21): the
/// client mirror of one `journeys.journeys` row plus its LIVE
/// `journeys.journey_plan_items` set (the apiaries-to-visit plan), replicated
/// down by the org-scoped PowerSync Sync Rule.
///
/// [organizationId] is nullable — NOT because the server column is optional
/// (it isn't, FR-TEN-2), but because [JourneysRepository.create] deliberately
/// never writes it locally (mirrors [Activity]'s own doc comment): a
/// freshly-created, not-yet-uploaded row has it NULL until the write
/// round-trips through sync and the server-derived value replicates back
/// down.
///
/// [apiaryIds] is only populated by [JourneysRepository.getById] (the edit
/// form's pre-fill read) — [JourneysRepository.watchAll] (the list screen)
/// deliberately leaves it empty, since the minimal list (#45's scope; full
/// filtering/detail is #47/#48) never needs it, and joining every journey's
/// plan into the list query would be wasted work for a screen that never
/// shows it.
class Journey {
  const Journey({
    required this.id,
    required this.name,
    required this.mainActivityType,
    required this.status,
    this.organizationId,
    this.apiaryIds = const [],
  });

  final String id;
  final String name;
  final String mainActivityType;
  final String status;
  final String? organizationId;
  final List<String> apiaryIds;

  bool get isOpen => status == journeyStatusOpen;
}

/// Writes journeys against the local store (#45, FR-JO-4, FR-OF-1),
/// mirroring activities_repository.dart's/apiaries_repository.dart's own
/// local-first convention: every write is queued for the write-back seam
/// (walking-skeleton.md §4.4) rather than calling a REST write endpoint
/// directly.
///
/// `organization_id` is deliberately NOT written by [create] — exactly like
/// activities_repository's own omission — derived SERVER-SIDE from the
/// authenticated caller's token on write-back (FR-TEN-2), never from
/// client-supplied data.
///
/// The "apiaries to visit" plan rides a SEPARATE local table
/// ([journeyPlanItemsTable]) from the journey's own row
/// ([journeysTable]) — mirroring [apiaryCountersTable]'s own
/// parent-row-plus-child-rows split for a single owning service — so
/// [create]/[update] write BOTH tables, and PowerSync's CRUD queue carries
/// two independent kinds of op that the connector
/// (powersync_connector.dart's `entityTypeForTable`) routes to the SAME
/// journeys service.
class JourneysRepository {
  JourneysRepository(this._store);

  final LocalStoreEngine _store;
  static const _uuid = Uuid();

  /// Creates a journey with [apiaryIds] as its initial plan (FR-JO-4) —
  /// always starts **open** (D-21). [apiaryIds] may be empty: a journey can
  /// be created first and apiaries added to its plan later via [update].
  Future<String> create({
    required String name,
    required String mainActivityType,
    required List<String> apiaryIds,
  }) async {
    final id = _uuid.v4();
    final now = _nowIso();
    // Journey row first, its plan items second — PowerSync uploads queued
    // ops in local write order, and the server's plan-item apply looks up
    // the parent journey row (mirrors apiaries_repository.dart's own
    // apiary-then-counter ordering rationale), so this guarantees the
    // parent exists by the time a plan-item op applies.
    await _store.execute(
      'INSERT INTO $journeysTable '
      '(id, name, main_activity_type, status, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [id, name, mainActivityType, journeyStatusOpen, now, now],
    );
    for (final apiaryId in apiaryIds) {
      await _insertPlanItem(id, apiaryId, now);
    }
    return id;
  }

  Future<void> _insertPlanItem(String journeyId, String apiaryId, String now) {
    return _store.execute(
      'INSERT INTO $journeyPlanItemsTable (id, journey_id, apiary_id, created_at) '
      'VALUES (?, ?, ?, ?)',
      [_uuid.v4(), journeyId, apiaryId, now],
    );
  }

  /// One-shot read of a journey by id, including its current plan, or null
  /// if it doesn't (or no longer) exist — mirrors [ActivitiesRepository]'s
  /// `getById`. Used by the edit form's initial load.
  Future<Journey?> getById(String id) async {
    final row = await _store.getOptional(
      'SELECT id, organization_id, name, main_activity_type, status '
      'FROM $journeysTable WHERE id = ?',
      [id],
    );
    if (row == null) return null;
    final apiaryIds = await _planApiaryIds(id);
    return _fromRow(row, apiaryIds);
  }

  Future<List<String>> _planApiaryIds(String journeyId) async {
    final rows = await _store.getAll(
      'SELECT apiary_id FROM $journeyPlanItemsTable WHERE journey_id = ? '
      'ORDER BY created_at',
      [journeyId],
    );
    return rows.map((r) => r['apiary_id'] as String).toList();
  }

  /// Updates a journey's name/main_activity_type/status and fully replaces
  /// its plan with [apiaryIds] (#45, FR-JO-4, D-21) — the edit form always
  /// resubmits the complete current state (mirrors
  /// add_activity_screen.dart's own convention), so this diffs the requested
  /// plan against the stored one: an apiary no longer in [apiaryIds] is
  /// removed (its local row deleted — a plain local DELETE queues a
  /// PowerSync `delete` op, no identity enrichment needed since a plan
  /// item's own id IS its stable server identity, powersync_schema.dart's
  /// doc comment), and a newly-added one gets a fresh row; an apiary present
  /// in both is left completely untouched.
  ///
  /// [status] is always sent (mirrors [create]'s own "open" convention) —
  /// callers that only want to close a journey use [close], which reads the
  /// current state and resubmits it unchanged except for `status`.
  Future<void> update(
    String id, {
    required String name,
    required String mainActivityType,
    required String status,
    required List<String> apiaryIds,
  }) async {
    final now = _nowIso();
    await _store.execute(
      'UPDATE $journeysTable SET name = ?, main_activity_type = ?, status = ?, updated_at = ? '
      'WHERE id = ?',
      [name, mainActivityType, status, now, id],
    );

    final existing = await _store.getAll(
      'SELECT id, apiary_id FROM $journeyPlanItemsTable WHERE journey_id = ?',
      [id],
    );
    final existingIdByApiary = {
      for (final row in existing)
        row['apiary_id'] as String: row['id'] as String,
    };
    final desired = apiaryIds.toSet();

    for (final row in existing) {
      if (!desired.contains(row['apiary_id'])) {
        await _store.execute(
          'DELETE FROM $journeyPlanItemsTable WHERE id = ?',
          [row['id']],
        );
      }
    }
    for (final apiaryId in apiaryIds) {
      if (!existingIdByApiary.containsKey(apiaryId)) {
        await _insertPlanItem(id, apiaryId, now);
      }
    }
  }

  /// Closes a journey (D-21: moves it from open to selectable-by-default to
  /// hidden-by-default in the #46 activity-form picker) — reads the
  /// journey's current name/main_activity_type/plan and resubmits them
  /// unchanged via [update], only setting `status` to
  /// [journeyStatusClosed]. A no-op if [id] doesn't (or no longer) exist.
  Future<void> close(String id) async {
    final journey = await getById(id);
    if (journey == null) return;
    await update(
      id,
      name: journey.name,
      mainActivityType: journey.mainActivityType,
      status: journeyStatusClosed,
      apiaryIds: journey.apiaryIds,
    );
  }

  /// Deletes the journey row (FR-JO-4). A plain local DELETE — PowerSync's
  /// CRUD queue observes it as a `delete` op regardless, applied server-side
  /// as a tombstone (services/journeys/api/sync.go's applyJourneyOp). The
  /// journey's plan-item rows are deliberately left in place: inert and
  /// invisible once their parent journey is gone, mirroring
  /// apiaries_repository.dart's own "delete apiary, leave its counter rows"
  /// convention.
  Future<void> delete(String id) =>
      _store.execute('DELETE FROM $journeysTable WHERE id = ?', [id]);

  /// Every journey in the caller's org (#45's minimal list screen; #47 adds
  /// filters later), newest-first. Tenancy (FR-TEN-2) is primarily enforced
  /// by the org-scoped PowerSync Sync Rule; the `organization_id = ? OR
  /// organization_id IS NULL` clause is the same defense-in-depth + "don't
  /// hide a just-created, not-yet-round-tripped local row" tolerance
  /// [ActivitiesRepository.watchAll]'s own doc comment explains.
  Stream<List<Journey>> watchAll({required String? organizationId}) {
    if (organizationId == null) return Stream.value(const []);
    return _store
        .watch(
          'SELECT id, organization_id, name, main_activity_type, status '
          'FROM $journeysTable '
          'WHERE organization_id = ? OR organization_id IS NULL '
          'ORDER BY created_at DESC',
          [organizationId],
        )
        .map((rows) => rows.map((r) => _fromRow(r, const [])).toList());
  }

  /// Candidate journeys for the #46 activity-form picker (FR-JO-1, D-21):
  /// every journey — open OR closed, both are returned here, the picker
  /// itself decides what to show by default vs. behind the "show hidden
  /// journeys" toggle (journey_matching.dart's `splitJourneyCandidates`) —
  /// whose plan currently includes [apiaryId] AND whose
  /// `main_activity_type` is [activityType]. This is the ENTIRE matching
  /// rule (D-21: "the app looks for an open journey whose apiary and
  /// activity type match"), evaluated purely against locally-synced data so
  /// it works fully offline. Newest-first, same convention as [watchAll], so
  /// the picker's auto-select (the first OPEN entry after splitting) is
  /// "the most recently created matching journey".
  Stream<List<Journey>> watchMatching({
    required String apiaryId,
    required String activityType,
    required String? organizationId,
  }) {
    if (organizationId == null) return Stream.value(const []);
    return _store
        .watch(
          'SELECT j.id, j.organization_id, j.name, j.main_activity_type, j.status '
          'FROM $journeysTable j '
          'JOIN $journeyPlanItemsTable p ON p.journey_id = j.id '
          'WHERE (j.organization_id = ? OR j.organization_id IS NULL) '
          'AND j.main_activity_type = ? AND p.apiary_id = ? '
          'ORDER BY j.created_at DESC',
          [organizationId, activityType, apiaryId],
        )
        .map((rows) => rows.map((r) => _fromRow(r, const [])).toList());
  }

  Journey _fromRow(Map<String, Object?> r, List<String> apiaryIds) => Journey(
    id: r['id'] as String,
    organizationId: r['organization_id'] as String?,
    name: r['name'] as String,
    mainActivityType: r['main_activity_type'] as String,
    status: r['status'] as String,
    apiaryIds: apiaryIds,
  );

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

final journeysRepositoryProvider = FutureProvider<JourneysRepository>((
  ref,
) async {
  final session = await ref.watch(powerSyncProvider.future);
  return JourneysRepository(PowerSyncLocalStore(session.db));
});

/// Every journey across the org, live from local SQLite (offline-first) —
/// mirrors [activitiesStreamProvider]'s own org-dependent, never-erroring
/// shape.
final journeysStreamProvider = StreamProvider.autoDispose<List<Journey>>((
  ref,
) async* {
  final repo = await ref.watch(journeysRepositoryProvider.future);
  final org = await ref.watch(organizationProvider.future);
  yield* repo.watchAll(organizationId: org?.id);
});
