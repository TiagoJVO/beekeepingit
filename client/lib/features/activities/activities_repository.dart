import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/sync/local_store.dart';
import '../../core/sync/powersync_local_store.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/sync/powersync_service.dart';
import '../organization/organization_repository.dart';

/// A local activity row (#38/#39, read by #42/#43/#44 — FR-AC-1/FR-AC-5/
/// FR-AC-6/FR-TEN-2): the client mirror of one `activities.activities` row
/// replicated down by the org-scoped PowerSync Sync Rule (#39).
///
/// [performedBy]/[organizationId] are both nullable — NOT because the
/// server column is optional (it isn't, FR-TEN-2: every activity carries
/// both), but because [ActivitiesRepository.create] deliberately never
/// writes either locally (see its own doc comment): a freshly-created,
/// not-yet-uploaded row has both columns NULL until the write round-trips
/// through sync and the server-derived values replicate back down. Callers
/// that display attribution ([activityAttributionText], activity_display.
/// dart) handle a null [performedBy] as a distinct "not yet known" state,
/// not as a display bug.
class Activity {
  const Activity({
    required this.id,
    required this.apiaryId,
    required this.type,
    required this.occurredAt,
    required this.attributes,
    this.performedBy,
    this.organizationId,
    this.journeyId,
  });

  final String id;
  final String apiaryId;
  final String type;

  /// Plain `YYYY-MM-DD` (no time-of-day), matching the server's `DATE`
  /// column (services/activities/api/validate.go's `dateLayout`).
  final String occurredAt;
  final Map<String, dynamic> attributes;
  final String? performedBy;
  final String? organizationId;

  /// The journey this activity attaches to (D-21/#46), or null for "no
  /// journey" — mirrors [ActivitiesRepository.create]'s own `journeyId`
  /// param. Exposed on the read model starting #47 so journeys' own list
  /// (journeys_repository.dart's progress badge, journey_filters.dart's
  /// date-range filter) can correlate an activity back to its journey
  /// without a bespoke query of its own — the column has existed on the
  /// local table since #46, only the read side didn't surface it until now.
  final String? journeyId;

  DateTime get occurredAtDate => DateTime.parse(occurredAt);
}

