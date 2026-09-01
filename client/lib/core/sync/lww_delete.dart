/// The durable **delete-time** LWW stamp (#276, FR-OF-1, D-12) — the one seam
/// every repository deletes a synced row through, and the one the connector
/// reads back from `CrudEntry.metadata` (powersync_connector.dart's
/// `lwwTimestampFor`).
///
/// **Why this exists.** `updated_at` is the last-write-wins comparator
/// (sync.md §4.3) and a delete participates in LWW like any other field-set
/// (§4.5) — but a queued DELETE carries **no payload** (`CrudEntry.opData` is
/// null for a delete), so it has no `updated_at` of its own. The connector
/// previously invented one at *upload* time and cached it in memory per queued
/// op. That held the timestamp still across PowerSync's fast forward-retry
/// loop, but not across an **app restart with the delete still queued**: the
/// next launch recomputed it, so a delete that sat offline for a day could
/// upload with today's timestamp and spuriously beat a genuinely newer
/// concurrent edit.
///
/// **How it is made durable.** The synced tables enable PowerSync's
/// `Table.trackMetadata` (powersync_schema.dart), which adds two hidden view
/// columns, `_metadata` and `_deleted`. PowerSync persists the metadata string
/// **with the queued op**, so it survives a restart exactly as the op itself
/// does. The timestamp is therefore captured once here, at delete-time, and
/// simply read back at upload time.
library;

import 'local_store.dart';

/// Deletes the row [id] from the synced table [table], capturing the device's
/// delete-time as the op's durable LWW comparator.
///
/// **The SQL shape is load-bearing, not stylistic.** A plain
/// `DELETE FROM <table> WHERE id = ?` cannot carry metadata — SQL has no way
/// to attach values to a DELETE — so the PowerSync core extension provides a
/// second trigger, `ps_view_delete2_`, declared `INSTEAD OF UPDATE ... WHEN
/// NEW._deleted IS TRUE`, and guards the ordinary update trigger with `WHEN
/// NEW._deleted IS NOT TRUE` (powersync-sqlite-core's `views.rs`). So this
/// statement — and only this statement — deletes the local row **and** queues
/// a `DELETE` op carrying `NEW._metadata`. Writing `_metadata` in an ordinary
/// `UPDATE` instead would queue a spurious empty `patch` the server rejects,
/// and a plain `DELETE` would queue a delete with no timestamp at all.
///
/// [now] is injectable so the capture is deterministic under test; it is
/// normalized to UTC, matching the ISO-8601 UTC form every other write in the
/// client stamps `updated_at` with.
Future<void> deleteWithLwwStamp(
  LocalStoreEngine store,
  String table,
  String id, {
  DateTime? now,
}) {
  final stamp = (now ?? DateTime.now()).toUtc().toIso8601String();
  return store.execute(
    'UPDATE $table SET _deleted = TRUE, _metadata = ? WHERE id = ?',
    [stamp, id],
  );
}

/// Reads a queued op's `CrudEntry.metadata` back as an LWW comparator, or null
/// when there isn't a usable one.
///
/// Deliberately defensive — it returns null (so the caller falls back) rather
/// than forwarding whatever string it was handed, because the value reaching
/// here is not always one [deleteWithLwwStamp] wrote:
/// - **null** for every `put`/`patch` (nothing sets `_metadata` on those) and
///   for any delete queued by an app version predating #276, which is still
///   sitting in the upload queue after the upgrade;
/// - **anything else** would be a bug or a future metadata format, and must
///   never be POSTed as `updated_at` — the server compares it as a timestamp,
///   and a garbage comparator is a silent wrong-winner, not a loud failure.
String? lwwTimestampFromDeleteMetadata(String? metadata) {
  if (metadata == null) return null;
  return DateTime.tryParse(metadata) == null ? null : metadata;
}
