import 'dart:async';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/sync/sync_needs_fix_screen.dart';
import 'package:beekeepingit_client/features/sync/sync_rejected_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Widget tests for the needs-fix list (EPIC-06 #7, D-12 notify-and-fix): the
/// rejected offline writes retained in the local dead-letter, rendered so the
/// user can fix (deep-link to edit) or dismiss them. Driven through the real
/// [SyncRejectedRepository] over an in-memory [LocalStoreEngine] fake, so the
/// watch/delete round-trip (a Dismiss actually removing the row live) is
/// exercised, not just the initial render.
void main() {
  testWidgets('empty state when there is nothing to fix', (tester) async {
    await tester.pumpWidget(_harness(_FakeRejectedStore([])));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('needs-fix-empty')), findsOneWidget);
  });

  testWidgets(
    'renders one card per rejected op, with its field-error message',
    (tester) async {
      final store = _FakeRejectedStore([
        _row(id: 'r1'), // an apiary_counter rejection (default)
        _row(id: 'r2', entityType: 'apiary'),
      ]);
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('needs-fix-r1')), findsOneWidget);
      expect(find.byKey(const Key('needs-fix-r2')), findsOneWidget);
      // The server's field-level message is surfaced (not a generic fallback).
      expect(find.text('value must be >= 0'), findsWidgets);
    },
  );

  testWidgets('Dismiss deletes the row and it disappears live', (tester) async {
    final store = _FakeRejectedStore([_row(id: 'r1')]);
    await tester.pumpWidget(_harness(store));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('needs-fix-r1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('needs-fix-dismiss-r1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('needs-fix-r1')), findsNothing);
    expect(find.byKey(const Key('needs-fix-empty')), findsOneWidget);
  });

  testWidgets(
    'tapping Dismiss twice while the first dismiss is still in flight only '
    'issues one delete (#380)',
    (tester) async {
      final store = _FakeRejectedStore([
        _row(id: 'r1'),
      ], executeDelay: const Duration(milliseconds: 50));
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('needs-fix-dismiss-r1')));
      await tester.pump();
      // Second tap lands while the first DELETE is still in flight.
      await tester.tap(
        find.byKey(const Key('needs-fix-dismiss-r1')),
        warnIfMissed: false,
      );
      await tester.pump();

      await tester.pumpAndSettle();
      expect(store.executeCalls, 1);
      expect(find.byKey(const Key('needs-fix-r1')), findsNothing);
    },
  );

  testWidgets('Fix deep-links to the offending apiary\'s edit screen', (
    tester,
  ) async {
    final store = _FakeRejectedStore([
      _row(id: 'r1', fixApiaryId: 'apiary-42'),
    ]);
    await tester.pumpWidget(_harness(store));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('needs-fix-fix-r1')));
    await tester.pumpAndSettle();

    // Landed on the apiaryEdit route for the owning apiary.
    expect(find.text('edit apiary-42'), findsOneWidget);
  });

  group('entity labels (#379: everything but apiary_counter used to fall '
      'through to "Apiary change")', () {
    // One row per test (rather than all six in a single list) — a single
    // ListView with all six rows overflows the default test viewport, and
    // ListView.builder only builds what's actually laid out, so an
    // off-screen row's text isn't in the tree to find at all (not merely
    // hidden) without scrolling first.
    for (final MapEntry(key: entityType, value: expectedLabel) in const {
      'apiary': 'Apiary change',
      'apiary_counter': 'Hive count change',
      'activity': 'Activity change',
      'journey': 'Journey change',
      'journey_plan_item': 'Journey plan change',
      'todo': 'Todo change',
    }.entries) {
      testWidgets('shows "$expectedLabel" for entityType "$entityType"', (
        tester,
      ) async {
        final store = _FakeRejectedStore([
          _row(id: 'r1', entityType: entityType),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(find.text(expectedLabel), findsOneWidget);
      });
    }

    testWidgets('an unrecognized entity type falls back to the apiary label '
        '(preserves the previous safety-net behavior)', (tester) async {
      final store = _FakeRejectedStore([
        _row(id: 'r1', entityType: 'something_new'),
      ]);
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      expect(find.text('Apiary change'), findsOneWidget);
    });
  });

  group('payload-derived display name (#379 fix plan item 4)', () {
    testWidgets(
      'shows the record\'s own name alongside the entity label when the '
      'payload carries one',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'journey',
            payload: '{"data":{"name":"Spring Round"}}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(find.text('Journey change · Spring Round'), findsOneWidget);
      },
    );

    testWidgets(
      'falls back to the plain entity label when the payload carries no '
      'name/title/type field',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(id: 'r1', entityType: 'journey', payload: '{"data":{}}'),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(find.text('Journey change'), findsOneWidget);
      },
    );
  });

  group('per-entity Fix routing (#379 fix plan item 5)', () {
    testWidgets('a journey rejection\'s Fix opens the journey edit screen', (
      tester,
    ) async {
      final store = _FakeRejectedStore([
        _row(id: 'r1', entityType: 'journey', fixApiaryId: 'journey-1'),
      ]);
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('needs-fix-fix-r1')));
      await tester.pumpAndSettle();

      expect(find.text('edit journey journey-1'), findsOneWidget);
    });

    testWidgets('a todo rejection\'s Fix opens the todo edit screen', (
      tester,
    ) async {
      final store = _FakeRejectedStore([
        _row(id: 'r1', entityType: 'todo', fixApiaryId: 'todo-1'),
      ]);
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('needs-fix-fix-r1')));
      await tester.pumpAndSettle();

      expect(find.text('edit todo todo-1'), findsOneWidget);
    });

    testWidgets(
      'an activity rejection\'s Fix routes to the Activities tab root '
      '(no two-id activityEdit deep-link)',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(id: 'r1', entityType: 'activity', fixApiaryId: 'activity-1'),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('needs-fix-fix-r1')));
        await tester.pumpAndSettle();

        expect(find.text('activities list'), findsOneWidget);
      },
    );

    testWidgets(
      'a journey_plan_item rejection\'s Fix opens the owning journey\'s '
      'detail screen, using journey_id from the payload',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'journey_plan_item',
            fixApiaryId: 'plan-item-1',
            payload: '{"data":{"journey_id":"journey-9"}}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('needs-fix-fix-r1')));
        await tester.pumpAndSettle();

        expect(find.text('journey detail journey-9'), findsOneWidget);
      },
    );

    testWidgets(
      'a journey_plan_item rejection with no journey_id in its payload '
      'falls back to the Journeys tab root rather than a dead end',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'journey_plan_item',
            fixApiaryId: 'plan-item-1',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('needs-fix-fix-r1')));
        await tester.pumpAndSettle();

        expect(find.text('journeys list'), findsOneWidget);
      },
    );
  });
}

