/// Turns a server rejection's machine-readable RFC 9457 detail into **safe,
/// localized** user copy (#443, follow-up to #426/#434).
///
/// #426 stopped the needs-fix screen surfacing the server's raw validation
/// text, which is English-only and can embed internal DB column names
/// ("default_attributes must be a JSON object"). The blanket fix showed one
/// generic message for *every* rejection, so the user learned that something
/// was wrong but not what. This maps the parts of the problem body that are
/// already machine-readable — the per-field `code` and the field's own name —
/// onto EN/PT copy the app owns, so specific guidance comes back without the
/// raw text ever reaching the UI (FR-OF-2, sync.md §8).
///
/// Two deliberate rules keep this leak-proof by construction:
///
/// 1. **Allow-list, never passthrough.** Only a field name this file
///    explicitly labels, paired with a code it explicitly maps, produces
///    specific copy. Anything else (a new server field, a new code, the wire
///    envelope's own `op`/`entity_type`/`id`/`updated_at`/`data`/`ops`) falls
///    back to the generic message — a new server validator can never leak by
///    default.
/// 2. **No server string is ever rendered.** Neither the field name nor the
///    message from the body is interpolated into the output; the field name is
///    only ever a lookup key.
///
/// Deliberately free of any dependency on the dead-letter read model
/// (`sync_rejected_repository.dart`) or on widgets, so the client-side
/// pre-push revalidation path (#584) can reuse the same mapping for failures
/// it detects itself.
library;

import 'package:flutter/foundation.dart';

import '../../l10n/gen/app_localizations.dart';

/// One field-level rejection the server reported: the field it refers to and
/// the machine `code` it broke (`required`, `invalid`, `out_of_range`,
/// `too_long`, `not_found`, ... — `problem.FieldError` in
/// `services/*/api/sync.go`).
///
/// [field] is the wire path with the batch-op prefix already stripped by
/// `powersync_connector.dart`'s `parseRejectedProblem` (`ops[3].data.name`
/// arrives here as `data.name`).
@immutable
class RejectedFieldIssue {
  const RejectedFieldIssue({required this.field, required this.code});

  final String field;
  final String code;

  @override
  bool operator ==(Object other) =>
      other is RejectedFieldIssue && other.field == field && other.code == code;

  @override
  int get hashCode => Object.hash(field, code);

  @override
  String toString() => 'RejectedFieldIssue($field, $code)';
}

/// How many field messages one rejection may show. A rejected op can carry a
/// dozen field errors (a `put` of a half-filled record); listing them all
/// would bury the row's actions under a wall of text on a phone held in
/// gloves. Three is enough to act on; the rest resurface on the next push if
/// they are still wrong.
const int maxRejectionMessages = 3;

/// The localized lines to show for one rejection, in the order the server
/// reported them: one per mapped field issue (de-duplicated, capped at
/// [maxRejectionMessages]).
///
/// Never empty — when nothing maps (no field detail at all, an unknown field,
/// or an unknown code) it degrades to [fallback], defaulting to
/// `syncNeedsFixGenericProblem`, which is exactly #426's behavior.
///
/// [fallback] exists for the pre-push validation-parity path (#584): a failure
/// the client predicted itself was never sent, so "this change was rejected"
/// would be wrong for it. That path produces the same `(field, code)` shape
/// (its `localValidationProblem` synthesizes a `RejectedProblem`), so the
/// per-field mapping below already applies to it unchanged — only the
/// nothing-mapped wording differs.
List<String> localizedRejectionMessages(
  AppLocalizations l10n,
  List<RejectedFieldIssue> fieldIssues, {
  String? fallback,
}) {
  final messages = <String>[];
  for (final issue in fieldIssues) {
    final message = localizedFieldIssueMessage(l10n, issue);
    if (message == null || messages.contains(message)) continue;
    messages.add(message);
    if (messages.length == maxRejectionMessages) break;
  }
  if (messages.isNotEmpty) return messages;
  return [fallback ?? l10n.syncNeedsFixGenericProblem];
}

/// The localized line for a single field issue, or null when either half of
/// the pair is unmapped — the caller then falls back (see
/// [localizedRejectionMessages]). Exposed on its own so #584's pre-push
/// revalidation can render one locally-detected failure without synthesizing
/// a whole rejection.
String? localizedFieldIssueMessage(
  AppLocalizations l10n,
  RejectedFieldIssue issue,
) {
  final field = _normalizeField(issue.field);
  final label = _fieldLabel(l10n, field);
  if (label == null) return null;
  final rule = _ruleMessage(l10n, field, issue.code);
  if (rule == null) return null;
  return l10n.syncNeedsFixFieldProblem(label, rule);
}

/// The wire envelope every batch op's field path is nested under
/// (`powersync_connector.dart`'s `_toOp`), stripped before the lookup.
const _dataPrefix = 'data.';

