import 'dart:convert';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/sync/powersync_connector.dart';
import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/core/sync/sync_events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Unit tests for the connector's pure/injectable seams — the notify-and-fix
/// wiring (sync.md §4.2/§8, D-12) split out of [BeekeepingitConnector.uploadData]
/// so they're testable **without a real PowerSync database**:
///   - [parseSupersededChanges] — the `superseded` LWW-loss parse (#58);
///   - [classifyUploadOutcome] / [parseRejectedProblem] — the 4xx decision +
///     RFC 9457 problem parse (#256/#260);
///   - [BeekeepingitConnector.handleUploadResponse] — the retain/notify/complete
///     action, driven with a fake [LocalStoreEngine] + a `complete` closure.
/// The server shapes are `services/apiaries/api/sync.go`'s `ApplyResponse`
/// (`{"results": [...]}`) and `services/servicetemplate/problem`'s RFC 9457
/// `Problem` (`{code, detail, errors[]}`).
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

  group('decodeActivityAttributes (#39 — attributes must upload as an object, '
      'not a JSON string)', () {
    test('an activities put decodes the JSON-string attributes into a Map', () {
      // What PowerSync queues: the row column is JSON-encoded TEXT
      // (activities_repository.dart's jsonEncode), so opData carries a String.
      final data = <String, dynamic>{
        'apiary_id': 'apiary-1',
        'type': 'inspection',
        'occurred_at': '2026-07-14',
        'attributes': jsonEncode({'queen_seen': true, 'frames': 8}),
        'updated_at': '2026-07-14T10:00:00Z',
      };

      final out = decodeActivityAttributes(activitiesTable, data)!;

      // The regression: attributes must be an object on the wire, or the
      // server rejects it with "attributes must be a JSON object".
      expect(out['attributes'], isA<Map<String, dynamic>>());
      expect(out['attributes'], {'queen_seen': true, 'frames': 8});
      // Other columns pass through untouched.
      expect(out['apiary_id'], 'apiary-1');
      expect(out['type'], 'inspection');
    });

    test('a patch that changed attributes (opData carries only the changed '
        'columns) also decodes it', () {
      final data = <String, dynamic>{
        'attributes': jsonEncode({'note': 'requeened'}),
        'updated_at': '2026-07-14T11:00:00Z',
      };

      final out = decodeActivityAttributes(activitiesTable, data)!;

      expect(out['attributes'], isA<Map<String, dynamic>>());
      expect(out['attributes'], {'note': 'requeened'});
    });

    test('empty attributes decode to an empty Map (not the string "{}")', () {
      final data = <String, dynamic>{
        'attributes': jsonEncode(<String, dynamic>{}),
      };

      final out = decodeActivityAttributes(activitiesTable, data)!;

      expect(out['attributes'], isA<Map<String, dynamic>>());
      expect(out['attributes'], isEmpty);
    });

    test('a patch that did not touch attributes is left as-is (no key to '
        'decode)', () {
      final data = <String, dynamic>{
        'occurred_at': '2026-07-14',
        'updated_at': '2026-07-14T11:00:00Z',
      };

      expect(decodeActivityAttributes(activitiesTable, data), same(data));
    });

    test('a delete (null opData) is passed through untouched', () {
      expect(decodeActivityAttributes(activitiesTable, null), isNull);
    });

    test('a non-activities table is never rewritten, even if it happens to '
        'carry a string attributes column', () {
      final data = <String, dynamic>{'attributes': '{"x":1}'};

      // apiaries/counters ops must be handed to the server verbatim — only the
      // activities contract expects a nested object here.
      expect(decodeActivityAttributes(apiariesTable, data), same(data));
      expect(decodeActivityAttributes(apiaryCountersTable, data), same(data));
    });

    test(
      'an already-decoded Map attributes is left untouched (idempotent)',
      () {
        final data = <String, dynamic>{
          'attributes': {'queen_seen': true},
        };

        expect(decodeActivityAttributes(activitiesTable, data), same(data));
      },
    );
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

  group('classifyUploadOutcome (4xx classification, #256/#260)', () {
    test('200 → completed', () {
      expect(
        classifyUploadOutcome(200, '').disposition,
        UploadDisposition.completed,
      );
    });

    test('422 and 400 → retain (validation-class, can\'t heal on retry)', () {
      expect(
        classifyUploadOutcome(422, '{}').disposition,
        UploadDisposition.retain,
      );
      expect(
        classifyUploadOutcome(400, '{}').disposition,
        UploadDisposition.retain,
      );
    });

    test(
      'every other 4xx → retry (transient; a recoverable op is NOT dropped)',
      () {
        for (final status in [401, 403, 404, 408, 409, 429]) {
          expect(
            classifyUploadOutcome(status, '').disposition,
            UploadDisposition.retry,
            reason:
                '$status must stay queued for forward-retry, not be dropped',
          );
        }
      },
    );

    test('5xx → retry', () {
      expect(
        classifyUploadOutcome(500, '').disposition,
        UploadDisposition.retry,
      );
      expect(
        classifyUploadOutcome(503, '').disposition,
        UploadDisposition.retry,
      );
    });
  });

  group('parseRejectedProblem (RFC 9457, #256/#260)', () {
    test('parses code, detail, and maps ops[i].field errors to op index', () {
      final problem = parseRejectedProblem(
        jsonEncode({
          'title': 'Validation failed',
          'status': 422,
          'code': 'validation.failed',
          'detail': 'one or more ops are invalid',
          'errors': [
            {
              'field': 'ops[0].data.value',
              'code': 'out_of_range',
              'message': 'value must be >= 0',
            },
            {
              'field': 'ops[1].data.counter_type',
              'code': 'invalid',
              'message': 'counter_type must be one of the known counter types',
            },
          ],
        }),
      );

      expect(problem.code, 'validation.failed');
      expect(problem.detail, 'one or more ops are invalid');
      expect(problem.fieldErrors, hasLength(2));
      expect(problem.fieldErrors[0].opIndex, 0);
      expect(problem.fieldErrors[0].field, 'data.value');
      expect(problem.fieldErrors[0].message, 'value must be >= 0');
      expect(problem.fieldErrors[1].opIndex, 1);
      expect(problem.fieldErrors[1].field, 'data.counter_type');
    });

    test(
      'a non-op-scoped field keeps opIndex null (client can\'t attribute it)',
      () {
        final problem = parseRejectedProblem(
          jsonEncode({
            'code': 'validation.failed',
            'errors': [
              {'field': 'somethingElse', 'code': 'x', 'message': 'm'},
            ],
          }),
        );

        expect(problem.fieldErrors.single.opIndex, isNull);
        expect(problem.fieldErrors.single.field, 'somethingElse');
      },
    );

    test(
      'malformed body → empty-detail problem, no throw (op still retained)',
      () {
        final problem = parseRejectedProblem('not json');
        expect(problem.code, '');
        expect(problem.detail, '');
        expect(problem.fieldErrors, isEmpty);
      },
    );
  });

  group('handleUploadResponse — retained + surfaced, not dropped (D-12)', () {
    late BeekeepingitConnector connector;
    late _FakeRejectedStore store;

    setUp(() {
      connector = BeekeepingitConnector(getAccessToken: () async => null);
      store = _FakeRejectedStore();
    });

    tearDown(() => connector.dispose());

    // The enriched wire op `_toOp` produces for a rejected offline hive edit
    // (#256): a counter patch carrying its (apiary_id, counter_type) identity.
    Map<String, dynamic> counterOp({int value = -5}) => {
      'op': 'patch',
      'entity_type': apiaryCounterEntityType,
      'id': 'counter-row-1',
      'data': {
        'apiary_id': 'apiary-1',
        'counter_type': 'hive',
        'value': value,
        'updated_at': '2026-07-14T10:00:00Z',
      },
      'updated_at': '2026-07-14T10:00:00Z',
    };

    String validationBody() => jsonEncode({
      'title': 'Validation failed',
      'status': 422,
      'code': 'validation.failed',
      'detail': 'one or more ops are invalid',
      'errors': [
        {
          'field': 'ops[0].data.value',
          'code': 'out_of_range',
          'message': 'value must be >= 0',
        },
      ],
    });

    test('422: the op is retained in the dead-letter, surfaced, and the tx is '
        'completed (queue advances, edit not lost)', () async {
      final surfaced = <RejectedChange>[];
      final sub = connector.rejectedChanges.listen(surfaced.add);
      addTearDown(sub.cancel);
      var completed = false;

      await connector.handleUploadResponse(
        status: 422,
        body: validationBody(),
        ops: [counterOp()],
        store: store,
        complete: () async => completed = true,
      );
      await pumpEventQueue();

      // Completed → the poison op leaves the queue, so it can't wedge.
      expect(completed, isTrue);
      // Retained → NOT silently dropped (the whole point).
      expect(store.rejected, hasLength(1));
      final row = store.rejected.single;
      expect(row['entity_type'], apiaryCounterEntityType);
      expect(row['dedup_key'], 'apiary-1:hive'); // server identity, not row id
      expect(row['fix_apiary_id'], 'apiary-1'); // deep-link target
      expect(row['error_code'], 'validation.failed');
      expect(row['error_detail'], contains('value must be >= 0'));
      // Surfaced → the shell can notify + route to the needs-fix list.
      expect(surfaced, hasLength(1));
      expect(surfaced.single.entityId, 'apiary-1');
      expect(surfaced.single.errorCode, 'validation.failed');
    });

    test(
      'a re-rejection REPLACEs by server identity — one live entry per record',
      () async {
        await connector.handleUploadResponse(
          status: 422,
          body: validationBody(),
          ops: [counterOp(value: -5)],
          store: store,
          complete: () async {},
        );
        await connector.handleUploadResponse(
          status: 422,
          body: validationBody(),
          ops: [counterOp(value: -9)],
          store: store,
          complete: () async {},
        );

        expect(
          store.rejected.where((r) => r['dedup_key'] == 'apiary-1:hive'),
          hasLength(1),
          reason:
              'delete-then-insert keeps a single live dead-letter per record',
        );
      },
    );

    test(
      '401: the push is left queued (throws) — not completed, not dropped',
      () async {
        var completed = false;

        await expectLater(
          connector.handleUploadResponse(
            status: 401,
            body: '',
            ops: [counterOp()],
            store: store,
            complete: () async => completed = true,
          ),
          throwsA(isA<http.ClientException>()),
        );

        expect(completed, isFalse, reason: 'stays queued for forward-retry');
        expect(
          store.rejected,
          isEmpty,
          reason: 'a recoverable 401 is not dead-lettered',
        );
      },
    );

    test(
      '200: clear-on-success removes a prior dead-letter row for the record',
      () async {
        // A stale rejection from an earlier push of the same counter.
        store.rejected.add({
          'id': 'r1',
          'entity_type': apiaryCounterEntityType,
          'dedup_key': 'apiary-1:hive',
          'fix_apiary_id': 'apiary-1',
          'op': 'patch',
          'payload': '{}',
          'error_code': 'validation.failed',
          'error_detail': '{}',
          'rejected_at': '2026-07-14T09:00:00Z',
        });
        var completed = false;

        await connector.handleUploadResponse(
          status: 200,
          body: jsonEncode({
            'results': [
              {'id': 'counter-row-1', 'op': 'patch', 'result': 'applied'},
            ],
          }),
          ops: [counterOp(value: 12)], // the corrected value, now valid
          store: store,
          complete: () async => completed = true,
        );

        expect(completed, isTrue);
        expect(
          store.rejected,
          isEmpty,
          reason: 'the corrected re-save auto-resolved its earlier rejection',
        );
      },
    );
  });

  group('dispose (HIGH #1 — resource leak)', () {
    test('closes the injected http.Client', () {
      final client = _TrackingHttpClient();
      final connector = BeekeepingitConnector(
        getAccessToken: () async => null,
        client: client,
      );

      connector.dispose();

      expect(client.closed, isTrue);
    });
  });

  group('lwwTimestampFor (MEDIUM #1 — retried DELETE must not get an '
      'ever-later timestamp)', () {
    test('a put/patch payload\'s own updated_at is passed through untouched, '
        'and nothing is cached for it', () {
      final cache = <String, String>{};

      final result = lwwTimestampFor('row-1', {
        'updated_at': '2026-07-14T10:00:00Z',
      }, cache);

      expect(result, '2026-07-14T10:00:00Z');
      expect(cache, isEmpty);
    });

    test('a delete (no payload) gets a device timestamp, captured once and '
        'reused on every subsequent retry of the same queued op — not '
        'recomputed fresh each time', () async {
      final cache = <String, String>{};

      final firstAttempt = lwwTimestampFor('row-1', null, cache);
      // A real retry is separated in time (the SDK's forward-retry
      // backoff); without the fix each call recomputes DateTime.now(),
      // so this delay would otherwise make the values differ.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final retryAttempt = lwwTimestampFor('row-1', null, cache);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final secondRetryAttempt = lwwTimestampFor('row-1', null, cache);

      expect(
        retryAttempt,
        firstAttempt,
        reason:
            'a retry must reuse the original delete time, not a fresh '
            'now() that could spuriously win a later LWW conflict',
      );
      expect(secondRetryAttempt, firstAttempt);
    });

    test('two different deleted rows get independent timestamps', () {
      final cache = <String, String>{};

      lwwTimestampFor('row-1', null, cache);
      lwwTimestampFor('row-2', null, cache);

      expect(cache.keys, containsAll(<String>['row-1', 'row-2']));
      expect(cache, hasLength(2));
    });
  });
}

/// A minimal [http.Client] that records whether [close] was called, so
/// [BeekeepingitConnector.dispose] can be asserted to actually release its
/// injected client rather than merely existing as a no-op method.
class _TrackingHttpClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnsupportedError('not used by this test');

  @override
  void close() => closed = true;
}

