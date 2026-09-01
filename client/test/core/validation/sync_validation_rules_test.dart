import 'dart:convert';
import 'dart:io';

import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/core/validation/gen/sync_validation_rules.g.dart';
import 'package:beekeepingit_client/core/validation/sync_validation_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the **shared validation description** artifact itself
/// (`contracts/validation/sync-ops.validation.json`, sync.md §9, D-12, #584):
/// that the committed client copy is not stale, that it parses, and that it
/// still covers every entity type the connector can queue an op for.
///
/// The staleness check is the whole point of embedding the JSON verbatim: the
/// shared file is the single definition, so if someone edits it without
/// re-running `scripts/gen-sync-validation.sh`, this test — not a field bug —
/// is what notices. Same convention as the repo's committed `lib/l10n/gen`.
void main() {
  /// Repo-relative: `flutter test` runs with the client package as CWD.
  final sharedDescription = File(
    '../contracts/validation/sync-ops.validation.json',
  );

  group('the embedded description', () {
    test('is byte-identical to contracts/validation/sync-ops.validation.json — '
        'run scripts/gen-sync-validation.sh if this fails', () {
      expect(sharedDescription.existsSync(), isTrue);
      expect(syncValidationRulesJson, sharedDescription.readAsStringSync());
    });

    test('parses without throwing', () {
      expect(
        () => SyncValidationRules.parse(syncValidationRulesJson),
        returnsNormally,
      );
    });

    test('covers every entity type the connector can upload — a syncable table '
        'added without rules would silently lose parity', () {
      final rules = SyncValidationRules.shared;
      expect(rules.entities.keys.toSet(), {
        apiaryEntityType,
        apiaryCounterEntityType,
        stockDeclarationEntityType,
        activityEntityType,
        journeyEntityType,
        journeyPlanItemEntityType,
        todoEntityType,
      });
    });

    test('records the rules deliberately left to the authoritative server, so '
        'an omission reads as a decision rather than as an oversight', () {
      final json = jsonDecode(syncValidationRulesJson) as Map<String, dynamic>;
      expect(json['serverOnly'], isA<List<dynamic>>());
      expect((json['serverOnly'] as List<dynamic>), isNotEmpty);
    });
  });

  group('parsing rejects a malformed description rather than degrading', () {
    test('an unknown check kind throws — a rule the evaluator cannot run must '
        'never be silently ignored', () {
      const source = '''
{
  "envelope": {
    "id": {"code": "invalid", "message": "id must be a UUID"},
    "updatedAt": {"code": "required", "message": "updated_at is required"}
  },
  "entities": {
    "apiary": {
      "ops": {"allowed": ["put"], "code": "invalid", "message": "bad op"},
      "fields": [
        {"name": "name", "checks": [{"kind": "minLength", "code": "x", "message": "y"}]}
      ]
    }
  }
}
''';
      expect(
        () => SyncValidationRules.parse(source),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-object document throws', () {
      expect(
        () => SyncValidationRules.parse('[]'),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'a check whose kind needs a limit but carries none throws AT PARSE '
      'time — the evaluator null-asserts it, so accepting this would mean '
      'green tests and a crash against a real op on a beekeeper\'s device',
      () {
        expect(
          () => SyncValidationRules.parse(
            _withNameChecks(
              '{"kind": "maxLength", '
              '"code": "too_long", "message": "too long"}',
            ),
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('a range check missing a bound throws at parse time too', () {
      expect(
        () => SyncValidationRules.parse(
          _withNameChecks(
            '{"kind": "range", '
            '"min": -180, "code": "out_of_range", "message": "out of range"}',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('a non-numeric limit is reported as a FormatException, matching the '
        'documented parse contract, not a raw TypeError', () {
      expect(
        () => SyncValidationRules.parse(
          _withNameChecks(
            '{"kind": "maxLength", '
            '"limit": "200", "code": "too_long", "message": "too long"}',
          ),
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('a well-formed limit-bearing check still parses', () {
      expect(
        () => SyncValidationRules.parse(
          _withNameChecks(
            '{"kind": "maxLength", '
            '"limit": 200, "code": "too_long", "message": "too long"}',
          ),
        ),
        returnsNormally,
      );
    });
  });
}

/// A minimal one-entity description whose only field carries [checks], for
/// exercising the parser's own guards without dragging in the real artifact.
String _withNameChecks(String checks) =>
    '''
{
  "envelope": {
    "id": {"code": "invalid", "message": "id must be a UUID"},
    "updatedAt": {"code": "required", "message": "updated_at is required"}
  },
  "entities": {
    "apiary": {
      "ops": {"allowed": ["put"], "code": "invalid", "message": "bad op"},
      "fields": [{"name": "name", "checks": [$checks]}]
    }
  }
}
''';
