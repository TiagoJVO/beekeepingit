import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'widget_test.dart' show FakeDeviceLocationService;

/// A no-op controller that reports a fixed completeness, so the router's
/// redirect logic can be exercised without a real ApiClient/network call.
class _FixedProfileController extends ProfileController {
  _FixedProfileController(this._complete);
  final bool _complete;

  @override
  Future<Profile> build() async => Profile(
    id: 'u1',
    name: _complete ? 'Ana' : '',
    email: _complete ? 'ana@example.com' : '',
    locale: 'en',
    profileComplete: _complete,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

/// A no-op controller that reports a fixed organization (or none), so the
/// router's org-completion gate (#26) can be exercised without a real
/// ApiClient/network call.
class _FixedOrganizationController extends OrganizationController {
  _FixedOrganizationController(this._hasOrganization);
  final bool _hasOrganization;

  @override
  Future<Organization?> build() async {
    if (!_hasOrganization) return null;
    return Organization(
      id: 'org-1',
      name: 'Dev Apiary Co.',
      address: '',
      createdBy: 'u1',
      role:
          'admin', // not under test here — this fixture only exercises has-org routing
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }
}

/// A no-op [LocalStoreEngine] for [_FakeJourneysRepository] (#391's
/// `/journeys/:id/stats` resolution test below) — mirrors
/// journey_stats_detail_screen_test.dart's identical fixture.
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

const _routeTestJourney = Journey(
  id: 'j1',
  name: 'Colheita de Primavera',
  mainActivityType: 'harvest',
  status: journeyStatusOpen,
);

Widget _buildApp({required bool profileComplete, bool hasOrganization = true}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      deviceLocationServiceProvider.overrideWithValue(
        const FakeDeviceLocationService(),
      ),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(const [])),
      profileProvider.overrideWith(
        () => _FixedProfileController(profileComplete),
      ),
      organizationProvider.overrideWith(
        () => _FixedOrganizationController(hasOrganization),
      ),
    ],
    child: const BeekeepingitApp(),
  );
}

void main() {
  testWidgets(
    'an authenticated user with an incomplete profile is redirected to /profile',
    (tester) async {
      await tester.pumpWidget(_buildApp(profileComplete: false));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile-name-field')), findsOneWidget);
      expect(find.text('Apiaries'), findsNothing);
    },
  );

  testWidgets(
    'a profile-complete user with no organization is redirected to /organization/new',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(profileComplete: true, hasOrganization: false),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('organization-name-field')), findsOneWidget);
      expect(find.text('Apiaries'), findsNothing);
    },
  );

  testWidgets(
    'an authenticated user with a complete profile and an organization reaches the apiaries home',
    (tester) async {
      await tester.pumpWidget(_buildApp(profileComplete: true));
      await tester.pumpAndSettle();

      // "Apiaries" now appears twice (shell header title + bottom-nav tab
      // label, #197) — findsWidgets rather than findsOneWidget.
      expect(find.text('Apiaries'), findsWidgets);
      expect(find.byKey(const Key('shell-bottom-nav')), findsOneWidget);
      expect(find.byKey(const Key('profile-name-field')), findsNothing);
      expect(find.byKey(const Key('organization-name-field')), findsNothing);
    },
  );

  testWidgets(
    'tapping the shell account action from the apiaries home reaches /account (#29)',
    (tester) async {
      await tester.pumpWidget(_buildApp(profileComplete: true));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell-account-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('account-name-field')), findsOneWidget);
      expect(find.text('Apiaries'), findsNothing);
    },
  );

  testWidgets('/journeys/:id/stats resolves to the #391 breakdown screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isAuthenticatedProvider.overrideWithValue(true),
          deviceLocationServiceProvider.overrideWithValue(
            const FakeDeviceLocationService(),
          ),
          apiariesStreamProvider.overrideWith((ref) => Stream.value(const [])),
          journeysStreamProvider.overrideWith(
            (ref) => Stream.value(const [_routeTestJourney]),
          ),
          journeyByIdProvider.overrideWith(
            (ref, id) => Stream.value(_routeTestJourney),
          ),
          activitiesByJourneyProvider.overrideWith(
            (ref, id) => Stream.value(const []),
          ),
          journeyPlanApiariesByJourneyProvider.overrideWith(
            (ref) => Stream.value(const {'j1': <String>[]}),
          ),
          journeysRepositoryProvider.overrideWith(
            (ref) async => _FakeJourneysRepository(_routeTestJourney),
          ),
          profileProvider.overrideWith(() => _FixedProfileController(true)),
          organizationProvider.overrideWith(
            () => _FixedOrganizationController(true),
          ),
        ],
        child: const BeekeepingitApp(),
      ),
    );
    await tester.pumpAndSettle();

    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/journeys/j1/stats');
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('journey-stats-filter-bar')), findsOneWidget);
  });

  testWidgets(
    '/todos/new?apiaryId=a1 builds TodoFormScreen with that apiary already '
    'selected (#389, preserving the create-from-apiary flow #52\'s '
    'quick-create sheet used to carry)',
    (tester) async {
      // The full form's content exceeds the default 800x600 test viewport
      // (todo_form_screen_test.dart's own note).
      tester.view.physicalSize = const Size(1200, 3600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            deviceLocationServiceProvider.overrideWithValue(
              const FakeDeviceLocationService(),
            ),
            apiariesStreamProvider.overrideWith(
              (ref) => Stream.value(const [
                Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4),
              ]),
            ),
            todosStreamProvider.overrideWith(
              (ref) => Stream.value(const <Todo>[]),
            ),
            // Kept hermetic (#44's own convention) — the form's assignee
            // picker would otherwise attempt a real fetch.
            memberNamesProvider.overrideWith(
              (ref) async => const <String, String>{},
            ),
            profileProvider.overrideWith(() => _FixedProfileController(true)),
            organizationProvider.overrideWith(
              () => _FixedOrganizationController(true),
            ),
          ],
          child: const BeekeepingitApp(),
        ),
      );
      await tester.pumpAndSettle();

      final router = GoRouter.of(tester.element(find.byType(AppShell)));
      router.go('/todos/new?apiaryId=a1');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('todo-apiary-option-a1')),
          matching: find.byIcon(Icons.radio_button_checked),
        ),
        findsOneWidget,
      );
    },
  );
}
