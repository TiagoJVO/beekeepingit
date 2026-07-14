import 'package:beekeepingit_client/core/sync/powersync_connector.dart';
import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for [parseSupersededChanges] — the pure parsing step behind
/// [BeekeepingitConnector.uploadData]'s notify-and-fix wiring (sync.md
/// §4.2/§8, #58). The server's shape is `services/apiaries/api/sync.go`'s
/// `ApplyResponse`: `{"results": [{"id","op","result"}]}`.
void main() {
  group('entityTypeForTable (#256)', () {
    test('apiaries rows map to the apiary entity type', () {
      expect(entityTypeForTable(apiariesTable), apiaryEntityType);
    });

    test('apiary_counters rows map to the apiary_counter entity type — the '
        'new op the server routes to applyCounterOp', () {
      expect(entityTypeForTable(apiaryCountersTable), apiaryCounterEntityType);
    });

    test('an unrecognized table defaults to the apiary entity type', () {
      expect(entityTypeForTable('something_else'), apiaryEntityType);
    });
  });

  group('parseSupersededChanges', () {
    test('returns one change per superseded op', () {
      final changes = parseSupersededChanges('''
        {"results": [
          {"id": "a1", "op": "patch", "result": "superseded"},
          {"id": "a2", "op": "put", "result": "applied"},
          {"id": "a3", "op": "delete", "result": "superseded"}
        ]}
      ''');

      expect(changes, hasLength(2));
      expect(changes[0].entityId, 'a1');
      expect(changes[0].entityType, 'apiary');
      expect(changes[1].entityId, 'a3');
    });

    test('returns an empty list when nothing was superseded', () {
      final changes = parseSupersededChanges('''
        {"results": [{"id": "a1", "op": "put", "result": "applied"}]}
      ''');

      expect(changes, isEmpty);
    });

    test('returns an empty list for an empty results array', () {
      expect(parseSupersededChanges('{"results": []}'), isEmpty);
    });

    test('returns an empty list for malformed JSON rather than throwing', () {
      expect(parseSupersededChanges('not json'), isEmpty);
    });

    test('returns an empty list when the results key is missing', () {
      expect(parseSupersededChanges('{}'), isEmpty);
    });
  });
}
