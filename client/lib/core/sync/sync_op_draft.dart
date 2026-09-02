import 'package:meta/meta.dart';

import '../validation/sync_op_validator.dart';
import '../validation/sync_validation_rules.dart';

/// One sync write-back op in its **wire shape** — the single place that shape
/// is built, so the two call sites of the validation-parity pass (FR-OF-2,
/// D-12, sync.md §9) cannot be looking at different bytes:
///
///  - `powersync_connector.dart`'s `_toOp` builds one per queued CRUD entry,
///    **before pushing** (#584);
///  - a form builds one from the values the user is about to save, **at save
///    time** (#597), so the beekeeper is told with the record still open
///    rather than at the next push.
///
/// Both then run the same [validateSyncOps] evaluator over the same shared
/// description (`contracts/validation/sync-ops.validation.json`), so there is
/// still exactly **one** source of truth for the rules — this type only makes
/// the *envelope* shared too.
///
/// The save-time caller is responsible for handing over the data the wire op
/// would carry, not the local row: counter identity enriched and JSON columns
/// decoded to objects, exactly as `_toOp` leaves them (the repositories' own
/// draft builders do this next to the SQL they mirror).
///
/// **The payload is an approximation, and deliberately the safe one.** A
/// save-time draft is the whole row the save is about to write; the op the
/// queue actually carries for an `update` is PowerSync's own column diff, and
/// may not exist at all where a repository's change-scoped write finds nothing
/// changed. So a save-time draft is a **superset** of an edit's real payload.
/// That only ever makes this pass see MORE than the pre-push one, and on an
/// edit `required` rules do not apply anyway (the op is a `patch`, #378), so
/// the extra columns are only checked against the same bounds a later full-row
/// write would face. The direction that would cost a beekeeper an edit — the
/// save-time pass seeing *less* than the wire op — cannot happen.
@immutable
class SyncOpDraft {
  const SyncOpDraft({
    required this.op,
    required this.entityType,
    required this.id,
    required this.data,
    required this.updatedAt,
  });

  /// `put`, `patch` or `delete`.
  final String op;

  /// The wire `entity_type` (`powersync_schema.dart`'s entity-type constants).
  final String entityType;

  /// The record's id — [draftPlaceholderId] for a record that does not exist
  /// yet (see that constant's doc for why that is safe).
  final String id;

  /// The op payload, keyed by the **server's** column names. Null for a
  /// `delete`, which carries no payload.
  final Map<String, dynamic>? data;

  /// The LWW comparator (sync.md §4.3).
  final Object? updatedAt;

  /// The op as `POST /v1/sync/batch` receives it.
  Map<String, dynamic> toWireOp() => {
    'op': op,
    'entity_type': entityType,
    'id': id,
    'data': data,
    'updated_at': updatedAt,
  };

  /// The save-time verdict for this draft: the first failure per data column,
  /// keyed by column, restricted to [columns].
  ///
  /// [columns] is the set of columns the caller can actually **put an error
  /// against** — a form's own bound fields. Everything else is dropped rather
  /// than reported, which is what keeps this advisory (D-12):
  ///
  ///  - the wire **envelope** (`op`, `id`, `updated_at`) is never reported at
  ///    all: it describes the sync protocol, nothing the beekeeper typed, and
  ///    a form that blocked on it could not be saved by any edit the user is
  ///    able to make;
  ///  - a column the caller does not bind is left to the pre-push pass and to
  ///    the authoritative server, exactly as before this check existed.
  ///
  /// Everything [validateSyncOps] already guarantees carries over unchanged:
  /// it never reports a rule the server would not apply (`put`-only `required`
  /// checks stay gated on the op kind, #378), an unknown `entity_type` is
  /// passed through unvalidated, rules the description omits by design
  /// (cross-org ownership, the extensible vocabularies of D-20, activities'
  /// attribute-bag schema) are not checked here, and the whole pass **fails
  /// open** — a defect in the description or evaluator reports nothing rather
  /// than throwing, so it can never make a form unsaveable.
  Map<String, SyncOpFieldError> validateColumns(
    Set<String> columns, {
    SyncValidationRules? rules,
  }) {
    final errors = <String, SyncOpFieldError>{};
    for (final error in validateSyncOps([toWireOp()], rules: rules)) {
      final column = _columnOf(error.field);
      if (column == null || !columns.contains(column)) continue;
      // First failure wins: a column that breaks two rules at once still gets
      // one message, in the order the description declares them.
      errors.putIfAbsent(column, () => error);
    }
    return errors;
  }
}

/// The id a draft of a **not-yet-created** record carries. The real id is
/// minted by the repository's `create`, so save time has none — and the
/// envelope's `id` check is never surfaced anyway ([SyncOpDraft.validateColumns]),
/// so any syntactically valid UUID does. A nil UUID makes it obvious in a log
/// or a debugger that this op was never queued.
const draftPlaceholderId = '00000000-0000-0000-0000-000000000000';

/// The LWW stamp a save-time draft carries — the same
/// `DateTime.now().toUtc()` ISO-8601 string every repository writes to
/// `updated_at`, so the draft mirrors the row the save is about to write
/// rather than inventing a shape of its own.
String draftUpdatedAt() => DateTime.now().toUtc().toIso8601String();

/// The wire envelope every op's data-field path is nested under.
const _dataPrefix = 'data.';

/// The data column one reported field path refers to, or null when the path is
/// not a data field at all (the envelope's own `op`/`id`/`updated_at`).
String? _columnOf(String field) =>
    field.startsWith(_dataPrefix) ? field.substring(_dataPrefix.length) : null;
