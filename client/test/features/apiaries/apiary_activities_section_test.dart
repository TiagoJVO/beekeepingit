import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/activities/activity_filters.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
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

const _apiary = Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3);

Activity _activity(
  String id, {
  String type = 'generic',
  required String date,
  String? performedBy,
  Map<String, dynamic> attributes = const {},
}) => Activity(
  id: id,
  apiaryId: 'a1',
  type: type,
  occurredAt: date,
  attributes: attributes,
  performedBy: performedBy,
);

Widget _buildApp({required List<Activity> activities}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith(
        (ref) => Stream.value(const [_apiary]),
      ),
      apiaryByIdProvider.overrideWith((ref, id) => Stream.value(_apiary)),
      apiaryCountersProvider.overrideWith(
        (ref, id) => Stream.value(const <ApiaryCounter>[]),
      ),
      activitiesByApiaryProvider.overrideWith(
        (ref, apiaryId) => Stream.value(activities),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openDetail(
  WidgetTester tester, {
  required List<Activity> activities,
}) async {
  await tester.pumpWidget(_buildApp(activities: activities));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('apiary-a1')));
  await tester.pumpAndSettle();
}

void main() {
  group('apiary detail activities section (#42, FR-AC-5)', () {
    testWidgets('lists every activity for this apiary', (tester) async {
      await _openDetail(
        tester,
        activities: [
          _activity('1', type: 'harvest', date: '2026-06-01'),
          _activity('2', type: 'feeding', date: '2026-06-02'),
        ],
      );

      expect(
        find.byKey(const Key('apiary-detail-activities-section')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('activity-1')), findsOneWidget);
      expect(find.byKey(const Key('activity-2')), findsOneWidget);
    });

    testWidgets(
      'shows the empty state when the apiary has no activities at all',
      (tester) async {
        await _openDetail(tester, activities: const []);

        expect(
          find.text('No activities logged for this apiary yet.'),
          findsOneWidget,
        );
      },
    );

    group('type filter', () {
      testWidgets('selecting a type shows only matching activities', (
        tester,
      ) async {
        await _openDetail(
          tester,
          activities: [
            _activity('1', type: 'harvest', date: '2026-06-01'),
            _activity('2', type: 'feeding', date: '2026-06-02'),
          ],
        );

        await tester.tap(find.byKey(const Key('activity-filter-type-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Honey harvest').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('activity-1')), findsOneWidget);
        expect(find.byKey(const Key('activity-2')), findsNothing);
      });

      testWidgets(
        'a type matching nothing shows the filter no-results state, not the '
        'plain empty state',
        (tester) async {
          await _openDetail(
            tester,
            activities: [_activity('1', type: 'feeding', date: '2026-06-02')],
          );

          await tester.tap(find.byKey(const Key('activity-filter-type-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Honey harvest').last);
          await tester.pumpAndSettle();

          expect(
            find.text('No activities match your filters.'),
            findsOneWidget,
          );
          expect(
            find.text('No activities logged for this apiary yet.'),
            findsNothing,
          );
        },
      );
    });

    group('date-range filter', () {
      testWidgets(
        'setting a date range keeps only activities within it (inclusive)',
        (tester) async {
          await _openDetail(
            tester,
            activities: [
              _activity('inside', date: '2026-06-05'),
              _activity('outside', date: '2026-01-01'),
            ],
          );

          final container = ProviderScope.containerOf(
            tester.element(find.byType(BeekeepingitApp)),
          );
          container
              .read(activityDateRangeFilterProvider('a1').notifier)
              .state = ActivityDateRange(
            start: DateTime(2026, 6, 1),
            end: DateTime(2026, 6, 10),
          );
          await tester.pumpAndSettle();

          expect(find.byKey(const Key('activity-inside')), findsOneWidget);
          expect(find.byKey(const Key('activity-outside')), findsNothing);
        },
      );

      testWidgets('the clear button resets an active date-range filter', (
        tester,
      ) async {
        await _openDetail(
          tester,
          activities: [_activity('1', date: '2026-06-05')],
        );

        final container = ProviderScope.containerOf(
          tester.element(find.byType(BeekeepingitApp)),
        );
        container
            .read(activityDateRangeFilterProvider('a1').notifier)
            .state = ActivityDateRange(
          start: DateTime(2020, 1, 1),
          end: DateTime(2020, 1, 2),
        );
        await tester.pumpAndSettle();

        expect(find.text('No activities match your filters.'), findsOneWidget);

        // The clear button sits below the fold on the apiary detail page's
        // scroll view at the default test viewport — scroll it into view
        // before tapping (mirrors add_activity_screen_test.dart's own
        // ensureVisible use for its save button).
        final clearButton = find.byKey(
          const Key('activity-filter-clear-button'),
        );
        await tester.ensureVisible(clearButton);
        await tester.pumpAndSettle();
        await tester.tap(clearButton);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('activity-1')), findsOneWidget);
      });
    });

    testWidgets(
      'type and date-range filters combine (#42 AC: filters can be combined)',
      (tester) async {
        await _openDetail(
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
        container.read(activityTypeFilterProvider('a1').notifier).state =
            'harvest';
        container
            .read(activityDateRangeFilterProvider('a1').notifier)
            .state = ActivityDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('activity-match')), findsOneWidget);
        expect(find.byKey(const Key('activity-wrong-date')), findsNothing);
        expect(find.byKey(const Key('activity-wrong-type')), findsNothing);
      },
    );

    group('attribution (#44, FR-TEN-2)', () {
      testWidgets('shows "You" for an activity performed by the current user', (
        tester,
      ) async {
        await _openDetail(
          tester,
          activities: [
            _activity('1', date: '2026-06-01', performedBy: 'test-user'),
          ],
        );

        expect(find.text('You'), findsOneWidget);
      });

      testWidgets(
        'shows a distinguishable placeholder for another performer, not "You"',
        (tester) async {
          await _openDetail(
            tester,
            activities: [
              _activity('1', date: '2026-06-01', performedBy: 'other-aaaaaaaa'),
            ],
          );

          expect(find.text('You'), findsNothing);
          expect(find.textContaining('Member'), findsOneWidget);
        },
      );

      testWidgets('attribution is shown per row for a multi-activity list', (
        tester,
      ) async {
        await _openDetail(
          tester,
          activities: [
            _activity('mine', date: '2026-06-01', performedBy: 'test-user'),
            _activity(
              'theirs',
              date: '2026-06-02',
              performedBy: 'other-bbbbbbbb',
            ),
          ],
        );

        expect(find.text('You'), findsOneWidget);
        expect(find.textContaining('Member'), findsOneWidget);
      });
    });
  });
}
