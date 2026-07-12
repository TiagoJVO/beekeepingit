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
