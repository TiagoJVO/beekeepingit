/// Client-side mirror of services/activities/api/types.go's ValidateActivity
/// (#38, FR-AC-1) — the per-type attribute schema + server-side validation
/// rules, re-applied here so the client can catch the same problems offline,
/// before a write ever reaches the server (D-12: "the client revalidates
/// queued edits against the same rules the server will apply, as closely as
/// feasible"). The server stays authoritative; this is a UX optimization,
/// not a security boundary — exactly D-12's own framing.
///
/// This file intentionally does NOT wire into any screen/repository yet: the
/// add/edit activity UI is #39 and later EPIC-03 stories. It exists now so
/// the validation RULES are defined once, in lockstep with the Go registry,
/// rather than each future form screen inventing its own ad hoc checks.
library;

import 'activity_types.dart';

/// One validation failure, mirroring problem.FieldError's shape
/// (field/code/message) so a future error-display widget can reuse the same
/// rendering the server's RFC 9457 responses already need.
class ActivityAttributeError {
  const ActivityAttributeError({
    required this.field,
    required this.code,
    required this.message,
  });

  final String field;
  final String code;
  final String message;

  @override
  String toString() => 'ActivityAttributeError($field, $code, $message)';
}

const _maxNotesLength = 10000;

/// Mirrors services/activities/api/types.go's maxLotBatchLength (#292).
const _maxLotBatchLength = 100;

enum _Kind { string, number, integer }

class _AttrSpec {
  const _AttrSpec(
    this.key, {
    this.required = false,
    this.kind = _Kind.string,
    this.vocab,
    this.min,
    this.maxLen,
    this.requiredIf,
  });

  final String key;
  final bool required;
  final _Kind kind;
  final List<String>? vocab;
  final num? min;
  final int? maxLen;
  final bool Function(Map<String, dynamic> attrs)? requiredIf;
}

/// The extensible type registry (see file doc) — mirrors
/// services/activities/api/types.go's typeSchemas map key-for-key. Adding a
/// future type/attribute here AND in the Go registry keeps client/server
/// validation in lockstep; the two are cross-checked by
/// activity_attributes_test.dart and types_test.go sharing the same
/// fixtures conceptually (kept as parallel table-driven tests, not a shared
/// file, since the two run in different languages/toolchains).
final Map<String, List<_AttrSpec>> _typeSchemas = {
  activityTypeHarvest: [
    const _AttrSpec(
      'honey_supers',
      required: true,
      kind: _Kind.integer,
      min: 0,
    ),
    const _AttrSpec('honey_kg', kind: _Kind.number, min: 0),
    const _AttrSpec('hives_involved', kind: _Kind.integer, min: 0),
    // lot_batch (#292, FR-AC-1, D-19): optional free-text lot/batch
    // identifier captured at harvest time, for future traceability.
    // Capture-side only — export coverage is a separate story
    // (EPIC-09-NEW-C).
    const _AttrSpec('lot_batch', maxLen: _maxLotBatchLength),
    const _AttrSpec('notes', maxLen: _maxNotesLength),
  ],
  activityTypeFeeding: [
    const _AttrSpec('feed_type', required: true, vocab: feedTypes),
    const _AttrSpec('feed_amount', required: true, kind: _Kind.number, min: 0),
    const _AttrSpec('hives_involved', kind: _Kind.integer, min: 0),
    const _AttrSpec('notes', maxLen: _maxNotesLength),
  ],
  activityTypeTreatment: [
    const _AttrSpec(
      'treatment_context',
      required: true,
      vocab: treatmentContexts,
    ),
    // treatment_type is required UNLESS this is a detection-only report
    // (#291 AC: "a detection can be logged with no treatment attached
    // yet").
    _AttrSpec(
      'treatment_type',
      vocab: treatmentTypes,
      requiredIf: (attrs) =>
          attrs['treatment_context'] != treatmentContextDetectionOnly,
    ),
    _AttrSpec(
      'disease',
      vocab: diseaseConditions,
      requiredIf: (attrs) {
        final ctx = attrs['treatment_context'];
        return ctx == treatmentContextDiseaseSpecific ||
            ctx == treatmentContextDetectionOnly;
      },
    ),
    const _AttrSpec('hives_involved', kind: _Kind.integer, min: 0),
    const _AttrSpec('notes', maxLen: _maxNotesLength),
  ],
  activityTypeGeneric: [const _AttrSpec('notes', maxLen: _maxNotesLength)],
};

