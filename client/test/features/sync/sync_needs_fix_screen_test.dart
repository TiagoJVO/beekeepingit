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
}

/// Wraps [SyncNeedsFixScreen] in a router carrying the two routes its actions
/// navigate to (`apiaryEdit`, `/account`), with the repository backed by the
/// in-memory [store].
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
}) => {
  'id': id,
  'entity_type': entityType,
  'fix_apiary_id': fixApiaryId,
  'op': 'patch',
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
