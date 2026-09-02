import 'dart:async';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/validation/sync_op_validator.dart';
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
    'renders one card per rejected op, with a localized non-technical message '
    "(never the server's raw validation text) (#426)",
    (tester) async {
      final store = _FakeRejectedStore([
        _row(id: 'r1'), // an apiary_counter rejection (default)
        _row(id: 'r2', entityType: 'apiary'),
      ]);
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('needs-fix-r1')), findsOneWidget);
      expect(find.byKey(const Key('needs-fix-r2')), findsOneWidget);
      // The server's raw field-level message is NOT surfaced — a localized,
      // non-technical message is shown instead (#426), now mapped from the
      // rejection's (field, code) pair rather than blanket-generic (#443).
      expect(find.text('value must be >= 0'), findsNothing);
      expect(find.text('Count: this must be 0 or more.'), findsNWidgets(2));
    },
  );

  group('rejection-code → localized field guidance (#443)', () {
    testWidgets(
      'maps a known (field, code) pair to specific localized guidance instead '
      'of the blanket generic message',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'apiary',
            errorDetail:
                '{"detail":"one or more ops are invalid","errors":[{"field":"data.hive_count","code":"out_of_range","message":"hive_count must be >= 0"}]}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(
          find.text('Number of hives: this must be 0 or more.'),
          findsOneWidget,
        );
        expect(find.textContaining('hive_count'), findsNothing);
        expect(
          find.text('This change was rejected and needs your attention.'),
          findsNothing,
        );
      },
    );

    testWidgets('renders one line per mapped field problem', (tester) async {
      final store = _FakeRejectedStore([
        _row(
          id: 'r1',
          entityType: 'todo',
          errorDetail:
              '{"detail":"one or more ops are invalid","errors":['
              '{"field":"data.title","code":"required","message":"title is required"},'
              '{"field":"data.due_date","code":"invalid","message":"due_date must be a YYYY-MM-DD date"}'
              ']}',
        ),
      ]);
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      expect(find.text('Title: this is required.'), findsOneWidget);
      expect(find.text("Due date: this value isn't valid."), findsOneWidget);
      expect(find.textContaining('due_date'), findsNothing);
    });

    testWidgets(
      'a rejected stock declaration names the DGAV field at fault instead of '
      'the generic line (#600)',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'stock_declaration',
            errorDetail:
                '{"detail":"one or more ops are invalid","errors":['
                '{"field":"data.declared_on","code":"required","message":"declared_on is required"},'
                '{"field":"data.total_hive_count","code":"out_of_range","message":"total_hive_count must be >= 0"}'
                ']}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(
          find.text('Declaration date: this is required.'),
          findsOneWidget,
        );
        expect(
          find.text('Total number of hives: this must be 0 or more.'),
          findsOneWidget,
        );
        expect(find.textContaining('declared_on'), findsNothing);
        expect(find.textContaining('total_hive_count'), findsNothing);
        expect(
          find.text('This change was rejected and needs your attention.'),
          findsNothing,
        );
      },
    );

    testWidgets(
      "an apiary's DGAV registration number gets the same label the apiary "
      'form uses (#600)',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'apiary',
            errorDetail:
                '{"detail":"one or more ops are invalid","errors":[{"field":"data.dgav_registration_number","code":"too_long","message":"dgav_registration_number must be at most 50 characters"}]}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(
          find.text('DGAV registration number: this text is too long.'),
          findsOneWidget,
        );
        expect(find.textContaining('dgav_registration_number'), findsNothing);
      },
    );

    testWidgets(
      'falls back to the generic message when the server reports a field the '
      'app has no copy for (a new validator can never leak by default)',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'apiary',
            errorDetail:
                '{"detail":"one or more ops are invalid","errors":[{"field":"data.internal_column","code":"invalid","message":"internal_column must be a widget"}]}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(find.textContaining('internal_column'), findsNothing);
        expect(
          find.text('This change was rejected and needs your attention.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('a malformed error_detail still renders the row with the generic '
        'message rather than throwing or losing the edit', (tester) async {
      final store = _FakeRejectedStore([
        _row(id: 'r1', entityType: 'apiary', errorDetail: 'not json at all'),
        // Well-formed JSON, but an errors[] entry missing its `code`: the
        // entry is skipped rather than defaulted, so it can't masquerade
        // as a real issue — and it can't take the whole row down with it.
        _row(
          id: 'r2',
          entityType: 'apiary',
          errorDetail:
              '{"detail":"x","errors":[{"field":"data.name","message":"name is required"}]}',
        ),
      ]);
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('needs-fix-r1')), findsOneWidget);
      expect(find.byKey(const Key('needs-fix-r2')), findsOneWidget);
      expect(
        find.text('This change was rejected and needs your attention.'),
        findsNWidgets(2),
      );
      expect(find.textContaining('name is required'), findsNothing);
    });

    testWidgets(
      'falls back to the generic message when the op carries no field detail '
      '(a collateral op of an atomic push, rolled back for a sibling)',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'apiary',
            errorDetail: '{"detail":"one or more ops are invalid","errors":[]}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(
          find.text('This change was rejected and needs your attention.'),
          findsOneWidget,
        );
      },
    );
  });

  testWidgets(
    'does not leak a raw snake_case DB column name from the server detail — '
    'shows localized copy instead (#426, now specific per #443)',
    (tester) async {
      // Reproduces the field-tested leak, with the code the journeys
      // validator actually emits for it (validateDefaultAttributes,
      // services/journeys/api/types.go): a rejected journey whose server
      // detail named the `default_attributes` DB column verbatim.
      final store = _FakeRejectedStore([
        _row(
          id: 'r1',
          entityType: 'journey',
          errorDetail:
              '{"detail":"validation failed","errors":[{"field":"data.default_attributes","code":"invalid","message":"default_attributes must be a JSON object"}]}',
        ),
      ]);
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('needs-fix-r1')), findsOneWidget);
      // The internal column name must never reach the UI.
      expect(find.textContaining('default_attributes'), findsNothing);
      expect(
        find.text("Defaults for activities: this value isn't valid."),
        findsOneWidget,
      );
    },
  );

  group('client-predicted rejections (#584, FR-OF-2/D-12)', () {
    testWidgets(
      'get the SAME per-field guidance a server rejection gets — the connector '
      'synthesizes the identical (field, code) pairs, so #443\'s mapping '
      'applies with no special case',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'todo',
            errorCode: localValidationFailedCode,
            errorDetail:
                '{"detail":"client-side validation parity check rejected this push",'
                '"errors":[{"field":"data.title","code":"required","message":"title is required"}]}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(find.text('Title: this is required.'), findsOneWidget);
        // Still no raw validation text (#426 holds for both origins).
        expect(find.textContaining('title is required'), findsNothing);
      },
    );

    testWidgets(
      'fall back to "wasn\'t sent yet", NOT "was rejected", when nothing maps — '
      'the server never saw the change, so refusing wording would be wrong',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            errorCode: localValidationFailedCode,
            errorDetail:
                '{"detail":"client-side validation parity check rejected this push","errors":[]}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('needs-fix-r1')), findsOneWidget);
        expect(
          find.text("This change wasn't sent yet — please correct it."),
          findsOneWidget,
        );
        expect(
          find.text('This change was rejected and needs your attention.'),
          findsNothing,
        );
      },
    );

    testWidgets(
      'a SERVER rejection with nothing mapped keeps the original wording — the '
      '#584 fallback must not swallow the case it sits beside',
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            errorDetail: '{"detail":"one or more ops are invalid","errors":[]}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(
          find.text('This change was rejected and needs your attention.'),
          findsOneWidget,
        );
        expect(
          find.text("This change wasn't sent yet — please correct it."),
          findsNothing,
        );
      },
    );
  });

  testWidgets(
    'a code the app has no copy for still degrades to the localized generic '
    'message, so a new server validator cannot leak (#426/#443)',
    (tester) async {
      final store = _FakeRejectedStore([
        _row(
          id: 'r1',
          entityType: 'journey',
          errorDetail:
              '{"detail":"validation failed","errors":[{"field":"data.default_attributes","code":"invalid_type","message":"default_attributes must be a JSON object"}]}',
        ),
      ]);
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      expect(find.textContaining('default_attributes'), findsNothing);
      expect(
        find.text('This change was rejected and needs your attention.'),
        findsOneWidget,
      );
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
      'stock_declaration': 'Stock declaration change',
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

    testWidgets("localizes an activity's wire type rather than printing it raw "
        '(#443 — the row used to read "Activity change · harvest")', (
      tester,
    ) async {
      final store = _FakeRejectedStore([
        _row(
          id: 'r1',
          entityType: 'activity',
          payload: '{"data":{"type":"harvest"}}',
        ),
      ]);
      await tester.pumpWidget(_harness(store));
      await tester.pumpAndSettle();

      expect(find.text('Activity change · Honey harvest'), findsOneWidget);
      // The raw wire enum must not be what's rendered. ("Honey harvest"
      // legitimately contains "harvest", so assert on the exact raw title
      // the old behavior produced rather than on a substring.)
      expect(find.text('Activity change · harvest'), findsNothing);
    });

    testWidgets(
      'falls back to the plain entity label for an activity type this client '
      "version doesn't know, rather than showing the raw identifier",
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'activity',
            payload: '{"data":{"type":"some_new_type"}}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(find.text('Activity change'), findsOneWidget);
        expect(find.textContaining('some_new_type'), findsNothing);
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

    testWidgets(
      'a stock declaration keeps the plain entity label — none of its payload '
      'fields is an already-human name, so none may reach the title (#600, '
      "the DGAV counterpart of #443's raw-activity-type leak)",
      (tester) async {
        final store = _FakeRejectedStore([
          _row(
            id: 'r1',
            entityType: 'stock_declaration',
            payload:
                '{"data":{"declared_on":"2026-09-14","total_hive_count":12,'
                '"dgav_registration_number":"PT-12345","notes":"annual"}}',
            // The helper's default detail is an apiary_counter's field, which
            // validateDeclarationOp could never emit — use a real declaration
            // rejection so the whole fixture is one the server could produce.
            errorDetail:
                '{"detail":"one or more ops are invalid","errors":[{"field":"data.declared_on","code":"invalid","message":"declared_on must be a date in YYYY-MM-DD form"}]}',
          ),
        ]);
        await tester.pumpWidget(_harness(store));
        await tester.pumpAndSettle();

        expect(find.text('Stock declaration change'), findsOneWidget);
        // Neither the ISO wire date (unlocalized in EN *and* PT) nor the
        // registration number may be appended to the row title.
        expect(find.textContaining('2026-09-14'), findsNothing);
        expect(find.textContaining('PT-12345'), findsNothing);
        expect(find.textContaining('·'), findsNothing);
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
  String? errorDetail,
  String errorCode = 'validation.failed',
}) => {
  'id': id,
  'entity_type': entityType,
  'fix_apiary_id': fixApiaryId,
  'op': 'patch',
  'payload': payload ?? '{}',
  'error_code': errorCode,
  'error_detail':
      errorDetail ??
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