/// Writes activities against the local store (#39/#40/#41, FR-AC-2/3/4,
/// FR-OF-1), mirroring apiaries_repository.dart's own local-first
/// convention: every write is queued for the write-back seam
/// (walking-skeleton.md §4.4, and — for activities specifically —
/// services/sync/api/coordinator.go's entity_type routing to the activities
/// service, services/activities/api/sync.go) rather than calling a REST
/// write endpoint directly.
///
/// `organization_id` and `performed_by` are deliberately NOT written here —
/// exactly like apiaries_repository's own omission of `organization_id` —
/// both are derived SERVER-SIDE from the authenticated caller's token on
/// write-back (FR-TEN-2: "each activity is recorded against the user who
/// performed it"), never from client-supplied data, so a spoofed attribution
/// is not even representable on the wire. `journey_id` (D-21/#46) IS written
/// by [create] (optionally — see its own doc) — and, as of #387, [update]
/// too: linking/moving/removing an activity's journey on edit is now a
/// supported action (add_activity_screen.dart's journey attachment section
/// renders in edit mode, not just create). This reverses the immutability
/// this class used to document: the sync-side server change (#387,
/// services/activities/api/sync.go's mergeActivityOp) had to ship FIRST, or
/// a queued journey_id change would have been silently dropped.
///
/// `apiary_id` is likewise never written by [update] (#40): the edit UI
/// never exposes moving an activity to a different apiary, so every local
/// UPDATE this repository issues touches only type/occurred_at/attributes —
/// matching services/activities/api/sync.go's own "apiary_id is optional on
/// an edit op, unchanged when absent" convention on the server side.
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
  ///
  /// [journeyId] (D-21/#46) is the journey this activity attaches to, or
  /// null for "no journey" — the activity-form picker's auto-select/
  /// deselect/switch/create-new outcome (journey_picker.dart), set once here
  /// and never changed afterward (this class's own doc comment).
  Future<String> create({
    required String apiaryId,
    required String type,
    required String occurredAt,
    required Map<String, dynamic> attributes,
    String? journeyId,
  }) async {
    final id = _uuid.v4();
    final now = _nowIso();
    await _store.execute(
      'INSERT INTO $activitiesTable '
      '(id, apiary_id, journey_id, type, occurred_at, attributes, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        id,
        apiaryId,
        journeyId,
        type,
        occurredAt,
        jsonEncode(attributes),
        now,
        now,
      ],
    );
    return id;
  }

  /// One-shot read of an activity by id, or null if it doesn't (or no
  /// longer) exist — mirrors [ApiariesRepository.getById]. Used by the edit
  /// form's initial load (add_activity_screen.dart's `_loadExisting`).
  Future<Activity?> getById(String id) async {
    final row = await _store.getOptional(
      'SELECT id, apiary_id, journey_id, performed_by, organization_id, type, '
      'occurred_at, attributes FROM $activitiesTable WHERE id = ?',
      [id],
    );
    return row == null ? null : _fromRow(row);
  }

  /// Live single-row watch for one activity by id — mirrors
  /// [ApiariesRepository.watchById]'s per-id pattern (not currently
  /// consumed by a screen yet, added alongside [getById] for the same
  /// reason that one exists: a future edit-screen provider can watch
  /// rather than one-shot load without a second read path being added
  /// later).
  Stream<Activity?> watchById(String id) {
    return _store
        .watch(
          'SELECT id, apiary_id, journey_id, performed_by, organization_id, '
          'type, occurred_at, attributes FROM $activitiesTable WHERE id = ?',
          [id],
        )
        .map((rows) => rows.isEmpty ? null : _fromRow(rows.first));
  }

  /// Updates an existing activity's type/date/attributes/journey (#40/#387,
  /// FR-AC-3). [attributes] must already be the exact per-[type] attribute
  /// bag, validated client-side the same way [create]'s callers do (D-12) —
  /// the edit form always resubmits the COMPLETE current state (never a
  /// sparse per-field diff), so this always sets every mutable column in one
  /// SQL UPDATE — matching services/activities/api/sync.go's own "put/patch
  /// are both a full resubmit" convention for this table (mergeActivityOp's
  /// doc comment). apiary_id is deliberately excluded from the SET clause
  /// (this class's own doc comment) — the edit UI never exposes moving an
  /// activity to a different apiary. [journeyId] IS included, always
  /// (#387) — required, not optional, for the same reason journeys_repository
  /// .dart's own `update`'s `defaultAttributes` param is required: an
  /// omitted value here would silently WIPE the stored link on every save
  /// rather than preserve it, so every caller must explicitly pass the
  /// journey attachment section's current effective selection (null for "no
  /// journey", same as [create]'s own convention).
  Future<void> update(
    String id, {
    required String type,
    required String occurredAt,
    required Map<String, dynamic> attributes,
    required String? journeyId,
  }) async {
    // #378: skip the write entirely when nothing actually changed (e.g.
    // opening the edit form and saving without touching anything) —
    // otherwise this still bumps updated_at, queuing a sync op whose diffed
    // payload carries only the changed columns (PowerSync uploads a column
    // diff, not always this full row), which the server used to reject
    // outright ("occurred_at is required", "type is required"). journeyId
    // (#387) participates in this no-op check too — a journey-only change
    // must not be masked by unchanged type/occurred_at/attributes, and vice
    // versa an unchanged journey must not force a write when nothing else
    // changed either.
    final current = await getById(id);
    final encodedAttributes = jsonEncode(attributes);
    if (current != null &&
        current.type == type &&
        current.occurredAt == occurredAt &&
        current.journeyId == journeyId &&
        jsonEncode(current.attributes) == encodedAttributes) {
      return;
    }
    await _store.execute(
      'UPDATE $activitiesTable SET type = ?, occurred_at = ?, attributes = ?, journey_id = ?, updated_at = ? '
      'WHERE id = ?',
      [type, occurredAt, encodedAttributes, journeyId, _nowIso(), id],
    );
  }

  /// Deletes the activity row (#41, FR-AC-4). A plain local DELETE —
  /// PowerSync's CRUD queue observes it as a `delete` op regardless (the
  /// same mechanism [ApiariesRepository.delete]'s own doc comment
  /// describes), which the connector (powersync_connector.dart's
  /// `entityTypeForTable`) routes to the activities service's sync-apply
  /// endpoint, where it is applied as a server-side tombstone
  /// (services/activities/api/sync.go's applyActivityOp) — the row is
  /// removed from THIS device immediately and propagates to every other
  /// device on their next sync via the PowerSync Sync Rules'
  /// `deleted_at IS NULL` filter.
  Future<void> delete(String id) =>
      _store.execute('DELETE FROM $activitiesTable WHERE id = ?', [id]);

  /// One apiary's activities (#42, FR-AC-5), newest-first. No org filter is
  /// needed here — unlike [watchAll] below, an apiary belonging to another
  /// organization is never locally present to begin with (the apiaries
  /// Sync Rule already scopes it out), so filtering activities by
  /// [apiaryId] alone can never cross a tenant boundary.
  Stream<List<Activity>> watchByApiary(String apiaryId) {
    return _store
        .watch(
          'SELECT id, apiary_id, journey_id, performed_by, organization_id, '
          'type, occurred_at, attributes FROM $activitiesTable '
          'WHERE apiary_id = ? ORDER BY occurred_at DESC, created_at DESC',
          [apiaryId],
        )
        .map((rows) => rows.map(_fromRow).toList());
  }

  /// One journey's activities (#48, FR-JO-3, D-21), newest-first —
  /// attributed by the activity's STORED `journey_id` column, never a live
  /// re-match against the journey's current plan/apiary/type (D-21, mirrors
  /// journeys_repository.dart's `getStats`/`watchStats` own doc on this same
  /// guarantee): `journey_id` is set once at creation and never changed
  /// afterward (this class's own doc comment above), so this query simply
  /// reflects whatever is currently stored. No org filter needed here either
  /// — same rationale as [watchByApiary]'s own doc: a journey belonging to
  /// another organization is never locally present to begin with (the
  /// journeys Sync Rule already scopes it out), so filtering activities by
  /// [journeyId] alone can never cross a tenant boundary.
  Stream<List<Activity>> watchByJourney(String journeyId) {
    return _store
        .watch(
          'SELECT id, apiary_id, journey_id, performed_by, organization_id, '
          'type, occurred_at, attributes FROM $activitiesTable '
          'WHERE journey_id = ? ORDER BY occurred_at DESC, created_at DESC',
          [journeyId],
        )
        .map((rows) => rows.map(_fromRow).toList());
  }

  /// Every activity across every apiary in the caller's org (#43, FR-AC-6),
  /// newest-first. Tenancy (FR-TEN-2) is primarily enforced by the
  /// org-scoped PowerSync Sync Rule (#39's `activities.activities` bucket)
  /// that only ever replicates the caller's own org's rows to this device —
  /// this repository has no other org's data to leak in the first place.
  ///
  /// The `organization_id = ? OR organization_id IS NULL` clause is a
  /// second, defense-in-depth layer specific to this cross-apiary list
  /// (#42's own [watchByApiary] doesn't need one — see its doc): it must
  /// tolerate a just-created, not-yet-round-tripped local row (whose
  /// `organization_id` is NULL until sync — [create] never sets it, see the
  /// [Activity] class doc) while still excluding any row that DOES carry a
  /// foreign `organization_id` — which the Sync Rule should already
  /// guarantee never happens, but this makes "never include another
  /// organization's activities" (#43 AC) a real, independently testable
  /// property of this query rather than something only trusted by
  /// inference from the sync-rule config.
  ///
  /// [organizationId] is the caller's own org id (organization_repository.
  /// dart's `organizationProvider`). A null value (no organization loaded
  /// yet — the onboarding gate should make this unreachable in practice)
  /// yields an empty stream rather than an unscoped query.
  Stream<List<Activity>> watchAll({required String? organizationId}) {
    if (organizationId == null) return Stream.value(const []);
    return _store
        .watch(
          'SELECT id, apiary_id, journey_id, performed_by, organization_id, '
          'type, occurred_at, attributes FROM $activitiesTable '
          'WHERE organization_id = ? OR organization_id IS NULL '
          'ORDER BY occurred_at DESC, created_at DESC',
          [organizationId],
        )
        .map((rows) => rows.map(_fromRow).toList());
  }

  Activity _fromRow(Map<String, Object?> r) => Activity(
    id: r['id'] as String,
    apiaryId: r['apiary_id'] as String,
    journeyId: r['journey_id'] as String?,
    performedBy: r['performed_by'] as String?,
    organizationId: r['organization_id'] as String?,
    type: r['type'] as String,
    occurredAt: r['occurred_at'] as String,
    attributes: r['attributes'] == null
        ? const {}
        : (jsonDecode(r['attributes'] as String) as Map<String, dynamic>),
  );

  String _nowIso() => DateTime.now().toUtc().toIso8601String();
}

