import 'dart:convert';
import 'dart:developer' as developer;

import 'package:meta/meta.dart';

import 'sync_validation_rules.dart';

/// The problem `code` a **client-predicted** rejection carries, distinguishing
/// it from the server's own `validation.failed` in the `sync_rejected_ops`
/// dead-letter and in [SyncOpFieldError]-derived UI. It matters that the two
/// stay distinguishable: a client-predicted rejection is a prediction the
/// server never got to disagree with, so it is worth telling the user (and a
/// log reader) that the change was never sent, rather than that it was refused.
const localValidationFailedCode = 'validation.failed.local';

/// One pre-push validation failure — the client-side twin of the server's RFC
/// 9457 `problem.FieldError` (`services/servicetemplate/problem`), already
/// split into the op it belongs to and the op-relative field path, matching
/// what `powersync_connector.dart`'s `RejectedFieldError` parses out of a
/// server rejection (`ops[<opIndex>].<field>`).
@immutable
class SyncOpFieldError {
  const SyncOpFieldError({
    required this.opIndex,
    required this.field,
    required this.code,
    required this.message,
  });

  /// Index of the offending op within the batch.
  final int opIndex;

  /// Op-relative field path, e.g. `data.name`, `op`, `id`.
  final String field;

  /// The server's machine code for this rule (`required`, `invalid`,
  /// `too_long`, `out_of_range`).
  final String code;

  /// The server's English message for this rule. **Diagnostics only** — the
  /// needs-fix UI shows a localized, non-technical message instead (#426).
  final String message;
}

/// Revalidates queued sync ops **before** they are pushed (FR-OF-2, D-12,
/// sync.md §9), against the shared validation description
/// (`contracts/validation/sync-ops.validation.json`) that mirrors each owning
/// service's `validate*Op`.
///
/// Runs entirely offline — no network, no database, pure function of the wire
/// ops. Call it on the ops **as they would be sent** (i.e. after
/// `powersync_connector.dart`'s `_toOp` has enriched counter identity and
/// decoded JSON columns), so what is checked is exactly what would go on the
/// wire.
///
/// **Never rejects what the server would accept** — the property that actually
/// costs a user something if it breaks, since a rejected op leaves the upload
/// queue and only a re-save re-queues it. Every `required` check is gated on the
/// same op kinds the server gates it on, so a partial `patch` is validated as a
/// partial update (#378) rather than as a full row.
///
/// The converse holds only *approximately*, on purpose: where a rule is hard to
/// mirror exactly, this errs toward **admitting** and letting the server decide
/// (see [_isUuid], which is looser than Go's `uuid.Parse` in a few unreachable
/// corners). Rules the description omits outright — cross-organization
/// ownership, activities' per-type attribute schema, the extensible
/// vocabularies — pass here by design.
///
/// An op whose `entity_type` the description doesn't know is passed through
/// unvalidated — deferring to the server is always the safe direction.
///
/// **Fails open, on purpose.** If the description can't be loaded or evaluated
/// at all, this reports **no** errors rather than throwing. D-12 makes the
/// server authoritative and this pass a UX optimization, so the correct
/// degraded mode is "skip the optimization and let the server decide", never
/// "stop syncing": a throw here would escape `uploadData`, which PowerSync
/// treats as transient and retries forever, stalling every pending write behind
/// a defect in an artifact that isn't a security control. A malformed
/// description is still caught at build time, by
/// `sync_validation_rules_test.dart` — that is where it should fail, not on a
/// beekeeper's device.
List<SyncOpFieldError> validateSyncOps(
  List<Map<String, dynamic>> ops, {
  SyncValidationRules? rules,
}) {
  try {
    final ruleSet = rules ?? SyncValidationRules.shared;
    return [
      for (var i = 0; i < ops.length; i++) ..._validateOp(ruleSet, i, ops[i]),
    ];
  } on Object catch (error, stackTrace) {
    developer.log(
      'validation parity unavailable; deferring to the authoritative server',
      name: 'sync',
      error: error,
      stackTrace: stackTrace,
    );
    return const [];
  }
}

List<SyncOpFieldError> _validateOp(
  SyncValidationRules rules,
  int index,
  Map<String, dynamic> op,
) {
  final entity = rules.entities[op['entity_type']];
  if (entity == null) return const [];

  final errors = <SyncOpFieldError>[];
  void report(String field, SyncOutcome outcome) => errors.add(
    SyncOpFieldError(
      opIndex: index,
      field: field,
      code: outcome.code,
      message: outcome.message,
    ),
  );

  final opKind = op['op'] as String? ?? '';
  if (!entity.allowedOps.contains(opKind)) {
    report('op', entity.opOutcome);
  }
  if (!_isUuid(op['id'])) {
    report('id', rules.envelope.id);
  }
  final updatedAt = op['updated_at'];
  if (updatedAt == null || (updatedAt is String && updatedAt.isEmpty)) {
    report('updated_at', rules.envelope.updatedAt);
  }
  // A delete carries no payload — the server's validators return here too, so
  // no data-shaped rule may fire against an op that has no data.
  if (opKind == 'delete') return errors;

  final data = op['data'] as Map<String, dynamic>? ?? const {};
  for (final field in entity.fields) {
    for (final check in field.checks) {
      final outcome = _runCheck(field, check, data, opKind);
      if (outcome != null) report('data.${field.name}', outcome);
    }
  }
  for (final check in entity.entityChecks) {
    if (_entityCheckFails(check, data, opKind)) {
      final path = check.reportAs.isEmpty ? 'data' : 'data.${check.reportAs}';
      report(path, check.outcome);
    }
  }
  return errors;
}