/// Validates [attributes] (already JSON-decoded, so a JSON number arrives as
/// `num`) against [type]'s registered schema. Returns one
/// [ActivityAttributeError] per violation — unknown activity type, an
/// attribute key not part of that type's schema, a missing required
/// attribute (including a conditionally-required one), or a malformed value
/// — or an empty list when [attributes] is valid for [type]. Mirrors
/// ValidateActivity's field-path convention (`attributes.<key>`, bare `type`
/// for the type-itself error) so error codes line up with the server's.
List<ActivityAttributeError> validateActivityAttributes(
  String type,
  Map<String, dynamic> attributes,
) {
  final specs = _typeSchemas[type];
  if (specs == null) {
    return [
      ActivityAttributeError(
        field: 'type',
        code: 'invalid',
        message:
            'type must be one of the known activity types: $knownActivityTypes',
      ),
    ];
  }

  final known = {for (final s in specs) s.key: s};
  final errors = <ActivityAttributeError>[];

  for (final key in attributes.keys) {
    if (!known.containsKey(key)) {
      errors.add(
        ActivityAttributeError(
          field: 'attributes.$key',
          code: 'invalid',
          message: '"$key" is not a valid attribute for activity type "$type"',
        ),
      );
    }
  }

  for (final spec in specs) {
    final err = _validateAttr(spec, type, attributes);
    if (err != null) errors.add(err);
  }

  errors.sort((a, b) => a.field.compareTo(b.field));
  return errors;
}

/// Validates a JOURNEY's `default_attributes` (#385) against [type]'s
/// schema — same rules [validateActivityAttributes] applies to a real
/// activity's attributes, EXCEPT a journey's defaults are always entirely
/// optional (a journey may specify a treatment's context without also
/// committing to its type/disease yet), so every `required`-coded error is
/// dropped. Vocabulary/type/length/range errors on whatever IS present are
/// still surfaced — a malformed or unknown-for-this-type default is still a
/// real problem, just not a REQUIRED one. Mirrors the server's identically
/// shallow validation split (services/journeys/api/types.go's
/// validateDefaultAttributes does shape-only checks; this is the client-side
/// deep-validation counterpart the server deliberately doesn't do, since it
/// must not import this per-type schema — #385's design doc).
List<ActivityAttributeError> validateJourneyDefaultAttributes(
  String type,
  Map<String, dynamic> attrs,
) {
  return validateActivityAttributes(
    type,
    attrs,
  ).where((e) => e.code != 'required').toList();
}

ActivityAttributeError? _validateAttr(
  _AttrSpec spec,
  String type,
  Map<String, dynamic> attrs,
) {
  final field = 'attributes.${spec.key}';
  final present = attrs.containsKey(spec.key) && attrs[spec.key] != null;
  final required = spec.required || (spec.requiredIf?.call(attrs) ?? false);

  if (!present) {
    if (required) {
      return ActivityAttributeError(
        field: field,
        code: 'required',
        message: '"${spec.key}" is required for activity type "$type"',
      );
    }
    return null;
  }

  final value = attrs[spec.key];
  switch (spec.kind) {
    case _Kind.string:
      if (value is! String) {
        return ActivityAttributeError(
          field: field,
          code: 'invalid',
          message: '"${spec.key}" must be a string',
        );
      }
      if (spec.vocab != null && !spec.vocab!.contains(value)) {
        return ActivityAttributeError(
          field: field,
          code: 'invalid',
          message: '"${spec.key}" must be one of ${spec.vocab}',
        );
      }
      if (spec.maxLen != null && value.length > spec.maxLen!) {
        return ActivityAttributeError(
          field: field,
          code: 'too_long',
          message: '"${spec.key}" must be at most ${spec.maxLen} characters',
        );
      }
    case _Kind.number:
    case _Kind.integer:
      if (value is! num) {
        return ActivityAttributeError(
          field: field,
          code: 'invalid',
          message: '"${spec.key}" must be a number',
        );
      }
      if (spec.kind == _Kind.integer && value != value.truncate()) {
        return ActivityAttributeError(
          field: field,
          code: 'invalid',
          message: '"${spec.key}" must be an integer',
        );
      }
      if (spec.min != null && value < spec.min!) {
        return ActivityAttributeError(
          field: field,
          code: 'out_of_range',
          message: '"${spec.key}" must be >= ${spec.min}',
        );
      }
  }
  return null;
}