/// Reduces a wire field path to the key [_fieldLabel] looks up: drops the
/// [_dataPrefix] envelope, and collapses an activity's per-type attribute path
/// (`attributes.<key>`) onto the bag itself, since the individual attribute
/// keys are internal schema names with no localized label of their own
/// (`ValidateActivity` in `services/activities/api/types.go`). A journey's
/// `default_attributes` is only ever reported as the whole bag — journeys
/// validates its shape, not its keys — so there is no nested variant of it to
/// collapse.
String _normalizeField(String field) {
  var normalized = field.startsWith(_dataPrefix)
      ? field.substring(_dataPrefix.length)
      : field;
  final dot = normalized.indexOf('.');
  if (dot > 0) normalized = normalized.substring(0, dot);
  return normalized;
}

/// The localized label for a user-fixable field, or null for anything this
/// app does not have copy for — including the wire envelope's own fields
/// (`op`, `entity_type`, `id`, `updated_at`, `data`, `ops`), which describe
/// the sync protocol rather than anything the beekeeper typed.
String? _fieldLabel(AppLocalizations l10n, String field) => switch (field) {
  'name' => l10n.syncNeedsFixFieldName,
  'title' => l10n.syncNeedsFixFieldTitle,
  'description' => l10n.syncNeedsFixFieldDescription,
  'notes' => l10n.syncNeedsFixFieldNotes,
  'place_label' => l10n.syncNeedsFixFieldPlace,
  'location' => l10n.syncNeedsFixFieldLocation,
  'location_lat' => l10n.syncNeedsFixFieldLatitude,
  'location_lon' => l10n.syncNeedsFixFieldLongitude,
  'hive_count' => l10n.syncNeedsFixFieldHiveCount,
  'value' => l10n.syncNeedsFixFieldCount,
  'counter_type' => l10n.syncNeedsFixFieldCountType,
  'apiary_id' => l10n.syncNeedsFixFieldApiary,
  'journey_id' => l10n.syncNeedsFixFieldJourney,
  'assignee_id' => l10n.syncNeedsFixFieldAssignee,
  'type' => l10n.syncNeedsFixFieldActivityType,
  'main_activity_type' => l10n.syncNeedsFixFieldMainActivityType,
  'occurred_at' => l10n.syncNeedsFixFieldDate,
  'due_date' => l10n.syncNeedsFixFieldDueDate,
  'completed_at' => l10n.syncNeedsFixFieldCompletedAt,
  'priority' => l10n.syncNeedsFixFieldPriority,
  'status' => l10n.syncNeedsFixFieldStatus,
  'attributes' => l10n.syncNeedsFixFieldDetails,
  'default_attributes' => l10n.syncNeedsFixFieldActivityDefaults,
  _ => null,
};

/// The localized rule fragment for one `(field, code)` pair, or null when
/// this app has no truthful copy for it — an unmapped code, or a pair whose
/// generic copy would misdescribe the actual constraint. A few fields get a
/// sharper message than the code alone can give: the exact bound is part of
/// the API contract, not of the server's wording, so restating it here can't
/// drift into a leak.
String? _ruleMessage(AppLocalizations l10n, String field, String code) {
  // An activity's attributes are a BAG: the server reports one error per
  // offending entry (`attributes.<key>`), all of which collapse onto the one
  // "Details" label. The plain fragments would then say "Details: this is
  // required." about a Details section the user did fill in — and two missing
  // entries would de-duplicate down to that single misleading line. So the bag
  // gets its own wording, phrased about the entries inside it, which stays
  // true for one offending entry or several.
  if (field == 'attributes') {
    return switch (code) {
      'required' => l10n.syncNeedsFixRuleAttributeRequired,
      'invalid' => l10n.syncNeedsFixRuleAttributeInvalid,
      'too_long' => l10n.syncNeedsFixRuleAttributeTooLong,
      'out_of_range' => l10n.syncNeedsFixRuleAttributeOutOfRange,
      _ => null,
    };
  }
  if (code == 'out_of_range') {
    return switch (field) {
      'hive_count' || 'value' => l10n.syncNeedsFixRuleNonNegative,
      'location_lat' => l10n.syncNeedsFixRuleLatitudeRange,
      'location_lon' => l10n.syncNeedsFixRuleLongitudeRange,
      _ => l10n.syncNeedsFixRuleOutOfRange,
    };
  }
  // A journey's default_attributes is capped in BYTES of encoded JSON
  // (`validateDefaultAttributes`, services/journeys/api/types.go), not in
  // characters of a text field the user could shorten — "this text is too
  // long" would be both untrue and unactionable, so this one pair falls
  // through to the generic message. An activity's own attributes.<key>
  // too_long IS a real string-length cap, and keeps the fragment.
  if (code == 'too_long' && field == 'default_attributes') return null;
  return switch (code) {
    'required' => l10n.syncNeedsFixRuleRequired,
    'invalid' => l10n.syncNeedsFixRuleInvalid,
    'too_long' => l10n.syncNeedsFixRuleTooLong,
    'not_found' => l10n.syncNeedsFixRuleNotFound,
    _ => null,
  };
}
