/// Engine-agnostic seam over the on-device local store + sync engine
/// (NFR-ARC-2, #55). Feature repositories (e.g.
/// `features/apiaries/apiaries_repository.dart`) depend on [LocalStoreEngine]
/// — never on a concrete engine type like `PowerSyncDatabase` directly — so
/// swapping the sync engine later is a change behind this file, not a
/// feature-by-feature rewrite. [PowerSyncLocalStore]
/// (`powersync_local_store.dart`) is the only implementation today.
///
/// Kept intentionally minimal (read/watch/write + lifecycle): it covers
/// exactly what `ApiariesRepository` needs today, not a speculative superset.
/// SQL stays engine-specific by design — every engine PowerSync-shaped enough
/// to be a realistic swap-in (e.g. ElectricSQL, per
/// docs/spikes/sp-1-powersync-vs-electricsql.md) is itself a SQLite-over-HTTP
/// sync layer, so a parameterized-SQL local read/write surface is the right
/// level of abstraction, not a bespoke query DSL.
abstract interface class LocalStoreEngine {
  /// A live query: emits the current result set immediately, then again on
  /// every local write that could affect it (the engine's own change
  /// notification, e.g. PowerSync's `watch`).
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]);

  /// A one-shot query, or null if it matches no rows.
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]);

  /// A one-shot query returning every matching row (empty list if none) —
  /// [getOptional]'s multi-row counterpart. Added for #45 (journeys):
  /// reconciling a journey's plan-items diff on edit needs the CURRENT full
  /// row set once, not a live subscription ([watch]) or a single row
  /// ([getOptional]) — the same kind of genuine new need [clear]'s own doc
  /// comment describes ("the abstraction should not need to grow a new
  /// method the next time a caller wants X"), now realized for a one-shot
  /// multi-row read.
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]);

  /// Executes a local write (INSERT/UPDATE/DELETE). Writes are optimistic —
  /// applied to the local store immediately and queued for upload by the
  /// engine's own sync lifecycle (sync.md §5.1); callers never talk to the
  /// server directly.
  Future<void> execute(String sql, [List<Object?> args = const []]);

  /// Clears every locally-replicated row and drops the upload queue —
  /// e.g. on logout, so a second user on the same shared device/browser
  /// never sees the previous session's data before the next sync reconciles
  /// (auth_controller.dart's `logout()`). Exposed on the interface now (not
  /// added ad hoc later) because #125's planned `disconnectAndClear` needs
  /// it too — the abstraction should not need to grow a new method the next
  /// time a caller wants "log out and wipe local state".
  Future<void> clear();
}
