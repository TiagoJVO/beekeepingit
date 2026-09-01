import 'dart:convert';
import 'dart:io';

import 'package:beekeepingit_client/core/validation/sync_op_validator.dart';
import 'package:flutter_test/flutter_test.dart';

/// The client half of the **boundary contract corpus**
/// (`contracts/validation/sync-ops.corpus.json`, sync.md §9, ADR-0025, D-12,
/// FR-OF-2, NFR-TST-1, #585).
///
/// `sync_op_validator_test.dart` checks this evaluator against hand-written
/// expectations — which is exactly where two independent implementations of one
/// description drift, because both halves of the expectation are written by the
/// same person at the same time. This file instead replays a corpus that the
/// owning services' Go validators are replayed against too
/// (`services/*/api/sync_validation_corpus_test.go`), so the accept/reject
/// decision and the exact `(field, code, message)` are compared **between the
/// two evaluators**, not between one evaluator and its author's memory.
///
/// A case's `expect` is what BOTH sides must report, and nothing else. Its
/// `serverOnly` list is what only the authoritative server reports — ownership
/// lookups, the extensible vocabularies (D-20), activities' attribute schema,
/// declarations' `breakdown`, the patch-changes-any rule — and the client must
/// report **none** of it. Deferring is always safe; predicting a rejection the
/// server would not have made costs a beekeeper a valid edit.
void main() {
  /// Repo-relative: `flutter test` runs with the client package as CWD.
  final corpusFile = File('../contracts/validation/sync-ops.corpus.json');

  test('the corpus artifact is present and well-formed', () {
    expect(corpusFile.existsSync(), isTrue);
    expect(_cases(corpusFile), isNotEmpty);
  });

  test('the canary op the cases below ride with is itself rejected', () {
    expect(
      validateSyncOps([_canaryOp]).map(_key).toSet(),
      _canaryOutcomes,
      reason:
          'if this changes, every case below silently loses its liveness '
          'check — fix the canary here, not the assertion in each case',
    );
  });

  group('the client evaluator agrees with the owning services', () {
    for (final testCase in _cases(corpusFile)) {
      test(testCase.name, () {
        // Each op is validated alongside a known-bad CANARY op, because
        // validateSyncOps fails OPEN by design: a throw anywhere inside it is
        // swallowed and reported as "no errors". Without the canary, a case
        // whose expectation is "both sides accept this" could not tell a
        // genuine accept from an evaluator that crashed on the op — the one
        // divergence this corpus would otherwise be blind to. If the canary's
        // own errors survive, the evaluator ran.
        final all = validateSyncOps([testCase.op, _canaryOp]);
        expect(
          all.where((e) => e.opIndex == 1).map(_key).toSet(),
          _canaryOutcomes,
          reason:
              'the canary op lost its errors while validating '
              '"${testCase.name}" — validateSyncOps threw and swallowed it '
              '(it fails open on purpose), so this case proves nothing. Run '
              'the evaluator against this op directly to see the exception.',
        );

        final actual = all.where((e) => e.opIndex == 0).toList();
        final unexpected = <SyncOpFieldError>[];
        final outstanding = [...testCase.expect];

        for (final error in actual) {
          final match = outstanding.indexWhere(
            (e) =>
                e.field == error.field &&
                e.code == error.code &&
                e.message == error.message,
          );
          if (match < 0) {
            unexpected.add(error);
          } else {
            outstanding.removeAt(match);
          }
        }

        if (outstanding.isEmpty && unexpected.isEmpty) return;
        fail(_report(testCase, actual, outstanding, unexpected));
      });
    }
  });

  test('every op index in a batch is reported against its own op — a validator '
      'that lost track of the index would attach failures to the wrong card in '
      'the needs-fix list', () {
    final testCases = _cases(corpusFile);
    final errors = validateSyncOps([for (final c in testCases) c.op]);

    final byIndex = <int, List<SyncOpFieldError>>{};
    for (final error in errors) {
      (byIndex[error.opIndex] ??= []).add(error);
    }
    for (var i = 0; i < testCases.length; i++) {
      final got = (byIndex[i] ?? const <SyncOpFieldError>[])
          .map((e) => '${e.field}|${e.code}')
          .toSet();
      final want = testCases[i].expect
          .map((e) => '${e.field}|${e.code}')
          .toSet();
      expect(got, want, reason: 'batch position $i is ${testCases[i].name}');
    }
  });

  test('the @repeat macro expands the way the Go harness expands it', () {
    expect(_expand('@repeat:3:ab'), 'ababab');
    expect(_expand('@repeat:0:a'), '');
    expect(_expand('plain'), 'plain');
    expect(_expand('@repeat:2:é'), 'éé');
  });
}

/// A deliberately invalid op used as a liveness check: it is not a corpus case,
/// it is the thing that proves the evaluator actually ran. Kept minimal and
/// self-contained so it breaks only if the apiary envelope rules themselves
/// change — in which case the dedicated test above says so once, rather than
/// every case failing at once.
final _canaryOp = <String, dynamic>{
  'op': 'put',
  'entity_type': 'apiary',
  'id': 'not-a-uuid',
  'data': <String, dynamic>{},
};

/// The `field|code` pairs [_canaryOp] must produce.
const _canaryOutcomes = {
  'id|invalid',
  'updated_at|required',
  'data.name|required',
  'data.location|required',
};

