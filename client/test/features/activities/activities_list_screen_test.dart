import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/activities/activity_filters.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixtures mirroring apiary_detail_screen_test.dart's own (file-private
/// there, so re-declared here).
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

const _apiaries = [
  Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
  Apiary(id: 'a2', name: 'Vale Sul', hiveCount: 5),
];

Activity _activity(
  String id, {
  String type = 'generic',
  required String date,
  String apiaryId = 'a1',
  String? performedBy,
  String? organizationId,
}) => Activity(
  id: id,
  apiaryId: apiaryId,
  type: type,
  occurredAt: date,
  attributes: const {},
  performedBy: performedBy,
  organizationId: organizationId,
);

Widget _buildApp({required List<Activity> activities}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(_apiaries)),
      // Tasks is the app's landing screen now (#427, D-29) — stub its stream
      // so booting the app renders the Todos tab without hanging on the real,
      // never-resolving todos repository chain.
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      activitiesStreamProvider.overrideWith((ref) => Stream.value(activities)),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openActivitiesTab(
  WidgetTester tester, {
  required List<Activity> activities,
}) async {
  await tester.pumpWidget(_buildApp(activities: activities));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('shell-tab-activities')));
  await tester.pumpAndSettle();
}

/// A no-op [LocalStoreEngine] — the org-scoping test below overrides every
/// method the fake repository touches, mirroring add_activity_screen_test.
/// dart's identical fixture.
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

/// Simulates the local table possibly holding rows from more than one
/// organization (which the real Sync Rule should never allow, #39) and
/// exercises the REAL [ActivitiesRepository.watchAll] org-scoping logic —
/// complementing activities_repository_test.dart's own direct repository
/// tests by additionally proving the PROVIDER wiring
/// ([activitiesStreamProvider] -> [organizationProvider] -> `watchAll`) and
/// the screen end-to-end only ever render the caller's own org's rows.
class _MultiOrgActivitiesRepository extends ActivitiesRepository {
  _MultiOrgActivitiesRepository(this._allRows) : super(_NoopLocalStore());

  final List<Activity> _allRows;

  @override
  Stream<List<Activity>> watchAll({required String? organizationId}) {
    if (organizationId == null) return Stream.value(const []);
    return Stream.value(
      _allRows
          .where(
            (a) =>
                a.organizationId == organizationId || a.organizationId == null,
          )
          .toList(),
    );
  }
}

