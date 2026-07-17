import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/routing/app_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The full per-apiary activities screen (#42, FR-AC-5): the properly-
/// virtualized list the detail page's capped preview links out to. Fixtures
/// mirror apiary_activities_section_test.dart's.
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

Activity _activity(String id, {required String date}) => Activity(
  id: id,
  apiaryId: 'a1',
  type: 'generic',
  occurredAt: date,
  attributes: const {},
);

Future<void> _openFullList(
  WidgetTester tester, {
  required List<Activity> activities,
}) async {
  await tester.pumpWidget(
    ProviderScope(
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
    ),
  );
  await tester.pumpAndSettle();
  // Deep-link straight to the full list (the detail page's "view all" is
  // covered by apiary_activities_section_test.dart).
  final container = ProviderScope.containerOf(
    tester.element(find.byType(BeekeepingitApp)),
  );
  container.read(routerProvider).go('/apiaries/a1/activities');
  await tester.pumpAndSettle();
}

void main() {
  group('apiary activities full-screen list (#42, FR-AC-5)', () {
    testWidgets('titles the screen with the apiary name and lists every row', (
      tester,
    ) async {
      await _openFullList(
        tester,
        activities: [
          for (var i = 1; i <= 7; i++) _activity('a$i', date: '2026-06-0$i'),
        ],
      );

      expect(find.widgetWithText(AppBar, 'Serra Norte'), findsOneWidget);
      // All seven render — no preview cap on this screen. Some may be below
      // the fold, so scroll the last into view rather than asserting blindly.
      final last = find.byKey(const Key('activity-a7'));
      await tester.scrollUntilVisible(last, 200);
      expect(last, findsOneWidget);
      expect(find.byKey(const Key('activity-list-view-all')), findsNothing);
    });

    testWidgets('shows the empty state when the apiary has no activities', (
      tester,
    ) async {
      await _openFullList(tester, activities: const []);

      expect(
        find.text('No activities logged for this apiary yet.'),
        findsOneWidget,
      );
    });
  });
}
