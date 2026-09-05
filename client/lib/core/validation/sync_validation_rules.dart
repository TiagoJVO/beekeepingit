import 'dart:convert';

import 'gen/sync_validation_rules.g.dart';

/// The parsed form of the **shared sync-op validation description**
/// (`contracts/validation/sync-ops.validation.json`, docs/architecture/sync.md
/// §9, D-12, FR-OF-2) — the single definition of the mechanical rules each
/// owning service's `validate*Op` enforces
/// (`services/{apiaries,activities,journeys,todos}/api/sync.go`).
///
/// This file only *models and parses* the description; `sync_op_validator.dart`
/// interprets it. The description itself is embedded verbatim by
/// `scripts/gen-sync-validation.sh` into
/// [gen/sync_validation_rules.g.dart]'s `syncValidationRulesJson`, so the rule
/// **data** on the client is byte-identical to the shared file and cannot drift
/// from it — only this interpreter can, which is what #585's boundary contract
/// tests exist to catch.
///
/// **Deliberately partial.** Rules that need context the device does not have
/// offline (cross-organization ownership lookups, activities' per-type
/// attribute-bag schema) are absent from the description and left entirely to
/// the authoritative server. Parity is a UX optimization, not a security
/// boundary (D-12).
class SyncValidationRules {
  const SyncValidationRules({required this.envelope, required this.entities});

  /// The shared description, parsed once (lazily) from the generated constant.
  static final SyncValidationRules shared = parse(syncValidationRulesJson);

  /// Parses a description document. Throws [FormatException] on a malformed or
  /// structurally unexpected document — a defect in the committed artifact, and
  /// exactly what `sync_validation_rules_test.dart` asserts never happens.
  static SyncValidationRules parse(String source) {
    final json = jsonDecode(source);
    if (json is! Map<String, dynamic>) {
      throw const FormatException('validation description must be an object');
    }
    final entities = _requireMap(json, 'entities');
    return SyncValidationRules(
      envelope: SyncEnvelopeRules._fromJson(_requireMap(json, 'envelope')),
      entities: {
        for (final entry in entities.entries)
          entry.key: SyncEntityRules._fromJson(
            entry.key,
            _asMap(entry.value, 'entities.${entry.key}'),
          ),
      },
    );
  }

  /// Op-level rules shared by every entity type (`id`, `updated_at`).
  final SyncEnvelopeRules envelope;

  /// Per-`entity_type` rules, keyed by the wire `entity_type`
  /// (`powersync_schema.dart`'s entity-type constants).
  final Map<String, SyncEntityRules> entities;
}

/// The `id` / `updated_at` checks every op carries, regardless of entity type.
class SyncEnvelopeRules {
  const SyncEnvelopeRules({required this.id, required this.updatedAt});

  factory SyncEnvelopeRules._fromJson(Map<String, dynamic> json) {
    return SyncEnvelopeRules(
      id: SyncOutcome._fromJson(_requireMap(json, 'id')),
      updatedAt: SyncOutcome._fromJson(_requireMap(json, 'updatedAt')),
    );
  }

  /// `id` must be a UUID.
  final SyncOutcome id;

  /// `updated_at` (the LWW comparator, sync.md §4.3) is required.
  final SyncOutcome updatedAt;
}

/// The `(code, message)` a failing check reports — the RFC 9457
/// `problem.FieldError` half that is not the field path
/// (`services/servicetemplate/problem`).
class SyncOutcome {
  const SyncOutcome({required this.code, required this.message});

  factory SyncOutcome._fromJson(Map<String, dynamic> json) => SyncOutcome(
    code: _requireString(json, 'code'),
    message: _requireString(json, 'message'),
  );

  final String code;
  final String message;
}

/// The rules for one wire `entity_type`.
class SyncEntityRules {
  const SyncEntityRules({
    required this.entityType,
    required this.allowedOps,
    required this.opOutcome,
    required this.fields,
    required this.entityChecks,
  });

  factory SyncEntityRules._fromJson(String entityType, Map<String, dynamic> j) {
    final ops = _requireMap(j, 'ops');
    return SyncEntityRules(
      entityType: entityType,
      allowedOps: _stringList(ops['allowed'], 'ops.allowed'),
      opOutcome: SyncOutcome._fromJson(ops),
      fields: [
        for (final f in _list(j['fields']))
          SyncFieldRules._fromJson(_asMap(f, 'fields[]')),
      ],
      entityChecks: [
        for (final c in _list(j['entityChecks']))
          SyncEntityCheck._fromJson(_asMap(c, 'entityChecks[]')),
      ],
    );
  }

