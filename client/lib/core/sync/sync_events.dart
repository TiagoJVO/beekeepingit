/// One offline edit that lost a last-write-wins conflict on the server
/// (sync.md §4.2/§8: `superseded` — the push succeeded but this particular op
/// was overwritten by a newer server value). Emitted by
/// [BeekeepingitConnector.supersededChanges] so the shell (#58) can show a
/// non-blocking notice ("your change to X was overwritten by a newer edit").
/// The full conflict-log timeline (winning/losing payloads) is the
/// entity-history UI (FR-HIS, #59-#62), not this toast.
class SupersededChange {
  const SupersededChange({required this.entityType, required this.entityId});

  final String entityType;
  final String entityId;
}

/// One offline write the server **permanently rejected** on upload — a
/// validation-class `4xx` (RFC 9457 `422`/`400`) that can't heal on retry
/// (sync.md §8's `rejected` state, D-12 notify-and-fix, #256/#260). Unlike a
/// [SupersededChange] (an LWW loss the server preserves in `sync_conflict_log`
/// and replicates back), a rejection was **never accepted server-side**, so the
/// client is the only place the edit exists: the connector retains it in the
/// local `sync_rejected_ops` dead-letter (powersync_schema.dart) and emits this
/// so the shell (EPIC-06 #7) can surface a non-blocking "one of your changes
/// needs fixing" notice that routes to the needs-fix list.
///
/// [entityId] is the **apiary to fix** — the apiary id for an `apiary`
/// rejection, or the owning apiary's id for an `apiary_counter` one — so the
/// "Fix" action can deep-link straight to that apiary's edit screen.
class RejectedChange {
  const RejectedChange({
    required this.entityType,
    required this.entityId,
    required this.errorCode,
  });

  final String entityType;
  final String entityId;

  /// The RFC 9457 problem `code` (e.g. `validation.failed`), or `''` if the
  /// server sent no machine-readable code.
  final String errorCode;
}
