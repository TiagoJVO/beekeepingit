import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journey_filters.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A no-op [LocalStoreEngine] — [_FakeJourneysRepository] overrides every
/// method the edit-route push touches, mirroring
/// journey_form_screen_test.dart's identical fixture.
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

/// Resolves getById() immediately (with whatever the test needs) so
/// navigating into the edit route never hangs on the real
/// journeysRepositoryProvider chain (powerSyncProvider never resolves in
/// these tests) — mirrors journey_form_screen_test.dart's
/// `_FakeJourneysRepository`.
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

Widget _buildApp({
  required List<Journey> journeys,
  Journey? existingForEdit,
  List<Activity> activities = const [],
  Map<String, List<String>> planApiariesByJourney = const {},
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      // The Apiaries tab is the app's initial route and stays mounted (via
      // StatefulShellRoute's IndexedStack) even after switching to Journeys
      // — overridden so it doesn't hang on the real, never-resolving
      // apiariesRepositoryProvider chain (mirrors app_shell_test.dart's own
      // rationale for this exact override).
      apiariesStreamProvider.overrideWith(
        (ref) => Stream.value(const <Apiary>[]),
      ),
      journeysStreamProvider.overrideWith((ref) => Stream.value(journeys)),
      journeysRepositoryProvider.overrideWith(
        (ref) async => _FakeJourneysRepository(existingForEdit),
      ),
      // The date-range filter and the progress badge (#47) both read these —
      // overridden directly (rather than relying on the real, never-
      // resolving activitiesRepositoryProvider/powerSyncProvider chain) so
      // tests can control exactly what each journey's "activities" are.
      activitiesStreamProvider.overrideWith((ref) => Stream.value(activities)),
      journeyPlanApiariesByJourneyProvider.overrideWith(
        (ref) => Stream.value(planApiariesByJourney),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openJourneysTab(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('shell-tab-journeys')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'shows the empty state when the organization has no journeys yet (#45)',
    (tester) async {
      await tester.pumpWidget(_buildApp(journeys: const []));
      await _openJourneysTab(tester);

      expect(
        find.text('No journeys yet. Tap “New journey” to create one.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('lists every journey with its name and status, unfiltered (#45 — '
      'minimal list, filtering is #47)', (tester) async {
    await tester.pumpWidget(
      _buildApp(
        journeys: const [
          Journey(
            id: 'j1',
            name: 'Colheita de Primavera',
            mainActivityType: 'harvest',
            status: journeyStatusOpen,
          ),
          Journey(
            id: 'j2',
            name: 'Old Journey',
            mainActivityType: 'feeding',
            status: journeyStatusClosed,
          ),
        ],
      ),
    );
    await _openJourneysTab(tester);

    expect(find.byKey(const Key('journey-j1')), findsOneWidget);
    expect(find.byKey(const Key('journey-j2')), findsOneWidget);
    expect(find.text('Colheita de Primavera'), findsOneWidget);
    expect(find.text('Old Journey'), findsOneWidget);
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Closed'), findsOneWidget);
  });

  testWidgets('tapping a row navigates to its edit form (#45)', (tester) async {
    const journey = Journey(
      id: 'j1',
      name: 'Colheita de Primavera',
      mainActivityType: 'harvest',
      status: journeyStatusOpen,
    );
    await tester.pumpWidget(
      _buildApp(journeys: const [journey], existingForEdit: journey),
    );
    await _openJourneysTab(tester);

    await tester.tap(find.byKey(const Key('journey-j1')));
    await tester.pumpAndSettle();

    final nameField = tester.widget<TextFormField>(
      find.byKey(const Key('journey-name-field')),
    );
    expect(nameField.controller!.text, 'Colheita de Primavera');
  });

  group('filters (#47, FR-JO-2)', () {
    const harvestJourney = Journey(
      id: 'j-harvest',
      name: 'Colheita de Primavera',
      mainActivityType: 'harvest',
      status: journeyStatusOpen,
    );
    const feedingJourney = Journey(
      id: 'j-feeding',
      name: 'Alimentação de Inverno',
      mainActivityType: 'feeding',
      status: journeyStatusOpen,
    );

    Activity activityFor(
      String journeyId, {
      required String date,
      String apiaryId = 'a1',
    }) => Activity(
      id: 'act-$journeyId-$date',
      apiaryId: apiaryId,
      type: 'generic',
      occurredAt: date,
      attributes: const {},
      journeyId: journeyId,
    );

    testWidgets('selecting a type shows only matching journeys', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(journeys: const [harvestJourney, feedingJourney]),
      );
      await _openJourneysTab(tester);

      await tester.tap(find.byKey(const Key('journey-filter-type-field')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Feeding').last);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('journey-j-harvest')), findsNothing);
      expect(find.byKey(const Key('journey-j-feeding')), findsOneWidget);
    });

    testWidgets(
      'setting a date range keeps only journeys with a recorded activity '
      'within it',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            journeys: const [harvestJourney, feedingJourney],
            activities: [
              activityFor('j-harvest', date: '2026-06-05'),
              activityFor('j-feeding', date: '2020-01-01'),
            ],
          ),
        );
        await _openJourneysTab(tester);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(BeekeepingitApp)),
        );
        container
            .read(journeyDateRangeFilterProvider.notifier)
            .state = JourneyDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('journey-j-harvest')), findsOneWidget);
        expect(find.byKey(const Key('journey-j-feeding')), findsNothing);
      },
    );

    testWidgets(
      'type and date-range filters combine (#47 AC) and the no-results '
      'state shows when nothing matches',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            journeys: const [harvestJourney, feedingJourney],
            activities: [
              activityFor('j-harvest', date: '2026-06-05'),
              activityFor('j-feeding', date: '2026-06-05'),
            ],
          ),
        );
        await _openJourneysTab(tester);

        final container = ProviderScope.containerOf(
          tester.element(find.byType(BeekeepingitApp)),
        );
        container.read(journeyTypeFilterProvider.notifier).state = 'harvest';
        container
            .read(journeyDateRangeFilterProvider.notifier)
            .state = JourneyDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('journey-j-harvest')), findsOneWidget);
        expect(find.byKey(const Key('journey-j-feeding')), findsNothing);

        // Narrow further so nothing matches at all — the no-results state,
        // not the "org has zero journeys" empty state.
        container.read(journeyTypeFilterProvider.notifier).state = 'treatment';
        await tester.pumpAndSettle();

        expect(find.text('No journeys match your filters.'), findsOneWidget);
        expect(
          find.text('No journeys yet. Tap “New journey” to create one.'),
          findsNothing,
        );
      },
    );

    testWidgets('the clear-filters button resets both filters', (tester) async {
      await tester.pumpWidget(
        _buildApp(journeys: const [harvestJourney, feedingJourney]),
      );
      await _openJourneysTab(tester);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(BeekeepingitApp)),
      );
      container.read(journeyTypeFilterProvider.notifier).state = 'harvest';
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('journey-j-feeding')), findsNothing);

      await tester.tap(find.byKey(const Key('journey-filter-clear-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('journey-j-harvest')), findsOneWidget);
      expect(find.byKey(const Key('journey-j-feeding')), findsOneWidget);
    });
  });

  group('progress badge (#47, FR-JO-2 — "feitos/planeados")', () {
    const journey = Journey(
      id: 'j1',
      name: 'Colheita de Primavera',
      mainActivityType: 'harvest',
      status: journeyStatusOpen,
    );

    testWidgets(
      'shows the done/planned count when the journey has planned apiaries',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            journeys: const [journey],
            activities: const [
              Activity(
                id: 'act1',
                apiaryId: 'a1',
                type: 'generic',
                occurredAt: '2026-06-01',
                attributes: {},
                journeyId: 'j1',
              ),
            ],
            planApiariesByJourney: const {
              'j1': ['a1', 'a2'],
            },
          ),
        );
        await _openJourneysTab(tester);

        expect(find.byKey(const Key('journey-progress-badge')), findsOneWidget);
        expect(find.text('1/2 apiaries visited'), findsOneWidget);
      },
    );

    testWidgets('is hidden when the journey has no planned apiaries yet', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp(journeys: const [journey]));
      await _openJourneysTab(tester);

      expect(find.byKey(const Key('journey-progress-badge')), findsNothing);
    });
  });
}
