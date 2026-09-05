import 'dart:convert';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/sync/powersync_connector.dart';
import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/core/sync/sync_events.dart';
import 'package:beekeepingit_client/core/validation/sync_op_validator.dart';
import 'package:flutter_test/flutter_test.dart';

/// The connector half of the pre-push **validation-parity** pass (FR-OF-2,
/// D-12, sync.md §9, #584): what happens to a push the client's own check
/// rejected — it must land in the same dead-letter + needs-fix flow a server
/// rejection lands in, and the CRUD transaction must still complete so the FIFO
/// upload queue can't wedge behind an op that will never succeed as-is.
///
/// Kept in its own file (rather than appended to `powersync_connector_test.dart`)
/// so the parity work and the in-flight `_toOp`/`lwwTimestampFor` changes don't
/// collide in the same test file.
const _uuid = '018f5f4e-2a3b-7c1d-9e2f-0a1b2c3d4e5f';
const _otherUuid = '018f5f4e-2a3b-7c1d-9e2f-0a1b2c3d4e60';
const _now = '2026-09-01T10:00:00.000Z';

void main() {
  group('localValidationProblem', () {
    test('carries a code distinct from the server\'s validation.failed, so a '
        'predicted rejection stays distinguishable from a real one', () {
      final problem = localValidationProblem(const [
        SyncOpFieldError(
          opIndex: 0,
          field: 'data.name',
          code: 'required',
          message: 'name is required',
        ),
      ]);

      expect(problem.code, localValidationFailedCode);
      expect(problem.code, isNot('validation.failed'));
      expect(problem.detail, isNotEmpty);
    });

    test('maps each parity failure onto the same RejectedFieldError shape the '
        'server\'s 422 body parses into', () {
      final problem = localValidationProblem(const [
        SyncOpFieldError(
          opIndex: 1,
          field: 'data.priority',
          code: 'required',
          message: 'priority is required',
        ),
      ]);

      expect(problem.fieldErrors, hasLength(1));
      expect(problem.fieldErrors.single.opIndex, 1);
      expect(problem.fieldErrors.single.field, 'data.priority');
      expect(problem.fieldErrors.single.code, 'required');
    });
  });

  group('handleLocalValidationFailure', () {
    late BeekeepingitConnector connector;
    late _FakeRejectedStore store;

    setUp(() {
      connector = BeekeepingitConnector(
        getAccessToken: () async => 'token',
        hasMembership: () => true,
      );
      store = _FakeRejectedStore();
    });

    tearDown(() => connector.dispose());

    List<Map<String, dynamic>> opsWithOneInvalidTodo() => [
      {
        'op': 'delete',
        'entity_type': apiaryEntityType,
        'id': _otherUuid,
        'data': null,
        'updated_at': _now,
      },
      {
        'op': 'put',
        'entity_type': todoEntityType,
        'id': _uuid,
        'data': <String, dynamic>{'title': '', 'priority': 'high'},
        'updated_at': _now,
      },
    ];

    test('retains EVERY op of the push and still completes the transaction — a '
        'push is atomic (so a valid op batched with an invalid one would '
        'otherwise be lost), and the FIFO queue must advance rather than wedge '
        'on an op that can never succeed as-is', () async {
      final ops = opsWithOneInvalidTodo();
      var completed = false;

      await connector.handleLocalValidationFailure(
        ops: ops,
        errors: validateSyncOps(ops),
        store: store,
        complete: () async => completed = true,
      );

      expect(store.rejected, hasLength(2));
      expect(completed, isTrue);
    });

    test('stamps the dead-letter rows with the local validation code, so the '
        'needs-fix screen can say the change was never sent', () async {
      final ops = opsWithOneInvalidTodo();

      await connector.handleLocalValidationFailure(
        ops: ops,
        errors: validateSyncOps(ops),
        store: store,
        complete: () async {},
      );

      expect(
        store.rejected.map((r) => r['error_code']),
        everyElement(localValidationFailedCode),
      );
    });

    test('attributes the field detail to the op it belongs to — the valid '
        'collateral op carries none', () async {
      final ops = opsWithOneInvalidTodo();

      await connector.handleLocalValidationFailure(
        ops: ops,
        errors: validateSyncOps(ops),
        store: store,
        complete: () async {},
      );

      final byEntity = {
        for (final r in store.rejected)
          r['entity_type'] as String:
              jsonDecode(r['error_detail'] as String) as Map<String, dynamic>,
      };
      expect(byEntity[apiaryEntityType]!['errors'], isEmpty);
      final todoErrors = byEntity[todoEntityType]!['errors'] as List<dynamic>;
      expect(
        todoErrors.map((e) => (e as Map<String, dynamic>)['field']),
        contains('data.title'),
      );
    });

    test('surfaces each retained op on rejectedChanges, so the shell shows the '
        'needs-fixing notice exactly as for a server rejection', () async {
      final ops = opsWithOneInvalidTodo();
      final seen = <RejectedChange>[];
      final sub = connector.rejectedChanges.listen(seen.add);

      await connector.handleLocalValidationFailure(
        ops: ops,
        errors: validateSyncOps(ops),
        store: store,
        complete: () async {},
      );
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(seen, hasLength(2));
      expect(
        seen.map((c) => c.errorCode),
        everyElement(localValidationFailedCode),
      );
    });

    test('stores the full wire op as the payload, so the needs-fix row can '
        'still name the record the user has to fix', () async {
      final ops = opsWithOneInvalidTodo();

      await connector.handleLocalValidationFailure(
        ops: ops,
        errors: validateSyncOps(ops),
        store: store,
        complete: () async {},
      );

      final todoRow = store.rejected.firstWhere(
        (r) => r['entity_type'] == todoEntityType,
      );
      final payload = jsonDecode(todoRow['payload'] as String);
      expect((payload as Map<String, dynamic>)['id'], _uuid);
    });
  });
}

/// The same minimal in-memory [LocalStoreEngine] `powersync_connector_test.dart`
/// uses: it interprets only the two SQL shapes the connector issues against
/// [rejectedOpsTable], so the dead-letter write is exercised with no PowerSync
/// database.
class _FakeRejectedStore implements LocalStoreEngine {
  final List<Map<String, Object?>> rejected = [];

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    final normalized = sql.trim().toUpperCase();
    if (normalized.startsWith('DELETE FROM SYNC_REJECTED_OPS')) {
      rejected.removeWhere((r) => r['dedup_key'] == args[0]);
    } else if (normalized.startsWith('INSERT INTO SYNC_REJECTED_OPS')) {
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
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => const [];

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) => throw UnimplementedError();

  @override
  Future<void> clear() async => rejected.clear();
}
