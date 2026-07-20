import 'dart:convert';

import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/features/history/history_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A local store that replays one fixed result set and records the query it
/// was asked — enough to assert both the mapping and the SQL's own shape
/// (which table filters it applies, and with which args) without a real
/// PowerSync database. Mirrors the `_NoopLocalStore` convention the detail
/// screen tests already use, plus the captured-args part.
class _FakeLocalStore implements LocalStoreEngine {
  _FakeLocalStore(this.rows);

  final List<Map<String, Object?>> rows;
  String? lastSql;
  List<Object?>? lastArgs;

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) {
    lastSql = sql;
    lastArgs = args;
    return Stream.value(rows);
  }

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async => rows.isEmpty ? null : rows.first;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => rows;

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}

  @override
  Future<void> clear() async {}
}

/// Builds a repository over [rows] and an [ApiClient] backed by a
/// [MockClient] — the same dependency-injection seam members_repository_test
/// uses, so no real network is involved.
({HistoryRepository repo, _FakeLocalStore store, List<Uri> requests})
_buildRepo({
  List<Map<String, Object?>> rows = const [],
  Future<http.Response> Function(http.Request)? handler,
}) {
  final requests = <Uri>[];
  final store = _FakeLocalStore(rows);
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWith(
        (ref) => ApiClient(
          ref,
          httpClient: MockClient((request) async {
            requests.add(request.url);
            return handler == null
                ? http.Response('{"data":[]}', 200)
                : handler(request);
          }),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (
    repo: HistoryRepository(store, container.read(apiClientProvider)),
    store: store,
    requests: requests,
  );
}

/// One local `audit_log` row as PowerSync delivers it: JSONB and TEXT[]
/// columns arrive as JSON-encoded *text*, not as native maps/lists.
Map<String, Object?> _auditRow({
  String id = 'h1',
  String changeType = 'update',
  String? actor = 'user-1',
  String recordedAt = '2026-07-18T10:00:00Z',
  Object? changedFields = '["name","notes"]',
  Object? change = '{"name":{"from":"A","to":"B"}}',
}) => {
  'id': id,
  'entity_type': apiaryEntityType,
  'entity_id': 'a1',
  'event_kind': changeType,
  'actor_user_id': actor,
  'occurred_at': '2026-07-18T09:59:00Z',
  'recorded_at': recordedAt,
  'changed_fields': changedFields,
  'change': change,
  'winning_payload': null,
  'losing_payload': null,
  'winner': null,
};

/// One local `sync_conflict_log` row, as the UNION's second leg selects it:
/// a synthetic `superseded` kind, null changed_fields/change, and the three
/// raw conflict columns.
Map<String, Object?> _conflictRow({
  String id = 'c1',
  String recordedAt = '2026-07-19T10:00:00Z',
  String winner = 'server',
}) => {
  'id': id,
  'entity_type': apiaryEntityType,
  'entity_id': 'a1',
  'event_kind': supersededEventKind,
  'actor_user_id': 'user-2',
  'occurred_at': null,
  'recorded_at': recordedAt,
  'changed_fields': null,
  'change': null,
  'winning_payload': '{"name":"Server wins"}',
  'losing_payload': '{"name":"Client loses"}',
  'winner': winner,
};

void main() {
  group('HistoryRepository local timeline (#60, FR-HIS-1, history.md §6)', () {
    test('maps an audit_log row, decoding its JSON-as-text columns', () async {
      final h = _buildRepo(rows: [_auditRow()]);

      final entries = await h.repo
          .watchLocalTimeline(entityType: apiaryEntityType, entityId: 'a1')
          .first;

      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.id, 'h1');
      expect(e.kind, HistoryEventKind.updated);
      expect(e.actorUserId, 'user-1');
      expect(e.changedFields, ['name', 'notes']);
      expect(e.change, {
        'name': {'from': 'A', 'to': 'B'},
      });
      expect(e.recordedAt.toUtc(), DateTime.utc(2026, 7, 18, 10));
      expect(e.occurredAt, isNotNull);
      // Only a superseded row has a winner.
      expect(e.conflictWinner, isNull);
    });

    test('maps a sync_conflict_log row to a superseded entry, rebuilding the '
        'payload shape the server assembles in SQL', () async {
      final h = _buildRepo(rows: [_conflictRow()]);

      final e =
          (await h.repo
                  .watchLocalTimeline(
                    entityType: apiaryEntityType,
                    entityId: 'a1',
                  )
                  .first)
              .single;

      expect(e.kind, HistoryEventKind.superseded);
      expect(e.conflictWinner, 'server');
      expect(e.change['winning_payload'], {'name': 'Server wins'});
      expect(e.change['losing_payload'], {'name': 'Client loses'});
      // occurred_at is nullable on this table (the losing edit may carry
      // no device time) — a null must not become epoch-zero.
      expect(e.occurredAt, isNull);
    });

    test('filters both UNION legs by the same entity type and id', () async {
      final h = _buildRepo(rows: [_auditRow()]);

      await h.repo
          .watchLocalTimeline(entityType: activityEntityType, entityId: 'act9')
          .first;

      expect(h.store.lastSql, contains(auditLogTable));
      expect(h.store.lastSql, contains(syncConflictLogTable));
      expect(h.store.lastSql, contains('UNION ALL'));
      // Newest first — the capped detail-screen preview depends on it.
      expect(h.store.lastSql, contains('ORDER BY recorded_at DESC'));
      // One (type, id) pair per leg, in order.
      expect(h.store.lastArgs, [
        activityEntityType,
        'act9',
        activityEntityType,
        'act9',
      ]);
    });

    test(
      'degrades a malformed JSON column without dropping the entry',
      () async {
        final h = _buildRepo(
          rows: [_auditRow(changedFields: 'not json', change: '{{{')],
        );

        final e =
            (await h.repo
                    .watchLocalTimeline(
                      entityType: apiaryEntityType,
                      entityId: 'a1',
                    )
                    .first)
                .single;

        // The row still tells the user THAT something changed, and when —
        // which is the point of an audit trail.
        expect(e.id, 'h1');
        expect(e.kind, HistoryEventKind.updated);
        expect(e.changedFields, isEmpty);
        expect(e.change, isEmpty);
      },
    );

    test(
      'an unrecognized event kind degrades to unknown, not an exception',
      () async {
        final h = _buildRepo(rows: [_auditRow(changeType: 'archived')]);

        final e =
            (await h.repo
                    .watchLocalTimeline(
                      entityType: apiaryEntityType,
                      entityId: 'a1',
                    )
                    .first)
                .single;

        expect(e.kind, HistoryEventKind.unknown);
      },
    );

    test(
      'a null actor stays null (history.md §3 allows an unset actor)',
      () async {
        final h = _buildRepo(rows: [_auditRow(actor: null)]);

        final e =
            (await h.repo
                    .watchLocalTimeline(
                      entityType: apiaryEntityType,
                      entityId: 'a1',
                    )
                    .first)
                .single;

        expect(e.actorUserId, isNull);
      },
    );
  });

  group('HistoryRepository remote fallback (history.md §6 deep history)', () {
    test('parses the REST timeline and re-sorts it newest first', () async {
      // The endpoint returns oldest-first; the client renders newest-first.
      final h = _buildRepo(
        handler: (_) async => http.Response(
          jsonEncode({
            'data': [
              {
                'id': 'old',
                'entity_type': apiaryEntityType,
                'entity_id': 'a1',
                'event_kind': 'create',
                'actor_user_id': 'user-1',
                'occurred_at': '2026-07-01T10:00:00Z',
                'recorded_at': '2026-07-01T10:00:00Z',
                'change': {'name': 'Serra'},
              },
              {
                'id': 'new',
                'entity_type': apiaryEntityType,
                'entity_id': 'a1',
                'event_kind': 'update',
                'actor_user_id': 'user-1',
                'occurred_at': '2026-07-05T10:00:00Z',
                'recorded_at': '2026-07-05T10:00:00Z',
                'changed_fields': ['name'],
                'change': {
                  'name': {'from': 'Serra', 'to': 'Serra Norte'},
                },
              },
            ],
          }),
          200,
        ),
      );

      final entries = await h.repo.fetchRemoteTimeline(
        entityType: apiaryEntityType,
        entityId: 'a1',
      );

      expect(entries.map((e) => e.id), ['new', 'old']);
      // REST delivers real lists/maps rather than JSON text — the same
      // mapper must handle both.
      expect(entries.first.changedFields, ['name']);
      expect(entries.last.kind, HistoryEventKind.created);
      expect(h.requests.single.path, endsWith('/v1/apiaries/a1/history'));
    });

    test(
      'a superseded row with no device time stays null, matching the local path',
      () async {
        // The invariant this class documents: both sources produce the
        // identical shape. sync_conflict_log.occurred_at is nullable, and the
        // server omits the key rather than emitting Go's zero time — so the
        // REST path must land on null here, exactly as the local path does
        // for a true SQL NULL (see the local superseded test above).
        final h = _buildRepo(
          handler: (_) async => http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'c1',
                  'entity_type': apiaryEntityType,
                  'entity_id': 'a1',
                  'event_kind': supersededEventKind,
                  'recorded_at': '2026-07-19T10:00:00Z',
                  // no occurred_at, no actor_user_id, no changed_fields
                  'change': {
                    'winning_payload': {'name': 'Server wins'},
                    'losing_payload': {'name': 'Client loses'},
                    'winner': 'server',
                  },
                },
              ],
            }),
            200,
          ),
        );

        final e = (await h.repo.fetchRemoteTimeline(
          entityType: apiaryEntityType,
          entityId: 'a1',
        )).single;

        expect(e.kind, HistoryEventKind.superseded);
        expect(e.occurredAt, isNull);
        expect(e.actorUserId, isNull);
        expect(e.changedFields, isEmpty);
        // The REST source already carries the assembled conflict payload, so
        // it is passed through rather than rebuilt.
        expect(e.conflictWinner, 'server');
        expect(e.change['winning_payload'], {'name': 'Server wins'});
      },
    );

    test('routes an activity to its own owning service path', () async {
      final h = _buildRepo();

      await h.repo.fetchRemoteTimeline(
        entityType: activityEntityType,
        entityId: 'act1',
      );

      expect(h.requests.single.path, endsWith('/v1/activities/act1/history'));
    });

    test('an entity type with no history endpoint makes no request', () async {
      final h = _buildRepo();

      final entries = await h.repo.fetchRemoteTimeline(
        entityType: 'journey',
        entityId: 'j1',
      );

      expect(entries, isEmpty);
      expect(h.requests, isEmpty);
    });

    test(
      'a failing request yields empty, not an error (best-effort)',
      () async {
        final h = _buildRepo(
          handler: (_) async => http.Response('{"title":"boom"}', 500),
        );

        final entries = await h.repo.fetchRemoteTimeline(
          entityType: apiaryEntityType,
          entityId: 'a1',
        );

        // An offline/failing fallback is an empty history, not a broken
        // screen — the same convention memberNamesProvider follows.
        expect(entries, isEmpty);
      },
    );
  });
}
