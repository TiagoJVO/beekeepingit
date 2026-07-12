import 'package:powersync/powersync.dart';

/// Local table name — matches the unqualified name PowerSync's Sync Rules
/// stream produces from `apiaries.apiaries` (sync.md §5.1). The server-side
/// entity type is the singular `apiary`.
const apiariesTable = 'apiaries';
const apiaryEntityType = 'apiary';

/// The on-device SQLite schema PowerSync manages. The `id` primary key is
/// implicit (client-generated UUID). `deleted_at` is NOT a local column:
/// the Sync Rules exclude tombstoned rows, so a server-side delete simply
/// leaves the client's result set and PowerSync removes the row locally.
///
/// `notes` (FR-AP-8, #196) is optional free-text, nullable like the server
/// column it mirrors.
///
/// `location_lon`/`location_lat` (#34/#37, FR-AP-3/FR-AP-5) are plain
/// nullable REAL columns — the Sync Rules bucket for `apiaries.apiaries`
/// projects the server's PostGIS `geography(Point,4326)` column to these via
/// `ST_X`/`ST_Y(location::geometry)` (infra/helm/beekeepingit/charts/
/// powersync/values.yaml) rather than streaming the raw geography column,
/// which arrives in a wire form (EWKB) this client has no parser for. Both
/// null together when the apiary has no stored location (nullable, matching
/// the DB column's own optionality).
const appSchema = Schema([
  Table(apiariesTable, [
    Column.text('organization_id'),
    Column.text('name'),
    Column.integer('hive_count'),
    Column.text('notes'),
    Column.text('created_at'),
    Column.text('updated_at'),
    Column.real('location_lon'),
    Column.real('location_lat'),
  ]),
]);
