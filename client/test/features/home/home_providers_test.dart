import 'dart:async';

import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/sync/powersync_service.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/home/home_providers.dart';
import 'package:beekeepingit_client/features/home/home_summary.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Todo _overdueTodo(String id) => Todo(
  id: id,
  title: 'Todo $id',
  priority: 'medium',
  status: 'open',
  // Far enough in the past to be overdue whatever day the suite runs on.
  dueDate: '2020-01-01',
);

Journey _openJourney(String id) => Journey(
  id: id,
  name: 'Journey $id',
  mainActivityType: 'inspection',
  status: journeyStatusOpen,
);

Apiary _apiary(String id) => Apiary(id: id, name: 'Apiary $id', hiveCount: 0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A container wired only to the four org-scoped stream providers Home
  /// composes. A `null` stream argument means "left at its real
  /// implementation" — never used here except by the un-scoped-query test,
  /// which needs the un-overridden dependency chain to blow up if it is
  /// touched.
  ProviderContainer buildContainer({
    Stream<List<Todo>>? todos,
    Stream<List<Journey>>? journeys,
    Stream<List<Apiary>>? apiaries,
    Stream<List<Activity>>? activities,
  }) {
    final container = ProviderContainer(
      overrides: [
        todosStreamProvider.overrideWith(
          (ref) => todos ?? Stream.value(const <Todo>[]),
        ),
        journeysStreamProvider.overrideWith(
          (ref) => journeys ?? Stream.value(const <Journey>[]),
        ),
        apiariesStreamProvider.overrideWith(
          (ref) => apiaries ?? Stream.value(const <Apiary>[]),
        ),
        activitiesStreamProvider.overrideWith(
          (ref) => activities ?? Stream.value(const <Activity>[]),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('yields a usable summary while a dependency is still loading', () async {
    // Journeys never emits — it stays AsyncLoading forever. Home must still
    // paint (offline-first): the journeys section degrades to empty, the
    // other three sections are fully computed.
    final container = buildContainer(
      todos: Stream.value([_overdueTodo('t1')]),
      journeys: const Stream<List<Journey>>.empty(),
    );

    container.listen(homeSummaryProvider, (_, _) {});
    await pumpEventQueue();

    expect(
      container.read(journeysStreamProvider),
      isA<AsyncLoading<List<Journey>>>(),
    );
    final summary = container.read(homeSummaryProvider);
    expect(summary.attentionTodos.count, 1);
    expect(summary.openJourneys.count, 0);
    expect(summary.state, HomeSummaryState.needsAttention);
  });

  test('recomputes when the todos stream emits again', () async {
    final todos = StreamController<List<Todo>>();
    addTearDown(todos.close);
    final container = buildContainer(todos: todos.stream);

    container.listen(homeSummaryProvider, (_, _) {});

    todos.add(const []);
    await pumpEventQueue();
    expect(container.read(homeSummaryProvider).attentionTodos.count, 0);

    todos.add([_overdueTodo('t1'), _overdueTodo('t2')]);
    await pumpEventQueue();
    final after = container.read(homeSummaryProvider);
    expect(after.attentionTodos.count, 2);
    expect(after.state, HomeSummaryState.needsAttention);
  });

  test('a dependency in error degrades that section to empty', () async {
    final container = buildContainer(
      todos: Stream.error(StateError('no powersync session yet')),
      journeys: Stream.value([_openJourney('j1')]),
    );

    container.listen(homeSummaryProvider, (_, _) {});
    await pumpEventQueue();

    expect(container.read(todosStreamProvider), isA<AsyncError<List<Todo>>>());
    final summary = container.read(homeSummaryProvider);
    expect(summary.attentionTodos.count, 0);
    expect(summary.openJourneys.count, 1);
    expect(summary.state, HomeSummaryState.needsAttention);
  });

  // Named for what it actually pins. "Every section is computed against the
  // same now" is structurally guaranteed by [buildHomeSummary] taking a
  // single `now` parameter, and the property that a second clock read would
  // violate is pinned where it can actually be violated: the midnight-
  // straddle fixture in home_summary_test.dart, and the pinned-clock widget
  // guard in home_screen_test.dart.
  //
  // What IS worth pinning here is that this provider stamps the summary with
  // a clock it reads at build time — not a fixed epoch, not a value carried
  // over from a previous build.
  test(
    'stamps the summary with a clock read taken while building it',
    () async {
      final container = buildContainer(
        todos: Stream.value([_overdueTodo('t1')]),
      );

      container.listen(homeSummaryProvider, (_, _) {});
      await pumpEventQueue();

      final before = DateTime.now();
      final summary = container.read(homeSummaryProvider);
      // Read when the summary was built — so at or before this assertion's own
      // read, never after it.
      expect(summary.now.isAfter(before), isFalse);
      expect(
        summary.now.isAfter(
          DateTime.now().subtract(const Duration(minutes: 1)),
        ),
        isTrue,
        reason: 'a real clock read, not a placeholder instant',
      );
    },
  );

  test(
    'issues no query of its own: never reaches PowerSync or an org',
    () async {
      // Structural, not behavioural: any bespoke query would have to go
      // through a repository, and every repository provider resolves
      // [powerSyncProvider] first. Overriding it to throw means the summary can
      // only be produced by composing the four already-org-scoped stream
      // providers above — a re-implemented, potentially un-scoped query would
      // surface this error instead of a summary.
      final container = ProviderContainer(
        overrides: [
          powerSyncProvider.overrideWith(
            (ref) =>
                throw StateError('homeSummaryProvider must issue no query'),
          ),
          todosStreamProvider.overrideWith(
            (ref) => Stream.value([_overdueTodo('t1')]),
          ),
          journeysStreamProvider.overrideWith(
            (ref) => Stream.value([_openJourney('j1')]),
          ),
          apiariesStreamProvider.overrideWith(
            (ref) => Stream.value([_apiary('a1')]),
          ),
          activitiesStreamProvider.overrideWith(
            (ref) => Stream.value(const <Activity>[]),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.listen(homeSummaryProvider, (_, _) {});
      await pumpEventQueue();

      final summary = container.read(homeSummaryProvider);
      expect(summary.attentionTodos.count, 1);
      expect(summary.openJourneys.count, 1);
      expect(summary.staleApiaries.count, 1);
    },
  );

  group('shared-device tenancy regression (#658, FR-TEN-2)', () {
    // The scenario, end to end, with the REAL apiariesStreamProvider and the
    // REAL ApiariesRepository over a seeded local store — the one composition
    // an `apiariesStreamProvider.overrideWith(...)` harness can never cover.
    //
    // A shared tablet: user A closes the browser without logging out, so
    // neither of LocalStoreEngine.clear()'s two call sites runs (logout,
    // auth_controller.dart; membership loss, local_data_purge.dart) — there is
    // no login-time purge, and org A's replicated rows survive on disk. User B
    // logs in from a DIFFERENT org and lands on Home (#658 made it the landing
    // screen), and offline PowerSync never reconciles the buckets. Home must
    // render nothing from org A.
    test('Home shows no apiaries when the local store still holds the previous '
        'user\'s org rows and the active org is another one', () async {
      final store = _SeededLocalStore([
        _apiaryRow(id: 'a-1', name: 'Serra Norte', organizationId: 'org-a'),
        _apiaryRow(id: 'a-2', name: 'Vale Sul', organizationId: 'org-a'),
      ]);

      final container = ProviderContainer(
        overrides: [
          apiariesRepositoryProvider.overrideWith(
            (ref) async => ApiariesRepository(store),
          ),
          organizationProvider.overrideWith(_OrgBController.new),
          todosStreamProvider.overrideWith(
            (ref) => Stream.value(const <Todo>[]),
          ),
          journeysStreamProvider.overrideWith(
            (ref) => Stream.value(const <Journey>[]),
          ),
          activitiesStreamProvider.overrideWith(
            (ref) => Stream.value(const <Activity>[]),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.listen(homeSummaryProvider, (_, _) {});
      await pumpEventQueue();

      final summary = container.read(homeSummaryProvider);
      expect(
        summary.staleApiaries.count,
        0,
        reason:
            'org B must never see org A\'s apiaries — they would otherwise '
            'class as never-visited and render by NAME on the landing screen',
      );
      expect(summary.staleApiaries.preview, isEmpty);
    });

    test('the same store DOES surface its rows to their own org — the guard '
        'scopes, it does not blank the section out', () async {
      final store = _SeededLocalStore([
        _apiaryRow(id: 'b-1', name: 'Encosta Norte', organizationId: 'org-b'),
      ]);

      final container = ProviderContainer(
        overrides: [
          apiariesRepositoryProvider.overrideWith(
            (ref) async => ApiariesRepository(store),
          ),
          organizationProvider.overrideWith(_OrgBController.new),
          todosStreamProvider.overrideWith(
            (ref) => Stream.value(const <Todo>[]),
          ),
          journeysStreamProvider.overrideWith(
            (ref) => Stream.value(const <Journey>[]),
          ),
          activitiesStreamProvider.overrideWith(
            (ref) => Stream.value(const <Activity>[]),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.listen(homeSummaryProvider, (_, _) {});
      await pumpEventQueue();

      expect(container.read(homeSummaryProvider).staleApiaries.count, 1);
    });
  });

  group('readiness floor under firstRun (#658 review, D-35)', () {
    // COLD START. The four PowerSync streams have not emitted yet — the
    // window between the wasm DB opening and its first query returning,
    // which exists on EVERY launch. Home must not use that window to assert
    // the org owns nothing and offer "Add your first apiary".
    test(
      'does NOT claim first-run while a dependency has never emitted',
      () async {
        final container = buildContainer(
          todos: const Stream<List<Todo>>.empty(),
          journeys: const Stream<List<Journey>>.empty(),
          apiaries: const Stream<List<Apiary>>.empty(),
          activities: const Stream<List<Activity>>.empty(),
        );

        container.listen(homeSummaryProvider, (_, _) {});
        await pumpEventQueue();

        final summary = container.read(homeSummaryProvider);
        expect(
          summary.state,
          isNot(HomeSummaryState.firstRun),
          reason: 'an unresolved stream is not an empty org',
        );
        expect(summary.state, HomeSummaryState.notReady);
        expect(summary.readiness, HomeDataReadiness.waiting);
      },
    );

    test(
      'one unresolved dependency is enough to hold the floor down',
      () async {
        // Three streams resolved to genuinely empty; only activities is still
        // in flight. That is not yet grounds to say the org owns nothing.
        final container = buildContainer(
          activities: const Stream<List<Activity>>.empty(),
        );

        container.listen(homeSummaryProvider, (_, _) {});
        await pumpEventQueue();

        expect(
          container.read(homeSummaryProvider).state,
          HomeSummaryState.notReady,
        );
      },
    );

    test('once every dependency HAS resolved empty, first-run is reached '
        'again — the floor gates the claim, it does not remove it', () async {
      final container = buildContainer();

      container.listen(homeSummaryProvider, (_, _) {});
      await pumpEventQueue();

      final summary = container.read(homeSummaryProvider);
      expect(summary.readiness, HomeDataReadiness.ready);
      expect(summary.state, HomeSummaryState.firstRun);
    });

    // DEAD LOCAL STORE (denied storage, private-mode browser, worker load
    // failure): all four streams error before ever emitting. Today Home
    // settles on first-run permanently, with no error text anywhere.
    test('does NOT claim first-run when every dependency errored without ever '
        'producing a value', () async {
      final container = buildContainer(
        todos: Stream.error(StateError('local store failed to open')),
        journeys: Stream.error(StateError('local store failed to open')),
        apiaries: Stream.error(StateError('local store failed to open')),
        activities: Stream.error(StateError('local store failed to open')),
      );

      container.listen(homeSummaryProvider, (_, _) {});
      await pumpEventQueue();

      final summary = container.read(homeSummaryProvider);
      expect(
        summary.state,
        isNot(HomeSummaryState.firstRun),
        reason: 'a dead local store is not an empty org',
      );
      expect(summary.state, HomeSummaryState.unavailable);
      expect(summary.readiness, HomeDataReadiness.unavailable);
    });

    test('an error AFTER good data keeps the sections but still reports the '
        'store as unavailable', () async {
      // `AsyncError` retains its last `.value`, so the tasks section goes on
      // rendering rows that will now never update. Readiness is what stops
      // that frozen state from passing for a live one.
      final todos = StreamController<List<Todo>>();
      addTearDown(todos.close);
      final container = buildContainer(todos: todos.stream);

      container.listen(homeSummaryProvider, (_, _) {});

      todos.add([_overdueTodo('t1')]);
      await pumpEventQueue();
      expect(
        container.read(homeSummaryProvider).readiness,
        HomeDataReadiness.ready,
      );

      todos.addError(StateError('local store went away'));
      await pumpEventQueue();

      final after = container.read(homeSummaryProvider);
      expect(after.attentionTodos.count, 1, reason: 'stale rows still render');
      expect(after.state, HomeSummaryState.needsAttention);
      expect(after.readiness, HomeDataReadiness.unavailable);
    });

    // A partially-warm start still paints: the section that HAS data is the
    // whole point of reading `.value ?? const []` per section.
    test(
      'still paints the sections that did resolve while others have not',
      () async {
        final container = buildContainer(
          todos: Stream.value([_overdueTodo('t1')]),
          journeys: const Stream<List<Journey>>.empty(),
        );

        container.listen(homeSummaryProvider, (_, _) {});
        await pumpEventQueue();

        final summary = container.read(homeSummaryProvider);
        expect(summary.state, HomeSummaryState.needsAttention);
        expect(summary.attentionTodos.count, 1);
      },
    );
  });
}

Map<String, Object?> _apiaryRow({
  required String id,
  required String name,
  required String? organizationId,
}) => {
  'id': id,
  'organization_id': organizationId,
  'name': name,
  'notes': null,
  'place_label': null,
  'registration_number': null,
  'location_lon': null,
  'location_lat': null,
  'created_at': '2026-06-01T00:00:00Z',
  'updated_at': '2026-06-01T00:00:00Z',
};

/// The active organization for this group's caller: org B, a DIFFERENT org
/// from the one whose rows [_SeededLocalStore] still holds.
class _OrgBController extends OrganizationController {
  @override
  Future<Organization?> build() async => Organization(
    id: 'org-b',
    name: 'Org B',
    address: '',
    createdBy: 'user-b',
    role: 'admin',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

/// A read-only [LocalStoreEngine] holding rows that are already on disk —
/// the leftover replicated state of a previous session. It applies the
/// `organization_id` predicate **only when the issued SQL actually carries
/// one**, so a repository that queries unscoped gets every row back, exactly
/// as the real SQLite store would. That is what makes the test above a real
/// regression test rather than a fake that enforces the property itself.
class _SeededLocalStore implements LocalStoreEngine {
  _SeededLocalStore(this._rows);

  final List<Map<String, Object?>> _rows;

  List<Map<String, Object?>> _select(String sql, List<Object?> args) {
    var results = [
      for (final r in _rows) {...r, 'hive_count': 0},
    ];
    if (sql.toUpperCase().contains(
      'A.ORGANIZATION_ID = ? OR A.ORGANIZATION_ID IS NULL',
    )) {
      final orgId = args.last;
      results = results
          .where(
            (r) =>
                r['organization_id'] == orgId || r['organization_id'] == null,
          )
          .toList();
    }
    return results;
  }

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) => Stream.value(_select(sql, args));

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final results = _select(sql, args);
    return results.isEmpty ? null : results.first;
  }

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => _select(sql, args);

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async =>
      throw UnsupportedError('_SeededLocalStore is read-only');

  @override
  Future<void> clear() async => _rows.clear();
}
