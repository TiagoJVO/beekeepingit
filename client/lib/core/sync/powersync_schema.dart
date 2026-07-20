import 'package:powersync/powersync.dart';

/// Local table name — matches the unqualified name PowerSync's Sync Rules
/// stream produces from `apiaries.apiaries` (sync.md §5.1). The server-side
/// entity type is the singular `apiary`.
const apiariesTable = 'apiaries';
const apiaryEntityType = 'apiary';

/// Local table + entity type for `apiaries.apiary_counters` (#256, FR-AP-7):
/// typed 1-N counters decoupled from the apiaries table. The connector maps
/// each queued CRUD entry's source table to its entity type
/// (powersync_connector.dart's `_toOp`), so counter writes upload as their
/// own `apiary_counter` ops — keyed server-side by (apiary_id, counter_type),
/// never by this table's local row id (services/apiaries/api/sync.go's
/// applyCounterOp).
const apiaryCountersTable = 'apiary_counters';
const apiaryCounterEntityType = 'apiary_counter';

/// Local table + entity type for `activities.activities` (#38/#39, FR-AC-1,
/// FR-TEN-2). #39 wires the local WRITE path (features/activities/
/// activities_repository.dart's create, queued through the connector like
/// every other table here) and the offline→sync reconciliation
/// (powersync_connector.dart's entityTypeForTable routes this table's ops to
/// the ACTIVITIES owning service, not apiaries — see
/// services/sync/api/coordinator.go's groupOpsByOwner). Edit/delete/list are
/// later EPIC-03 stories.
const activitiesTable = 'activities';
const activityEntityType = 'activity';

/// Local table + entity type for `journeys.journeys` (#45, EPIC-04 M4,
/// FR-JO-4, D-21). One row per journey: name, main activity type, and
/// lifecycle status (open|closed, D-21's close action).
const journeysTable = 'journeys';
const journeyEntityType = 'journey';

/// Local table + entity type for `journeys.journey_plan_items` (#45,
/// FR-JO-4): the "apiaries to visit" plan, one row per (journey, apiary)
/// pair — a separate synced table/entity type from [journeysTable], the
/// same split [apiaryCountersTable]/[apiaryCounterEntityType] already
/// establishes for a parent-row-plus-child-rows shape owned by one service.
/// Unlike apiary_counters, a plan item's local row `id` IS its stable
/// server identity too (mirrors [activitiesTable]'s convention) — so
/// removing an apiary from a journey's plan is a plain local DELETE, no
/// identity-enrichment needed before upload (powersync_connector.dart's
/// `_toOp` doc comment).
const journeyPlanItemsTable = 'journey_plan_items';
const journeyPlanItemEntityType = 'journey_plan_item';

/// Local table + entity type for `todos.todos` (#50, FR-TD-1, FR-TEN-2). The
/// server-owning service is `services/todos`, routed independently of
/// activities/apiaries by `services/sync/api/coordinator.go`'s
/// `groupOpsByOwner` (this table's own `entityTypeForTable` mapping in
/// `powersync_connector.dart`). Unlike [activitiesTable], there is no JSON
/// attributes bag to decode/encode — every column here is a plain scalar, so
/// no connector-side transform is needed for this table (contrast
/// `decodeActivityAttributes`).
const todosTable = 'todos';
const todoEntityType = 'todo';