  final String entityType;

  /// The op kinds this entity accepts — e.g. an `apiary_counter` has no
  /// `delete` and a `journey_plan_item` has no `patch`.
  final List<String> allowedOps;

  /// What to report when the op kind is outside [allowedOps].
  final SyncOutcome opOutcome;

  final List<SyncFieldRules> fields;

  /// Checks that span more than one field (paired coordinates, "a patch must
  /// change something").
  final List<SyncEntityCheck> entityChecks;
}

/// How a field's value counts as "not supplied" — mirroring the exact guard the
/// server uses for that field, which differs per field and is load-bearing for
/// the `put`/`patch` distinction (#378).
enum SyncFieldAbsence {
  /// Only a missing/`null` value is absent (`data.X == nil`).
  nullOnly,

  /// `null` or the empty string (`data.X == nil || *data.X == ""`).
  empty,

  /// `null` or an all-whitespace string (`strings.TrimSpace(*data.X) == ""`).
  blank,

  /// A `json.RawMessage` field whose server guard skips an explicit JSON
  /// `null` as well as a missing key (`len(raw) == 0 || isJSONNull(raw)`).
  ///
  /// The distinction matters only for the shape checks that read RAW presence
  /// rather than this "absent" notion — `jsonObject` and `maxBytes`. For a
  /// RawMessage field WITHOUT this marker (activities' `attributes`), a
  /// present `null` is four wire bytes that are not an object, and the server
  /// rejects it; with it (journeys' `default_attributes`), the server reads it
  /// as "no defaults" — the wire form of a cleared bag, which is what
  /// PowerSync uploads for a column set to SQL NULL.
  jsonNull,
}

/// One field's rules inside an entity's `data` object.
class SyncFieldRules {
  const SyncFieldRules({
    required this.name,
    required this.absence,
    required this.checks,
  });

  factory SyncFieldRules._fromJson(Map<String, dynamic> json) => SyncFieldRules(
    name: _requireString(json, 'name'),
    absence: switch (json['absentWhen']) {
      null => SyncFieldAbsence.nullOnly,
      'empty' => SyncFieldAbsence.empty,
      'blank' => SyncFieldAbsence.blank,
      'jsonNull' => SyncFieldAbsence.jsonNull,
      final other => throw FormatException('unknown absentWhen: $other'),
    },
    checks: [
      for (final c in _list(json['checks']))
        SyncCheck._fromJson(_asMap(c, 'checks[]')),
    ],
  );

  final String name;
  final SyncFieldAbsence absence;
  final List<SyncCheck> checks;
}

/// The check kinds the description may use. Anything unknown is a defect in the
/// artifact, not something to skip silently — parsing throws.
enum SyncCheckKind {
  requiredOn,
  maxLength,
  maxBytes,
  min,
  range,
  uuid,
  date,
  dateTime,
  jsonObject,
}

/// One field-level check, plus the `(code, message)` it reports.
class SyncCheck {
  const SyncCheck({
    required this.kind,
    required this.outcome,
    this.on = const [],
    this.limit,
    this.min,
    this.max,
    this.onlyWithAll = const [],
  });

  /// Parses one check, rejecting a kind whose numeric parameters are missing.
  /// That coherence check earns its keep: the evaluator null-asserts `limit`/
  /// `min`/`max`, so a `maxLength` with no `limit` would otherwise parse
  /// cleanly and only blow up later, against a real op — i.e. green tests and a
  /// broken artifact. Failing here means the committed description's own parse
  /// test catches it instead.
  factory SyncCheck._fromJson(Map<String, dynamic> json) {
    final kind = _checkKind(_requireString(json, 'kind'));
    final limit = _optionalNum(json, 'limit');
    final min = _optionalNum(json, 'min');
    final max = _optionalNum(json, 'max');
    switch (kind) {
      case SyncCheckKind.maxLength:
      case SyncCheckKind.maxBytes:
      case SyncCheckKind.min:
        if (limit == null) {
          throw FormatException('check kind $kind needs a limit');
        }
      case SyncCheckKind.range:
        if (min == null || max == null) {
          throw const FormatException('check kind range needs min and max');
        }
      case SyncCheckKind.requiredOn:
      case SyncCheckKind.uuid:
      case SyncCheckKind.date:
      case SyncCheckKind.dateTime:
      case SyncCheckKind.jsonObject:
        break;
    }
    return SyncCheck(
      kind: kind,
      outcome: SyncOutcome._fromJson(json),
      on: _stringList(json['on'] ?? const [], 'on'),
      limit: limit,
      min: min,
      max: max,
      onlyWithAll: _stringList(json['onlyWithAll'] ?? const [], 'onlyWithAll'),
    );
  }

