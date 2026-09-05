/// The form-facing half of the **save-time** validation-parity check (#597,
/// FR-OF-2, D-12, sync.md §9): the localized line a form puts against the
/// offending field, with the record still open.
///
/// Deliberately thin, and deliberately **not** a second source of anything:
///
///  - the **rules** come from the shared description
///    (`contracts/validation/sync-ops.validation.json`), evaluated by the same
///    `validateSyncOps` the pre-push pass runs, over the same wire shape
///    ([SyncOpDraft]);
///  - the **copy** comes from #443's `sync_rejection_messages.dart` mapping,
///    reused unchanged — so the sentence a beekeeper reads in the form and the
///    one they would have read on the needs-fix card are the same sentence, in
///    both languages, and the description's English `message` stays what it
///    has always been: diagnostics, never UI.
library;

import 'package:flutter/foundation.dart';

import '../../core/sync/sync_op_draft.dart';
import '../../core/validation/sync_op_validator.dart';
import '../../l10n/gen/app_localizations.dart';
import 'sync_rejection_messages.dart';

/// The save-time failures of one draft, keyed by the data column each belongs
/// to, ready to be rendered by whatever a given form already uses for field
/// errors (a `TextFormField` validator, a live-region `Text`, an
/// `InputDecoration.errorText`) — this type deliberately renders nothing
/// itself, so no form has to adopt a foreign error pattern.
@immutable
class SaveTimeFieldErrors {
  const SaveTimeFieldErrors(this._byColumn);

  /// The empty verdict — a form's initial state, and what it returns to after
  /// a save that passed.
  const SaveTimeFieldErrors.none() : _byColumn = const {};

  /// Runs the check over [draft], reporting only the [columns] the calling
  /// form binds to a field of its own (see [SyncOpDraft.validateColumns] for
  /// why anything else is deliberately left to the server).
  factory SaveTimeFieldErrors.check(
    SyncOpDraft draft, {
    required Set<String> columns,
  }) => SaveTimeFieldErrors(Map.unmodifiable(draft.validateColumns(columns)));

  final Map<String, SyncOpFieldError> _byColumn;

  bool get isEmpty => _byColumn.isEmpty;
  bool get isNotEmpty => _byColumn.isNotEmpty;

  /// Whether [column] failed — for a caller that needs to **act** on the
  /// failure rather than render it, e.g. focusing the first offending field so
  /// a form whose Save button sits outside the scroll view doesn't look like it
  /// did nothing.
  bool contains(String column) => _byColumn.containsKey(column);

  /// The localized message for [column], or null when that column passed.
  ///
  /// Never the description's own English `message`, and never the snake_case
  /// column name: both stay diagnostics-only, exactly as on the needs-fix
  /// screen (#426/#443). A `(field, code)` pair #443 has no specific copy for
  /// — such as the stock-declaration fields it closed without labels for, or a
  /// rule added to the description later — degrades to a truthful generic
  /// line rather than to silence, so the offending field is still identified
  /// by the form and still fixable before the save.
  String? messageFor(AppLocalizations l10n, String column) {
    final error = _byColumn[column];
    if (error == null) return null;
    return localizedRejectionMessages(l10n, [
      RejectedFieldIssue(field: error.field, code: error.code),
    ], fallback: l10n.syncSaveCheckGenericProblem).first;
  }

  /// The message for the first of [columns] that failed — for a control that
  /// stands for several columns at once, such as the apiary form's single map
  /// pin behind `location` / `location_lat` / `location_lon`.
  String? messageForAny(AppLocalizations l10n, List<String> columns) {
    for (final column in columns) {
      final message = messageFor(l10n, column);
      if (message != null) return message;
    }
    return null;
  }
}