/// Wraps [SyncNeedsFixScreen] in a router carrying every route its "Fix"
/// action can navigate to per entity type (#379's fix plan item 5 — see
/// `sync_needs_fix_screen.dart`'s `_navigateToFix`), plus `/account`, with
/// the repository backed by the in-memory [store].
Widget _harness(_FakeRejectedStore store) {
  final router = GoRouter(
    initialLocation: '/sync-needs-fix',
    routes: [
      GoRoute(
        path: '/sync-needs-fix',
        name: 'syncNeedsFix',
        builder: (context, state) => const SyncNeedsFixScreen(),
      ),
      GoRoute(
        path: '/apiaries/:id/edit',
        name: 'apiaryEdit',
        builder: (context, state) =>
            Scaffold(body: Text('edit ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/journeys',
        name: 'journeys',
        builder: (context, state) =>
            const Scaffold(body: Text('journeys list')),
      ),
      GoRoute(
        path: '/journeys/:id',
        name: 'journeyDetail',
        builder: (context, state) => Scaffold(
          body: Text('journey detail ${state.pathParameters['id']}'),
        ),
      ),
      GoRoute(
        path: '/journeys/:id/edit',
        name: 'journeyEdit',
        builder: (context, state) =>
            Scaffold(body: Text('edit journey ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/todos/:id/edit',
        name: 'todoEdit',
        builder: (context, state) =>
            Scaffold(body: Text('edit todo ${state.pathParameters['id']}')),
      ),
      GoRoute(
        path: '/activities',
        name: 'activities',
        builder: (context, state) =>
            const Scaffold(body: Text('activities list')),
      ),
      GoRoute(
        path: '/account',
        name: 'account',
        builder: (context, state) => const Scaffold(body: Text('account')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      syncRejectedRepositoryProvider.overrideWith(
        (ref) => SyncRejectedRepository(store),
      ),
    ],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

Map<String, Object?> _row({
  required String id,
  String entityType = 'apiary_counter',
  String fixApiaryId = 'apiary-1',
  String? payload,
}) => {
  'id': id,
  'entity_type': entityType,
  'fix_apiary_id': fixApiaryId,
  'op': 'patch',
  'payload': payload ?? '{}',
  'error_code': 'validation.failed',
  'error_detail':
      '{"detail":"one or more ops are invalid","errors":[{"field":"data.value","code":"out_of_range","message":"value must be >= 0"}]}',
  'rejected_at': '2026-07-14T10:00:00Z',
};

/// In-memory [LocalStoreEngine] interpreting only the two `sync_rejected_ops`
/// shapes [SyncRejectedRepository] issues: the watch SELECT (list + count) and
/// the DELETE-by-id. Re-emits watches on every delete so the list updates live.
class _FakeRejectedStore implements LocalStoreEngine {
  _FakeRejectedStore(this.rows, {this.executeDelay});

  final List<Map<String, Object?>> rows;
  final _changes = StreamController<void>.broadcast();

  /// Artificial delay before [execute] applies its mutation — lets a test
  /// simulate a slow dismiss and tap twice before the first call resolves
  /// (#380's double-dismiss regression guard).
  final Duration? executeDelay;
  int executeCalls = 0;

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) async* {
    List<Map<String, Object?>> select() =>
        sql.toUpperCase().contains('COUNT(*)')
        ? [
            {'c': rows.length},
          ]
        : List<Map<String, Object?>>.from(rows);
    yield select();
    yield* _changes.stream.map((_) => select());
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {
    executeCalls++;
    if (sql.trim().toUpperCase().startsWith('DELETE FROM SYNC_REJECTED_OPS')) {
      if (executeDelay != null) await Future<void>.delayed(executeDelay!);
      rows.removeWhere((r) => r['id'] == args[0]);
      _changes.add(null);
    } else {
      throw UnsupportedError('_FakeRejectedStore.execute: $sql');
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
  ]) async => List<Map<String, Object?>>.from(rows);

  @override
  Future<void> clear() async {
    rows.clear();
    _changes.add(null);
  }
}