  final SyncCheckKind kind;
  final SyncOutcome outcome;

  /// For [SyncCheckKind.requiredOn]: the op kinds the field is required on. The
  /// server gates `required` on `op == "put"` for most fields precisely because
  /// a `patch` is a partial update (#378) — mirroring that gating is what keeps
  /// the client from rejecting perfectly valid partial patches.
  final List<String> on;

  /// [SyncCheckKind.maxLength] / [SyncCheckKind.maxBytes] / [SyncCheckKind.min].
  final num? limit;

  /// [SyncCheckKind.range] bounds.
  final num? min;
  final num? max;

  /// Only run this check when every named sibling field is also present —
  /// mirrors the server's `switch` that range-checks coordinates only once both
  /// halves of the pair are supplied.
  final List<String> onlyWithAll;
}

/// The entity-level (multi-field) check kinds.
enum SyncEntityCheckKind {
  /// Every named field is required, reported as one grouped field path.
  requiredGroup,

  /// If [SyncEntityCheck.whenPresent] is supplied, [SyncEntityCheck.require]
  /// must be too.
  requiredWhenPresent,
}

/// One entity-level check.
class SyncEntityCheck {
  const SyncEntityCheck({
    required this.kind,
    required this.outcome,
    required this.reportAs,
    this.on = const [],
    this.fields = const [],
    this.whenPresent,
    this.require,
  });

  factory SyncEntityCheck._fromJson(Map<String, dynamic> json) {
    final kind = switch (_requireString(json, 'kind')) {
      'requiredGroup' => SyncEntityCheckKind.requiredGroup,
      'requiredWhenPresent' => SyncEntityCheckKind.requiredWhenPresent,
      final other => throw FormatException('unknown entity check kind: $other'),
    };
    return SyncEntityCheck(
      kind: kind,
      outcome: SyncOutcome._fromJson(json),
      // requiredWhenPresent reports against the field it requires; the other
      // kinds carry an explicit (possibly empty) grouped path.
      reportAs:
          (json['reportAs'] as String?) ??
          (json['require'] as String?) ??
          (throw const FormatException(
            'entity check needs reportAs or require',
          )),
      on: _stringList(json['on'] ?? const [], 'on'),
      fields: _stringList(json['fields'] ?? const [], 'fields'),
      whenPresent: json['whenPresent'] as String?,
      require: json['require'] as String?,
    );
  }

  final SyncEntityCheckKind kind;
  final SyncOutcome outcome;

  /// The `data`-relative field path the failure is reported against — `''`
  /// reports against `data` itself.
  final String reportAs;

  final List<String> on;
  final List<String> fields;
  final String? whenPresent;
  final String? require;
}

SyncCheckKind _checkKind(String raw) => switch (raw) {
  'required' => SyncCheckKind.requiredOn,
  'maxLength' => SyncCheckKind.maxLength,
  'maxBytes' => SyncCheckKind.maxBytes,
  'min' => SyncCheckKind.min,
  'range' => SyncCheckKind.range,
  'uuid' => SyncCheckKind.uuid,
  'date' => SyncCheckKind.date,
  'dateTime' => SyncCheckKind.dateTime,
  'jsonObject' => SyncCheckKind.jsonObject,
  _ => throw FormatException('unknown check kind: $raw'),
};

Map<String, dynamic> _requireMap(Map<String, dynamic> json, String key) =>
    _asMap(json[key], key);

Map<String, dynamic> _asMap(Object? value, String where) {
  if (value is Map<String, dynamic>) return value;
  throw FormatException('$where must be an object');
}

List<Object?> _list(Object? value) {
  if (value == null) return const [];
  if (value is List) return List<Object?>.from(value);
  throw const FormatException('expected a list');
}

/// Reads an optional numeric field, reporting a wrong-typed value as the
/// [FormatException] this file's `parse` contract promises rather than as the
/// `TypeError` a bare `as num?` would throw.
num? _optionalNum(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is num) return value;
  throw FormatException('$key must be a number');
}

String _requireString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key must be a string');
}

List<String> _stringList(Object? value, String where) => [
  for (final v in _list(value))
    if (v is String) v else throw FormatException('$where must be strings'),
];