/// Local **read-only** history tables (#60, FR-HIS-1, history.md §3/§6/§8).
///
/// Both are **polymorphic**: one local table per log kind serves every
/// entity's timeline, keyed by `(entity_type, entity_id)` — `entity_type`
/// carries the same singular values the rest of this file declares
/// ([apiaryEntityType], [activityEntityType]). That is why the Sync Rules
/// stream `apiaries.audit_log` *and* `activities.audit_log` into this single
/// [auditLogTable]: PowerSync names the output table from the unqualified
/// `FROM` name and the two schemas' DDL is column-identical, so the rows
/// coexist by design rather than collide (infra/helm/beekeepingit/charts/
/// powersync/values.yaml's own comment on those entries).
///
/// **Never written locally.** Unlike every other synced table here, the client
/// only ever reads these — history is server-authored (a service writes its own
/// audit row in the same transaction as the domain write). So they generate no
/// CRUD ops, need no `entityTypeForTable` mapping in
/// `powersync_connector.dart`, and no repository ever `execute`s against them.
///
/// `change`, `winning_payload` and `losing_payload` mirror server JSONB, and
/// `changed_fields` mirrors a server `TEXT[]`; all four are declared
/// [Column.text] and hold their JSON-encoded form, the same
/// no-native-JSON-column convention [activitiesTable]'s `attributes` and
/// [rejectedOpsTable]'s `payload` already follow. Callers decode defensively —
/// `change`'s *shape* differs by event kind (§3's `{field:{from,to}}` delta vs.
/// §4.2's conflict payload), so it is parsed only after branching on the kind.
const auditLogTable = 'audit_log';
const syncConflictLogTable = 'sync_conflict_log';

/// The synthetic `event_kind` a [syncConflictLogTable] row takes in the
/// combined timeline — history.md §6's "LWW losers ... surfaced as a
/// superseded timeline event, not silently overwritten". Mirrors the server's
/// `history.EventSuperseded` constant, which the owning services' own
/// `ListEntityTimeline` query hardcodes into its `UNION ALL` the same way
/// (services/apiaries/store/sqlc/queries/apiaries.sql). [auditLogTable] rows
/// instead carry their own `change_type` (create|update|delete) as the kind.
const supersededEventKind = 'superseded';

/// Local **dead-letter** table for offline writes the server permanently
/// rejects on upload (a validation-class `4xx` — RFC 9457 `422`/`400`, sync.md
/// §8's `rejected` state, D-12 notify-and-fix, #256/#260). The connector
/// (`powersync_connector.dart`'s `handleUploadResponse`) writes one row per op
/// in a rejected push before it `complete()`s the CRUD transaction — so the op
/// leaves PowerSync's upload queue (the queue can't wedge) **without** the
/// user's edit being lost: it is retained here, surfaced via the needs-fix UI,
/// and cleared when a corrected re-save uploads (clear-on-success) or the user
/// dismisses it.
///
/// **Local-only** ([Table.localOnly]) on purpose: a rejected op (i) must never
/// sync up — it's a client-side needs-fix record, not domain data; (ii) must
/// survive an app restart (durability is the whole point); (iii) is org data
/// that must ride the §3.5 logout / membership-loss purge — and
/// `disconnectAndClear()` (via `LocalStoreEngine.clear()`) wipes local-only
/// rows too under its default `clearLocal: true`, so no extra teardown is
/// needed.
///
/// Keyed by **server identity**, not the local row id: [dedupKeyColumn] is the
/// apiary id for an `apiary` op and `"<apiary_id>:<counter_type>"` for an
/// `apiary_counter` op (a counter's local row id isn't stable across a
/// reject→fix cycle — `_upsertCounter` may re-INSERT after a down-sync). The
/// connector REPLACEs by that key (delete-then-insert; PowerSync's local schema
/// has no unique constraints, same as the counters table), so one live entry
/// per record. `fix_apiary_id` is the apiary the needs-fix "Fix" action
/// deep-links to (the apiary id for both op kinds).
const rejectedOpsTable = 'sync_rejected_ops';

/// The server-identity dedup column of [rejectedOpsTable] (see its doc).
const dedupKeyColumn = 'dedup_key';