final activitiesRepositoryProvider = FutureProvider<ActivitiesRepository>((
  ref,
) async {
  final session = await ref.watch(powerSyncProvider.future);
  return ActivitiesRepository(PowerSyncLocalStore(session.db));
});

/// Live single activity by id (#40/#41) — the edit screen's read path,
/// mirroring [apiaryByIdProvider]'s family + autoDispose pattern
/// (apiaries_repository.dart).
final activityByIdProvider = StreamProvider.autoDispose
    .family<Activity?, String>((ref, activityId) async* {
      final repo = await ref.watch(activitiesRepositoryProvider.future);
      yield* repo.watchById(activityId);
    });

/// One apiary's live activities (#42) — family-keyed + autoDispose, mirroring
/// apiaries_repository.dart's apiaryCountersProvider/apiaryByIdProvider
/// convention: a write to an unrelated apiary's activities never re-triggers
/// this.
final activitiesByApiaryProvider = StreamProvider.autoDispose
    .family<List<Activity>, String>((ref, apiaryId) async* {
      final repo = await ref.watch(activitiesRepositoryProvider.future);
      yield* repo.watchByApiary(apiaryId);
    });

/// Every activity across the org (#43), live from local SQLite
/// (offline-first) — depends on [organizationProvider] so it naturally
/// re-scopes if the org context ever changes, and stays an empty list
/// (never an error) while the org is still loading.
final activitiesStreamProvider = StreamProvider.autoDispose<List<Activity>>((
  ref,
) async* {
  final repo = await ref.watch(activitiesRepositoryProvider.future);
  final org = await ref.watch(organizationProvider.future);
  yield* repo.watchAll(organizationId: org?.id);
});

/// One journey's live activities (#48, FR-JO-3) — family-keyed + autoDispose,
/// mirroring [activitiesByApiaryProvider]'s own per-id convention: a write
/// to an unrelated journey's activities never re-triggers this.
final activitiesByJourneyProvider = StreamProvider.autoDispose
    .family<List<Activity>, String>((ref, journeyId) async* {
      final repo = await ref.watch(activitiesRepositoryProvider.future);
      yield* repo.watchByJourney(journeyId);
    });
