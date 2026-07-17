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
