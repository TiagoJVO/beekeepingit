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
]);
