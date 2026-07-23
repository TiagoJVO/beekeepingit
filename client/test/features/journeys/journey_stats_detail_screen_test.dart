import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Widget tests for the #391 "More stats" per-apiary breakdown screen
/// (`/journeys/:id/stats`) — mirrors journey_detail_screen_test.dart's own
/// house style: a real `BeekeepingitApp`/`GoRouter`, hand-written fakes, full
/// `ProviderScope` overrides (every provider this screen reads is overridden
/// with a plain `Stream.value(...)`, no network/PowerSync anywhere in this
/// file), `Key('...')` naming.

class _NoopLocalStore implements LocalStoreEngine {
  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) => const Stream.empty();
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
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}
  @override
  Future<void> clear() async {}
}

class _FakeJourneysRepository extends JourneysRepository {
  _FakeJourneysRepository(this.existing) : super(_NoopLocalStore());
  final Journey? existing;

  @override
  Future<Journey?> getById(String id) async => existing;
}

class _CompleteProfileController extends ProfileController {
  @override
  Future<Profile> build() async => Profile(
    id: 'test-user',
    name: 'Test User',
    email: 'test@example.com',
    locale: 'en',
    profileComplete: true,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _ExistingOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => Organization(
    id: 'test-org',
    name: 'Test Apiary Co.',
    address: '',
    createdBy: 'test-user',
    role: 'admin',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

const _harvestJourney = Journey(
  id: 'j1',
  name: 'Colheita de Primavera',
  mainActivityType: 'harvest',
  status: journeyStatusOpen,
);

Activity _activity({
  required String id,
  required String apiaryId,
  required String type,
  Map<String, dynamic> attributes = const {},
}) => Activity(
  id: id,
  apiaryId: apiaryId,
  type: type,
  occurredAt: '2026-06-01',
  attributes: attributes,
  journeyId: 'j1',
);

const _apiaries = [
  Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4),
  Apiary(id: 'a2', name: 'Serra Norte', hiveCount: 2),
  Apiary(id: 'a3', name: 'Vale Fundo', hiveCount: 1),
];

Widget _buildApp({
  Journey? journey = _harvestJourney,
  List<Apiary> apiaries = _apiaries,
  List<String> plannedApiaryIds = const ['a1', 'a2'],
  List<Activity> activities = const [],
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      journeysStreamProvider.overrideWith(
        (ref) => Stream.value(journey == null ? const <Journey>[] : [journey]),
      ),
      journeyByIdProvider.overrideWith((ref, id) => Stream.value(journey)),
      activitiesByJourneyProvider.overrideWith(
        (ref, id) => Stream.value(activities),
      ),
      journeyPlanApiariesByJourneyProvider.overrideWith(
        (ref) => Stream.value({'j1': plannedApiaryIds}),
      ),
      journeysRepositoryProvider.overrideWith(
        (ref) async => _FakeJourneysRepository(journey),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openStats(
  WidgetTester tester, {
  Journey? journey = _harvestJourney,
  List<Apiary> apiaries = _apiaries,
  List<String> plannedApiaryIds = const ['a1', 'a2'],
  List<Activity> activities = const [],
}) async {
  await tester.pumpWidget(
    _buildApp(
      journey: journey,
      apiaries: apiaries,
      plannedApiaryIds: plannedApiaryIds,
      activities: activities,
    ),
  );
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(AppShell)));
  router.go('/journeys/j1/stats');
  await tester.pumpAndSettle();
}

void main() {
  group('JourneyStatsDetailScreen route (#391)', () {
    testWidgets('/journeys/:id/stats resolves to the breakdown screen', (
      tester,
    ) async {
      await _openStats(tester);

      expect(find.byKey(const Key('journey-stats-filter-bar')), findsOneWidget);
    });

    testWidgets(
      'a deleted/unknown journey bounces back to the journeys list rather '
      'than rendering a blank screen',
      (tester) async {
        await _openStats(tester, journey: null);

        expect(find.byKey(const Key('journey-stats-filter-bar')), findsNothing);
        expect(
          find.text('No journeys yet. Tap “New journey” to create one.'),
          findsOneWidget,
        );
      },
    );
  });

  group('JourneyStatsDetailScreen — filtering (#391)', () {
    testWidgets('shows every apiary in scope by default (all filter)', (
      tester,
    ) async {
      await _openStats(
        tester,
        plannedApiaryIds: const ['a1', 'a2'],
        activities: [
          _activity(
            id: 'act1',
            apiaryId: 'a1',
            type: 'harvest',
            attributes: const {
              'honey_kg': 10,
              'honey_supers': 4,
              'hives_involved': 2,
            },
          ),
        ],
      );

      expect(
        find.byKey(const Key('journey-stats-detail-apiary-a1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('journey-stats-detail-apiary-a2')),
        findsOneWidget,
      );
    });

    testWidgets('the visited filter hides not-yet-visited apiaries', (
      tester,
    ) async {
      await _openStats(
        tester,
        plannedApiaryIds: const ['a1', 'a2'],
        activities: [
          _activity(
            id: 'act1',
            apiaryId: 'a1',
            type: 'harvest',
            attributes: const {
              'honey_kg': 10,
              'honey_supers': 4,
              'hives_involved': 2,
            },
          ),
        ],
      );

      await tester.tap(find.byKey(const Key('journey-stats-filter-visited')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('journey-stats-detail-apiary-a1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('journey-stats-detail-apiary-a2')),
        findsNothing,
      );
    });

    testWidgets('the not-visited filter hides already-visited apiaries', (
      tester,
    ) async {
      await _openStats(
        tester,
        plannedApiaryIds: const ['a1', 'a2'],
        activities: [
          _activity(
            id: 'act1',
            apiaryId: 'a1',
            type: 'harvest',
            attributes: const {
              'honey_kg': 10,
              'honey_supers': 4,
              'hives_involved': 2,
            },
          ),
        ],
      );

      await tester.tap(
        find.byKey(const Key('journey-stats-filter-not-visited')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('journey-stats-detail-apiary-a1')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('journey-stats-detail-apiary-a2')),
        findsOneWidget,
      );
    });

    testWidgets('shows the empty state when a filter matches nothing', (
      tester,
    ) async {
      await _openStats(tester, plannedApiaryIds: const ['a1', 'a2']);

      await tester.tap(find.byKey(const Key('journey-stats-filter-visited')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('journey-stats-detail-empty')),
        findsOneWidget,
      );
    });
  });

  group('JourneyStatsDetailScreen — sorting (#391)', () {
    testWidgets('sorting by kg/hive (descending) reorders a harvest '
        'journey\'s apiary cards', (tester) async {
      await _openStats(
        tester,
        plannedApiaryIds: const ['a1', 'a2'],
        activities: [
          _activity(
            id: 'act-a1',
            apiaryId: 'a1',
            type: 'harvest',
            attributes: const {
              'honey_kg': 4,
              'honey_supers': 2,
              'hives_involved': 2,
            }, // 2 kg/hive
          ),
          _activity(
            id: 'act-a2',
            apiaryId: 'a2',
            type: 'harvest',
            attributes: const {
              'honey_kg': 20,
              'honey_supers': 8,
              'hives_involved': 2,
            }, // 10 kg/hive
          ),
        ],
      );

      // Default sort (name): a1 (Monte Alto) before a2 (Serra Norte).
      final beforeA1 = tester.getTopLeft(
        find.byKey(const Key('journey-stats-detail-apiary-a1')),
      );
      final beforeA2 = tester.getTopLeft(
        find.byKey(const Key('journey-stats-detail-apiary-a2')),
      );
      expect(beforeA1.dy, lessThan(beforeA2.dy));

      await tester.tap(find.byKey(const Key('journey-stats-sort-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Kg/hive').last);
      await tester.pumpAndSettle();

      // a2 has the higher kg/hive (10 vs 2) — descending sort puts it first.
      final afterA1 = tester.getTopLeft(
        find.byKey(const Key('journey-stats-detail-apiary-a1')),
      );
      final afterA2 = tester.getTopLeft(
        find.byKey(const Key('journey-stats-detail-apiary-a2')),
      );
      expect(afterA2.dy, lessThan(afterA1.dy));
    });
  });

  group('JourneyStatsDetailScreen — per-type metric visibility (#391)', () {
    testWidgets('a harvest journey shows kg/hive and supers/hive metric '
        'labels on its apiary cards', (tester) async {
      await _openStats(
        tester,
        journey: _harvestJourney,
        plannedApiaryIds: const ['a1'],
        activities: [
          _activity(
            id: 'act1',
            apiaryId: 'a1',
            type: 'harvest',
            attributes: const {
              'honey_kg': 10,
              'honey_supers': 4,
              'hives_involved': 2,
            },
          ),
        ],
      );

      expect(find.text('Kg/hive'), findsOneWidget);
      expect(find.text('Supers/hive'), findsOneWidget);
      expect(find.text('Feed amount'), findsNothing);
      expect(find.text('Hives involved'), findsNothing);
    });

    testWidgets('a feeding journey shows the feed-amount metric and header '
        'summary, not the harvest metrics', (tester) async {
      const journey = Journey(
        id: 'j1',
        name: 'Alimentação de Outono',
        mainActivityType: 'feeding',
        status: journeyStatusOpen,
      );
      await _openStats(
        tester,
        journey: journey,
        plannedApiaryIds: const ['a1'],
        activities: [
          _activity(
            id: 'act1',
            apiaryId: 'a1',
            type: 'feeding',
            attributes: const {'feed_type': 'Xarope 1:1', 'feed_amount': 3},
          ),
        ],
      );

      expect(find.text('Feed amount'), findsWidgets);
      expect(find.text('Kg/hive'), findsNothing);
      expect(
        find.byKey(const Key('journey-stats-detail-feeding-summary')),
        findsOneWidget,
      );
    });

    testWidgets('a treatment journey shows the hives-involved metric and '
        'the treated-apiaries header summary', (tester) async {
      const journey = Journey(
        id: 'j1',
        name: 'Tratamento de Varroa',
        mainActivityType: 'treatment',
        status: journeyStatusOpen,
      );
      await _openStats(
        tester,
        journey: journey,
        plannedApiaryIds: const ['a1', 'a2'],
        activities: [
          _activity(
            id: 'act1',
            apiaryId: 'a1',
            type: 'treatment',
            attributes: const {
              'treatment_context': 'preventive',
              'hives_involved': 4,
            },
          ),
        ],
      );

      expect(find.text('Hives involved'), findsWidgets);
      expect(find.text('Kg/hive'), findsNothing);
      expect(
        find.byKey(const Key('journey-stats-detail-treated-summary')),
        findsOneWidget,
      );
      expect(find.text('1/2 apiaries treated'), findsOneWidget);
    });
  });
}
