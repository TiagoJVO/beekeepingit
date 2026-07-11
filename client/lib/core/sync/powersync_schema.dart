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
/// `location_lon`/`location_lat` (FR-AP-2, #33) are plain nullable reals —
/// the Sync Rules bucket (infra/helm/beekeepingit/charts/powersync/
/// values.yaml) projects the server's PostGIS `geography(Point,4326)`
/// column through `ST_X`/`ST_Y` into these two columns rather than
/// streaming the geography value itself (Dart/SQLite has no PostGIS type to
/// parse it into). Null on both exactly when the apiary has no location set.
const appSchema = Schema([
  Table(apiariesTable, [
    Column.text('organization_id'),
    Column.text('name'),
    Column.integer('hive_count'),
    Column.text('created_at'),
    Column.text('updated_at'),
    Column.real('location_lon'),
    Column.real('location_lat'),
  ]),
]);