/// A minimal in-memory [LocalStoreEngine] that interprets only the two SQL
/// shapes the connector issues against [rejectedOpsTable] (INSERT and
/// DELETE-by-dedup_key) — the dead-letter analogue of
/// `apiaries_repository_test.dart`'s `FakeLocalStore`, so `handleUploadResponse`
/// is exercised with no PowerSync database.
class _FakeRejectedStore implements LocalStoreEngine {
  final List<Map<String, Object?>> rejected = [];

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    final normalized = sql.trim().toUpperCase();
    if (normalized.startsWith('DELETE FROM SYNC_REJECTED_OPS')) {
      rejected.removeWhere((r) => r['dedup_key'] == args[0]);
    } else if (normalized.startsWith('INSERT INTO SYNC_REJECTED_OPS')) {
      // (id, entity_type, dedup_key, fix_apiary_id, op, payload, error_code,
      //  error_detail, rejected_at)
      rejected.add({
        'id': args[0],
        'entity_type': args[1],
        'dedup_key': args[2],
        'fix_apiary_id': args[3],
        'op': args[4],
        'payload': args[5],
        'error_code': args[6],
        'error_detail': args[7],
        'rejected_at': args[8],
      });
    } else {
      throw UnsupportedError('_FakeRejectedStore.execute: unhandled SQL: $sql');
    }
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async => null;

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) => throw UnimplementedError();

  @override
  Future<void> clear() async => rejected.clear();
}