/// Runs one field check, returning the failure outcome or null.
SyncOutcome? _runCheck(
  SyncFieldRules field,
  SyncCheck check,
  Map<String, dynamic> data,
  String opKind,
) {
  final value = data[field.name];

  // jsonObject/maxBytes read the RAW presence rather than the "absent" notion:
  // the server unmarshals these into a json.RawMessage, where an explicit
  // `null` is four present bytes, not a nil field. So a missing key skips them,
  // and a present `null` does NOT — unless the field is marked
  // [SyncFieldAbsence.jsonNull], the one absence rule whose server guard also
  // skips that literal (journeys' `default_attributes`: the wire form of a
  // cleared bag, which is what PowerSync uploads for a column set to SQL NULL).
  if (check.kind == SyncCheckKind.jsonObject ||
      check.kind == SyncCheckKind.maxBytes) {
    if (!data.containsKey(field.name)) return null;
    if (value == null && field.absence == SyncFieldAbsence.jsonNull) {
      return null;
    }
    if (check.kind == SyncCheckKind.jsonObject) {
      return value is Map ? null : check.outcome;
    }
    final bytes = utf8.encode(jsonEncode(value)).length;
    return bytes > check.limit! ? check.outcome : null;
  }

  final absent = _isAbsent(field.absence, data, field.name);
  if (check.kind == SyncCheckKind.requiredOn) {
    return absent && check.on.contains(opKind) ? check.outcome : null;
  }
  if (absent) return null;
  if (check.onlyWithAll.any((f) => data[f] == null)) return null;

  return switch (check.kind) {
    // Byte length, not UTF-16 code units: the server compares Go's len() on a
    // UTF-8 string, so an accented Portuguese name must be measured the same
    // way or the two sides disagree exactly where it matters.
    SyncCheckKind.maxLength =>
      value is String && utf8.encode(value).length > check.limit!
          ? check.outcome
          : null,
    SyncCheckKind.min =>
      value is num && value < check.limit! ? check.outcome : null,
    SyncCheckKind.range =>
      value is num && (value < check.min! || value > check.max!)
          ? check.outcome
          : null,
    SyncCheckKind.uuid => _isUuid(value) ? null : check.outcome,
    SyncCheckKind.date => _isCalendarDate(value) ? null : check.outcome,
    SyncCheckKind.dateTime => _isRfc3339(value) ? null : check.outcome,
    // Handled above.
    SyncCheckKind.requiredOn ||
    SyncCheckKind.jsonObject ||
    SyncCheckKind.maxBytes => null,
  };
}

bool _entityCheckFails(
  SyncEntityCheck check,
  Map<String, dynamic> data,
  String opKind,
) {
  // Every entity-level check mirrors a server guard written against the decoded
  // struct's pointers, so "supplied" here always means "not null", regardless
  // of the field's own absence rule.
  return switch (check.kind) {
    SyncEntityCheckKind.requiredGroup =>
      check.on.contains(opKind) && check.fields.any((f) => data[f] == null),
    SyncEntityCheckKind.requiredWhenPresent =>
      data[check.whenPresent] != null && data[check.require] == null,
  };
}

bool _isAbsent(SyncFieldAbsence absence, Map<String, dynamic> data, String f) {
  final value = data[f];
  if (value == null) return true;
  return switch (absence) {
    // jsonNull differs from nullOnly only for the raw-presence checks handled
    // in [_runCheck]; a non-null value is present under both.
    SyncFieldAbsence.nullOnly || SyncFieldAbsence.jsonNull => false,
    SyncFieldAbsence.empty => value is String && value.isEmpty,
    SyncFieldAbsence.blank => value is String && value.trim().isEmpty,
  };
}

/// Deliberately **at least** as permissive as Go's `uuid.Parse` (the server side
/// of this rule), which accepts the canonical 8-4-4-4-12 form, a bare 32-hex
/// string, a `urn:uuid:` prefix (compared with `strings.EqualFold`, hence
/// `caseSensitive: false` here) and a braced form, and checks **no**
/// version/variant bits. A stricter RFC-4122 check would reject ids the server
/// accepts — the one direction client-side validation must never take.
///
/// It is a little *looser* than `uuid.Parse` in corners the client cannot reach:
/// each hyphen is independently optional and the braces need not balance, so a
/// hand-crafted half-hyphenated id would pass here and be rejected server-side.
/// That is the safe direction (defer to the server), and unreachable anyway —
/// ids come from `package:uuid` or from the server, always lowercase canonical.
final _uuidPattern = RegExp(
  r'^(urn:uuid:|\{)?[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?'
  r'[0-9a-f]{4}-?[0-9a-f]{12}\}?$',
  caseSensitive: false,
);

bool _isUuid(Object? value) => value is String && _uuidPattern.hasMatch(value);

final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');

/// Mirrors Go's `time.Parse("2006-01-02", …)`: the exact layout **and** a real
/// calendar date. Dart's `DateTime.parse` rolls `2026-02-30` over into March,
/// so the round-trip comparison is what actually rejects it.
bool _isCalendarDate(Object? value) {
  if (value is! String) return false;
  final match = _datePattern.firstMatch(value);
  if (match == null) return false;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  if (month < 1 || month > 12 || day < 1) return false;
  final parsed = DateTime.utc(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day;
}

/// Mirrors Go's `time.Parse(time.RFC3339Nano, …)`: an uppercase `T`, seconds,
/// optional fractional seconds, and a mandatory `Z` or `±hh:mm` offset — all
/// stricter than Dart's `DateTime.parse`, which would otherwise accept strings
/// the server rejects.
final _rfc3339Pattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$',
);

bool _isRfc3339(Object? value) {
  if (value is! String) return false;
  final match = _rfc3339Pattern.firstMatch(value);
  if (match == null) return false;
  return _isCalendarDate(
    '${match.group(1)}-${match.group(2)}-${match.group(3)}',
  );
}