void main() {
  group('main Activities tab (#43, FR-AC-6)', () {
    testWidgets('lists activities across every apiary in the org', (
      tester,
    ) async {
      await _openActivitiesTab(
        tester,
        activities: [
          _activity('1', type: 'harvest', date: '2026-06-01', apiaryId: 'a1'),
          _activity('2', type: 'feeding', date: '2026-06-02', apiaryId: 'a2'),
        ],
      );

      expect(find.byKey(const Key('activity-1')), findsOneWidget);
      expect(find.byKey(const Key('activity-2')), findsOneWidget);
      // Each row shows which apiary it belongs to (#43 AC), unlike #42's
      // embedded per-apiary section.
      expect(find.textContaining('Serra Norte'), findsOneWidget);
      expect(find.textContaining('Vale Sul'), findsOneWidget);
    });

    testWidgets('shows the empty state when the org has no activities at all', (
      tester,
    ) async {
      await _openActivitiesTab(tester, activities: const []);

      expect(find.text('No activities yet.'), findsOneWidget);
    });

    group('type filter', () {
      testWidgets('selecting a type shows only matching activities', (
        tester,
      ) async {
        await _openActivitiesTab(
          tester,
          activities: [
            _activity('1', type: 'harvest', date: '2026-06-01'),
            _activity('2', type: 'feeding', date: '2026-06-02'),
          ],
        );

        await tester.tap(find.byKey(const Key('activity-filter-type-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Feeding').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('activity-1')), findsNothing);
        expect(find.byKey(const Key('activity-2')), findsOneWidget);
      });
    });

    group('date-range filter', () {
      testWidgets('setting a date range keeps only activities within it', (
        tester,
      ) async {
        await _openActivitiesTab(
          tester,
          activities: [
            _activity('inside', date: '2026-06-05'),
            _activity('outside', date: '2020-01-01'),
          ],
        );

        final container = ProviderScope.containerOf(
          tester.element(find.byType(BeekeepingitApp)),
        );
        container
            .read(activityDateRangeFilterProvider(allActivitiesScope).notifier)
            .state = ActivityDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('activity-inside')), findsOneWidget);
        expect(find.byKey(const Key('activity-outside')), findsNothing);
      });
    });

    testWidgets(
      'type and date-range filters combine (#43 AC: filters can be combined) '
      'and the no-results state shows when nothing matches',
      (tester) async {
        await _openActivitiesTab(
          tester,
          activities: [
            _activity('match', type: 'harvest', date: '2026-06-05'),
            _activity('wrong-date', type: 'harvest', date: '2020-01-01'),
            _activity('wrong-type', type: 'feeding', date: '2026-06-05'),
          ],
        );

        final container = ProviderScope.containerOf(
          tester.element(find.byType(BeekeepingitApp)),
        );
        container
                .read(activityTypeFilterProvider(allActivitiesScope).notifier)
                .state =
            'harvest';
        container
            .read(activityDateRangeFilterProvider(allActivitiesScope).notifier)
            .state = ActivityDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('activity-match')), findsOneWidget);
        expect(find.byKey(const Key('activity-wrong-date')), findsNothing);
        expect(find.byKey(const Key('activity-wrong-type')), findsNothing);

        // Narrow further so nothing matches at all — the no-results state,
        // not the "org has zero activities" empty state. 'treatment' has no
        // matching fixture at any date, unlike 'feeding' (whose fixture
        // falls inside the still-active date range above).
        container
                .read(activityTypeFilterProvider(allActivitiesScope).notifier)
                .state =
            'treatment';
        await tester.pumpAndSettle();

        expect(find.text('No activities match your filters.'), findsOneWidget);
        expect(find.text('No activities yet.'), findsNothing);
      },
    );

    group('attribution (#44, FR-TEN-2)', () {
      testWidgets('shows "You" and a distinguishable placeholder per row', (
        tester,
      ) async {
        await _openActivitiesTab(
          tester,
          activities: [
            _activity('mine', date: '2026-06-01', performedBy: 'test-user'),
            _activity(
              'theirs',
              date: '2026-06-02',
              performedBy: 'other-aaaaaaaa',
            ),
          ],
        );

        expect(find.text('You'), findsOneWidget);
        expect(find.textContaining('Member'), findsOneWidget);
      });
    });

    group('organization scoping (#43 AC: never include other organizations\' '
        'activities, FR-TEN-2)', () {
      testWidgets(
        'only the caller\'s own organization\'s activities render, even if a '
        'foreign-org row is (hypothetically) present locally',
        (tester) async {
          final repo = _MultiOrgActivitiesRepository([
            _activity(
              'own',
              date: '2026-06-01',
              apiaryId: 'a1',
              organizationId: 'test-org',
            ),
            _activity(
              'foreign',
              date: '2026-06-02',
              apiaryId: 'a2',
              organizationId: 'some-other-org',
            ),
          ]);

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                isAuthenticatedProvider.overrideWithValue(true),
                apiariesStreamProvider.overrideWith(
                  (ref) => Stream.value(_apiaries),
                ),
                // Tasks is the app's landing screen now (#427, D-29) — stub its
                // stream so booting the app renders the Todos tab without
                // hanging on the real, never-resolving todos repository chain.
                todosStreamProvider.overrideWith(
                  (ref) => Stream.value(const <Todo>[]),
                ),
                activitiesRepositoryProvider.overrideWith((ref) async => repo),
                profileProvider.overrideWith(_CompleteProfileController.new),
                organizationProvider.overrideWith(
                  _ExistingOrganizationController.new,
                ),
              ],
              child: const BeekeepingitApp(),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('shell-tab-activities')));
          await tester.pumpAndSettle();

          expect(find.byKey(const Key('activity-own')), findsOneWidget);
          expect(find.byKey(const Key('activity-foreign')), findsNothing);
        },
      );
    });
  });
}