/// The on-device SQLite schema PowerSync manages. The `id` primary key is
/// implicit (client-generated UUID). `deleted_at` is NOT a local column:
/// the Sync Rules exclude tombstoned rows, so a server-side delete simply
/// leaves the client's result set and PowerSync removes the row locally.
///
/// `notes` (FR-AP-8, #196) is optional free-text, nullable like the server
/// column it mirrors.
///
/// `location_lon`/`location_lat` (FR-AP-2/FR-AP-3/FR-AP-5, #33/#34/#37) are
/// plain nullable REAL columns — the Sync Rules bucket for
/// `apiaries.apiaries` projects the server's PostGIS
/// `geography(Point,4326)` column to these via `ST_X`/`ST_Y(location)`
/// (infra/helm/beekeepingit/charts/powersync/values.yaml — no `::geometry`
/// cast: PowerSync's sync-rules SQL parser doesn't support casting to
/// PostGIS types, and ST_X/ST_Y accept `geography` directly) rather than
/// streaming the raw geography column, which arrives in a wire form (EWKB)
/// this client has no parser for. Both null together when the apiary has no
/// stored location (nullable, matching the DB column's own optionality).
/// Used by #33's offline proximity ordering and #34/#37's map + offline
/// distance measurement alike. #252 wires these into the create/edit WRITE
/// path too (apiaries_repository.dart) — previously only ever read, never
/// written locally, so an in-app-created apiary had no coordinates even
/// though this column pair already existed.
///
/// `place_label` (#252) is an optional free-text place name (e.g.
/// "Montargil"), independent of `location`'s coordinates and of the
/// apiary's own `name` — nullable like `notes`, same plain-text column
/// shape (no projection needed, unlike location).
///
/// `hive_count` is NOT a column on [apiariesTable] anymore (#256): it was
/// retired server-side (apiaries migration 00005) in favor of the
/// [apiaryCountersTable] 1-N child table below, and this local schema
/// mirrors that — the repository reads the hive count via a local LEFT JOIN
/// (0 when no row exists) and writes it as a counter row, never as an
/// apiaries column.
const appSchema = Schema([
  Table(apiariesTable, [
    Column.text('organization_id'),
    Column.text('name'),
    Column.text('notes'),
    Column.text('place_label'),
    Column.text('created_at'),
    Column.text('updated_at'),
    Column.real('location_lon'),
    Column.real('location_lat'),
  ]),
  // apiary_counters (#256): one row per (apiary, counter_type) — the server
  // enforces that uniqueness (a UNIQUE constraint + upsert keyed by
  // (apiary_id, counter_type), never by this table's client-generated row
  // id); locally the repository's own upsert-shaped writes
  // (apiaries_repository.dart's update) maintain it, since PowerSync's
  // local schema has no unique-constraint support of its own. counter_type
  // comes from the known set in features/apiaries/counter_types.dart,
  // mirrored from the owning service (services/apiaries/api/counters.go).
  Table(apiaryCountersTable, [
    Column.text('organization_id'),
    Column.text('apiary_id'),
    Column.text('counter_type'),
    Column.integer('value'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  // activities (#38, FR-AC-1, FR-TEN-2): one row per activity, matching the
  // owning service's shape (services/activities/store/migrations/00001_
  // create_activities.sql). `type` is the extensible activity-type string
  // (client mirror: features/activities/activity_types.dart); `attributes`
  // is the per-type JSONB bag, stored locally as its JSON-encoded text
  // (PowerSync's local schema has no native JSON column type, same
  // convention as [rejectedOpsTable]'s `payload`/`error_detail` columns
  // below). `occurred_at` is a plain ISO-8601 date string, not part of
  // `attributes` — promoted to its own column server-side too, so date-range
  // filtering (FR-AC-5/FR-AC-6) doesn't need to unpack JSON. `journey_id`
  // (D-21) is nullable and unused until M4 (journeys). No write path reads
  // or writes this table yet (#39+, see [activitiesTable]'s doc).
  Table(activitiesTable, [
    Column.text('organization_id'),
    Column.text('apiary_id'),
    Column.text('performed_by'),
    Column.text('journey_id'),
    Column.text('type'),
    Column.text('occurred_at'),
    Column.text('attributes'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  // journeys (#45, FR-JO-4, D-21): name + one main activity type + lifecycle
  // status, matching the owning service's shape
  // (services/journeys/store/migrations/00001_create_journeys.sql).
  // `status` mirrors `type`'s extensible-string convention (open|closed
  // known today).
  Table(journeysTable, [
    Column.text('organization_id'),
    Column.text('name'),
    Column.text('main_activity_type'),
    Column.text('status'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  // journey_plan_items (#45, FR-JO-4): the "apiaries to visit" plan, one row
  // per (journey, apiary) pair — a separate table/entity type from
  // [journeysTable] (this table's own doc comment above explains why).
  Table(journeyPlanItemsTable, [
    Column.text('organization_id'),
    Column.text('journey_id'),
    Column.text('apiary_id'),
    Column.text('created_at'),
  ]),
  // todos (#50, FR-TD-1, FR-TEN-2): one row per todo, matching the owning
  // service's shape (services/todos/store/migrations/00001_create_todos.sql,
  // 00003_add_apiary_id.sql). `organization_id` is never written locally by
  // features/todos/todos_repository.dart (server-derived, same convention as
  // [activitiesTable]'s own organization_id). `priority`/`status` are the
  // extensible, Go-validated vocabularies (D-20) — plain text columns, not a
  // local enum. `due_date` is a plain YYYY-MM-DD string, nullable — a todo
  // may legitimately have none. `completed_at` is nullable, set on complete
  // and cleared on reopen. `assignee_id` (D-23) and `apiary_id` (#51,
  // FR-TD-1: "may be associated with a specific apiary, or left as a
  // general, org-level todo") are the two fields this repository DOES write
  // locally (the user's own choice), unlike organization_id.
  Table(todosTable, [
    Column.text('organization_id'),
    Column.text('title'),
    Column.text('description'),
    Column.text('due_date'),
    Column.text('priority'),
    Column.text('status'),
    Column.text('completed_at'),
    Column.text('assignee_id'),
    Column.text('apiary_id'),
    Column.text('created_at'),
    Column.text('updated_at'),
  ]),
  // audit_log (#60, FR-HIS-1): the applied create/update/delete trail, streamed
  // read-only from every owning service's own `<schema>.audit_log` (see
  // [auditLogTable]'s doc for why they share one local table). Column set
  // mirrors the server DDL exactly, minus nothing — these entries stream as a
  // flat `SELECT *`, so unlike the explicit-column tables above there is no
  // superset-drift hazard to guard here. `change_type` is the create|update|
  // delete kind; `changed_fields` is a JSON-encoded array, null on
  // create/delete; `actor_user_id` is nullable (history.md §3 allows an
  // unresolvable actor) and is resolved to a display name client-side against
  // the org roster (memberNamesProvider), never stored here as PII (§7.3).
  Table(auditLogTable, [
    Column.text('organization_id'),
    Column.text('entity_type'),
    Column.text('entity_id'),
    Column.text('change_type'),
    Column.text('actor_user_id'),
    Column.text('occurred_at'),
    Column.text('recorded_at'),
    Column.text('changed_fields'),
    Column.text('change'),
  ]),
  // sync_conflict_log (#60, FR-HIS-1, history.md §4.2/§6): LWW losses, shown
  // in the same timeline as a [supersededEventKind] event. `winner` is
  // server|client; the two payload columns are the JSON-encoded winning/losing
  // rows. `occurred_at` is nullable here (unlike audit_log's) — it is the
  // device time of the losing edit, which an op may not carry.
  Table(syncConflictLogTable, [
    Column.text('organization_id'),
    Column.text('entity_type'),
    Column.text('entity_id'),
    Column.text('winning_payload'),
    Column.text('losing_payload'),
    Column.text('winner'),
    Column.text('actor_user_id'),
    Column.text('occurred_at'),
    Column.text('recorded_at'),
  ]),
  // Dead-letter for permanently-rejected uploads (see [rejectedOpsTable] doc).
  // Local-only: never syncs up/down, wiped by clear() with the rest of the
  // local slice on logout / membership loss (§3.5).
  Table.localOnly(rejectedOpsTable, [
    Column.text('entity_type'), // 'apiary' | 'apiary_counter'
    Column.text(dedupKeyColumn), // server identity (see doc)
    Column.text('fix_apiary_id'), // apiary the "Fix" action deep-links to
    Column.text('op'), // 'put' | 'patch' | 'delete'
    Column.text('payload'), // JSON of the op we POSTed
    Column.text('error_code'), // RFC 9457 problem code (e.g. validation.failed)
    Column.text(
      'error_detail',
    ), // JSON: { detail, errors[] } field-level detail
    Column.text('rejected_at'), // device time, ISO-8601 UTC
  ]),
]);