String _key(SyncOpFieldError error) => '${error.field}|${error.code}';

/// One corpus case, reduced to what this side has to assert.
class _CorpusCase {
  _CorpusCase({
    required this.name,
    required this.why,
    required this.op,
    required this.expect,
    required this.serverOnly,
  });

  final String name;
  final String why;
  final Map<String, dynamic> op;

  /// What both sides must report — and nothing else.
  final List<_Outcome> expect;

  /// What only the server reports. Kept for the failure message: an error the
  /// client raised that is listed here is not merely "unexpected", it is the
  /// client having predicted a rejection it was told to leave to the server.
  final List<_Outcome> serverOnly;
}

class _Outcome {
  _Outcome(this.field, this.code, this.message, this.why);

  final String field;
  final String code;
  final String message;
  final String why;

  @override
  String toString() => message.isEmpty
      ? '$field  $code  (any message)'
      : '$field  $code  "$message"';
}

List<_CorpusCase> _cases(File file) {
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final raw in json['cases'] as List<dynamic>)
      _caseFromJson(raw as Map<String, dynamic>),
  ];
}

_CorpusCase _caseFromJson(Map<String, dynamic> json) => _CorpusCase(
  name: json['name'] as String,
  why: json['why'] as String? ?? '',
  op: _expandValue(json['op']) as Map<String, dynamic>,
  expect: _outcomes(json['expect']),
  serverOnly: _outcomes(json['serverOnly']),
);

List<_Outcome> _outcomes(Object? raw) => [
  for (final entry in (raw as List<dynamic>? ?? const []))
    _Outcome(
      (entry as Map<String, dynamic>)['field'] as String,
      entry['code'] as String,
      entry['message'] as String? ?? '',
      entry['why'] as String? ?? '',
    ),
];

/// Resolves the corpus's one string macro, `@repeat:<count>:<unit>`, so a
/// 10001-character notes field does not have to be spelled out in the artifact.
/// `ExpandCorpusOp` in `services/shared/syncvalidation/corpus.go` does the same
/// three lines; the macro test above is what keeps the two honest.
Object? _expandValue(Object? value) => switch (value) {
  final String text => _expand(text),
  final List<dynamic> list => [for (final item in list) _expandValue(item)],
  final Map<String, dynamic> map => <String, dynamic>{
    for (final entry in map.entries) entry.key: _expandValue(entry.value),
  },
  _ => value,
};

const _repeatPrefix = '@repeat:';

String _expand(String value) {
  if (!value.startsWith(_repeatPrefix)) return value;
  final rest = value.substring(_repeatPrefix.length);
  final separator = rest.indexOf(':');
  if (separator < 0) {
    throw FormatException('malformed corpus macro', value);
  }
  final count = int.tryParse(rest.substring(0, separator));
  if (count == null || count < 0) {
    throw FormatException('malformed corpus macro', value);
  }
  return rest.substring(separator + 1) * count;
}

/// Names the diverging rule and both sides' behaviour, so the fix is obvious
/// from the CI log without re-running anything locally.
String _report(
  _CorpusCase testCase,
  List<SyncOpFieldError> actual,
  List<_Outcome> missing,
  List<SyncOpFieldError> unexpected,
) {
  final buffer = StringBuffer()
    ..writeln()
    ..writeln(
      'VALIDATION PARITY BROKEN — case "${testCase.name}" '
      '(contracts/validation/sync-ops.corpus.json)',
    );
  if (testCase.why.isNotEmpty) {
    buffer.writeln('  what the case is for: ${testCase.why}');
  }
  _writeOutcomes(
    buffer,
    '  the corpus says BOTH sides must report',
    testCase.expect,
  );
  _writeOutcomes(
    buffer,
    '  the corpus says ONLY the server reports (this client must stay silent)',
    testCase.serverOnly,
  );
  _writeErrors(buffer, '  this client actually reported', actual);
  _writeOutcomes(
    buffer,
    '  MISSING — the owning service reports this and this client did not',
    missing,
  );
  _writeErrors(
    buffer,
    '  UNEXPECTED — this client would have blocked the push over a rule '
    'nothing declares; the server never gets to disagree',
    unexpected,
  );
  buffer.writeln(
    '  Fix sync_op_validator.dart, or update the corpus AND the shared description '
    '(contracts/validation/sync-ops.validation.json) together — the owning service replays '
    'these same cases in services/*/api/sync_validation_corpus_test.go, so changing one '
    'side alone will fail there instead.',
  );
  return buffer.toString();
}

void _writeOutcomes(
  StringBuffer buffer,
  String label,
  List<_Outcome> outcomes,
) {
  buffer.writeln('$label:');
  if (outcomes.isEmpty) {
    buffer.writeln('    (nothing)');
    return;
  }
  for (final outcome in outcomes) {
    buffer.writeln('    $outcome');
  }
}

void _writeErrors(
  StringBuffer buffer,
  String label,
  List<SyncOpFieldError> errors,
) {
  buffer.writeln('$label:');
  if (errors.isEmpty) {
    buffer.writeln('    (nothing — it accepted the op)');
    return;
  }
  for (final error in errors) {
    buffer.writeln('    ${error.field}  ${error.code}  "${error.message}"');
  }
}
