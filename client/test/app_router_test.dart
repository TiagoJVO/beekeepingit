import 'dart:convert';

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
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
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'widget_test.dart' show FakeDeviceLocationService;

/// A no-op [LocalPrefs] fake used to seed the onboarding gate's offline
/// cache (#390) — mirrors auth_controller_test.dart's own `FakeLocalPrefs`.
class _FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> _store = {};

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

Profile _profileFixture({required bool complete}) => Profile(
  id: 'u1',
  name: complete ? 'Ana' : '',
  email: complete ? 'ana@example.com' : '',
  locale: 'en',
  profileComplete: complete,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

/// A no-op controller that reports a fixed completeness, so the router's
/// redirect logic can be exercised without a real ApiClient/network call.
class _FixedProfileController extends ProfileController {
  _FixedProfileController(this._complete);
  final bool _complete;

  @override
  Future<Profile> build() async => _profileFixture(complete: _complete);
}

/// Starts INCOMPLETE and completes on `submit`, so the profile screen's own
/// post-save hand-off (`context.go`, profile_screen.dart) can be driven
/// end-to-end against the REAL router — the only place that decides where a
/// just-onboarded user lands. `submit` is stubbed rather than delegated to
/// the base controller so no ApiClient/network is involved.
class _CompletingProfileController extends ProfileController {
  bool _complete = false;

  @override
  Future<Profile> build() async => _profileFixture(complete: _complete);

  @override
  Future<void> submit({String? name, String? email, String? locale}) async {
    _complete = true;
    state = AsyncData(_profileFixture(complete: true));
  }
}

Organization _organizationFixture() => Organization(
  id: 'org-1',
  name: 'Dev Apiary Co.',
  address: '',
  createdBy: 'u1',
  role: 'admin', // not under test here — this fixture only exercises has-org routing
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

/// A no-op controller that reports a fixed organization (or none), so the
/// router's org-completion gate (#26) can be exercised without a real
/// ApiClient/network call.
class _FixedOrganizationController extends OrganizationController {
  _FixedOrganizationController(this._hasOrganization);
  final bool _hasOrganization;

  @override
  Future<Organization?> build() async =>
      _hasOrganization ? _organizationFixture() : null;
}

/// Starts with NO organization and creates one on `submit` — the second half
/// of the onboarding hand-off (organization_screen.dart's own `context.go`
/// after a successful create). Same rationale as
/// [_CompletingProfileController]: exercise the real router's landing
/// decision without a real ApiClient.
class _CreatingOrganizationController extends OrganizationController {
  Organization? _organization;

  @override
  Future<Organization?> build() async => _organization;

  @override
  Future<void> submit({required String name, String? address}) async {
    _organization = _organizationFixture();
    state = AsyncData(_organization);
  }
}

/// An always-empty members controller so `/organization/members` renders its
/// real (empty) list instead of spinning on a never-resolving fetch — the
/// members screen is only visited here to prove where its BACK button lands.
class _EmptyMembersController extends MembersController {
  @override
  Future<MembersState> build() async =>
      const MembersState(members: [], invitations: []);
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

/// Reaches the live GoRouter of a pumped [BeekeepingitApp], so a test can
/// navigate to a route the UI offers no button for.
GoRouter _routerOf(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(Navigator).first));

Widget _buildApp({
  required bool profileComplete,
  bool hasOrganization = true,
  ProfileController Function()? profileController,
  OrganizationController Function()? organizationController,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      deviceLocationServiceProvider.overrideWithValue(
        const FakeDeviceLocationService(),
      ),
      // Home is the landing screen (#658, D-35, amending D-29) and it
      // composes ALL FOUR org-scoped streams (home_providers.dart), so all
      // four are stubbed here — not just the Tasks one #427 needed — to keep
      // the landing render hermetic.
      apiariesStreamProvider.overrideWith((ref) => Stream.value(const [])),
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      journeysStreamProvider.overrideWith(
        (ref) => Stream.value(const <Journey>[]),
      ),
      activitiesStreamProvider.overrideWith(
        (ref) => Stream.value(const <Activity>[]),
      ),
      profileProvider.overrideWith(
        profileController ?? () => _FixedProfileController(profileComplete),
      ),
      organizationProvider.overrideWith(
        organizationController ??
            () => _FixedOrganizationController(hasOrganization),
      ),
      // /organization/members is visited below only to prove where its back
      // button lands; without this its real controller would fetch.
      membersProvider.overrideWith(_EmptyMembersController.new),
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

  // --- the second onboarding exit (#365 live testing, FR-ONB-2/D-3) -------
  //
  // The gate was WIDENED, not opened: /organization/new stays the default
  // landing (pinned by the test above, deliberately left unchanged), and
  // everything outside the two permitted onboarding destinations is still
  // bounced.

  testWidgets('a profile-complete user with no organization may sit on '
      '/organization/waiting', (tester) async {
    await tester.pumpWidget(
      _buildApp(profileComplete: true, hasOrganization: false),
    );
    await tester.pumpAndSettle();

    // Reachable from the create form, which is where the router lands them.
    await tester.tap(find.byKey(const Key('organization-join-instead-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('organization-waiting-check-button')),
      findsOneWidget,
    );
    // Not bounced back to the create form.
    expect(find.byKey(const Key('organization-name-field')), findsNothing);
  });

  testWidgets(
    '/organization/members is STILL bounced pre-onboarding - the permitted '
    'set is two explicit routes, not a /organization/* prefix',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(profileComplete: true, hasOrganization: false),
      );
      await tester.pumpAndSettle();

      _routerOf(tester).go('/organization/members');
      await tester.pumpAndSettle();

      // A prefix match would have let this through, and no other test would
      // have noticed - a members screen before any membership exists.
      expect(find.byKey(const Key('organization-name-field')), findsOneWidget);
    },
  );

  // --- the landing screen is Home (#658, D-35, amending D-29) -------------
  //
  // D-29's Tasks landing (#427) is superseded: a raw task list answers "what
  // do I need to do today" for one tab only, and answers nothing at all for a
  // new organization. Every entry point into "the app home" — boot, the
  // post-login redirect, the post-onboarding redirect, and the four screens
  // whose back/save action means "go home" — must agree on /home, so each is
  // pinned separately below rather than trusting one initialLocation test to
  // cover them all.

  testWidgets(
    'an authenticated, fully-onboarded user lands on Home, NOT the Tasks list '
    '(#658, D-35, D-29 as amended)',
    (tester) async {
      await tester.pumpWidget(_buildApp(profileComplete: true));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-screen')), findsOneWidget);
      // The Todos tab's own filter bar is unique to the Tasks screen, so its
      // ABSENCE is what proves the landing actually moved off it (#427's
      // landing target) rather than Home merely being reachable.
      expect(find.byKey(const Key('todo-filter-status-field')), findsNothing);
      expect(find.byKey(const Key('shell-bottom-nav')), findsOneWidget);
      expect(find.byKey(const Key('profile-name-field')), findsNothing);
      expect(find.byKey(const Key('organization-name-field')), findsNothing);
    },
  );

  testWidgets(
    'an already-authenticated user who hits /login is redirected to Home '
    '(#658, D-35)',
    (tester) async {
      await tester.pumpWidget(_buildApp(profileComplete: true));
      await tester.pumpAndSettle();

      _routerOf(tester).go('/login');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-screen')), findsOneWidget);
      expect(find.byKey(const Key('todo-filter-status-field')), findsNothing);
    },
  );

  testWidgets(
    'an onboarded user who hits an onboarding route is redirected to Home '
    '(the post-onboarding target, #658, D-35)',
    (tester) async {
      await tester.pumpWidget(_buildApp(profileComplete: true));
      await tester.pumpAndSettle();

      _routerOf(tester).go('/organization/new');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-screen')), findsOneWidget);
      expect(find.byKey(const Key('organization-name-field')), findsNothing);
      expect(find.byKey(const Key('todo-filter-status-field')), findsNothing);
    },
  );

  testWidgets(
    'finishing profile onboarding lands on Home (profile_screen.dart\'s own '
    'post-save hand-off, #658, D-35)',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(
          profileComplete: false,
          profileController: _CompletingProfileController.new,
        ),
      );
      await tester.pumpAndSettle();

      // The gate put us on /profile; completing it is what hands off.
      expect(find.byKey(const Key('profile-name-field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('profile-name-field')),
        'Ana',
      );
      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-screen')), findsOneWidget);
      expect(find.byKey(const Key('todo-filter-status-field')), findsNothing);
    },
  );

  testWidgets('finishing organization onboarding lands on Home '
      '(organization_screen.dart\'s own post-save hand-off, #658, D-35)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        profileComplete: true,
        hasOrganization: false,
        organizationController: _CreatingOrganizationController.new,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('organization-name-field')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('organization-name-field')),
      'Dev Apiary Co.',
    );
    await tester.tap(find.byKey(const Key('organization-save-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-screen')), findsOneWidget);
    expect(find.byKey(const Key('todo-filter-status-field')), findsNothing);
  });

  testWidgets(
    'tapping the shell account action from Home reaches /account (#29), and '
    'its back button returns to Home (#658, D-35)',
    (tester) async {
      await tester.pumpWidget(_buildApp(profileComplete: true));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell-account-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('account-name-field')), findsOneWidget);
      expect(find.text('Apiaries'), findsNothing);

      await tester.tap(find.byKey(const Key('account-back-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-screen')), findsOneWidget);
      expect(find.byKey(const Key('todo-filter-status-field')), findsNothing);
    },
  );

  testWidgets(
    'the members screen\'s back button returns to Home (#658, D-35)',
    (tester) async {
      await tester.pumpWidget(_buildApp(profileComplete: true));
      await tester.pumpAndSettle();

      _routerOf(tester).go('/organization/members');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('members-back-button')), findsOneWidget);

      await tester.tap(find.byKey(const Key('members-back-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('home-screen')), findsOneWidget);
      expect(find.byKey(const Key('todo-filter-status-field')), findsNothing);
    },
  );

  // #390: a previously-onboarded user must not be bounced to /profile or
  // /organization/new just because the REST fetch fails offline — the
  // repositories' own cache (ProfileRepository.fetch()/
  // OrganizationRepository.fetchMine()) should serve the last-known-good
  // snapshot instead, so the router's gate resolves the same way it would
  // online. Unlike `_buildApp` above (which overrides profileProvider/
  // organizationProvider directly with fixed controllers, bypassing the
  // repositories entirely), this drives the REAL ProfileController/
  // OrganizationController against a throwing ApiClient, to prove the
  // cache fallback itself — not just the router's handling of an
  // already-resolved value.
  testWidgets(
    'a previously-onboarded user reaches the apiaries home when the profile/'
    'organization fetch fails offline but a cached snapshot exists (#390)',
    (tester) async {
      final cache = _FakeLocalPrefs()
        ..write(
          kProfileCacheKey,
          jsonEncode({
            'id': 'u1',
            'name': 'Ana',
            'email': 'ana@example.com',
            'locale': 'en',
            'profile_complete': true,
            'created_at': '2026-01-01T00:00:00.000Z',
            'updated_at': '2026-01-01T00:00:00.000Z',
          }),
        )
        ..write(
          kOrganizationCacheKey,
          jsonEncode({
            'id': 'org-1',
            'name': 'Dev Apiary Co.',
            'address': '',
            'created_by': 'u1',
            'role': 'admin',
            'created_at': '2026-01-01T00:00:00.000Z',
            'updated_at': '2026-01-01T00:00:00.000Z',
          }),
        );
      final throwingClient = MockClient((req) async {
        throw http.ClientException('Failed host lookup');
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            deviceLocationServiceProvider.overrideWithValue(
              const FakeDeviceLocationService(),
            ),
            apiariesStreamProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
            // Tasks is the landing screen (#427, D-29) — stub its stream so
            // the home renders without the sync engine.
            todosStreamProvider.overrideWith(
              (ref) => Stream.value(const <Todo>[]),
            ),
            apiClientProvider.overrideWith(
              (ref) => ApiClient(ref, httpClient: throwingClient),
            ),
            profileRepositoryProvider.overrideWith(
              (ref) =>
                  ProfileRepository(ref.watch(apiClientProvider), prefs: cache),
            ),
            organizationRepositoryProvider.overrideWith(
              (ref) => OrganizationRepository(
                ref.watch(apiClientProvider),
                prefs: cache,
              ),
            ),
          ],
          child: const BeekeepingitApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Apiaries'), findsWidgets);
      expect(find.byKey(const Key('shell-bottom-nav')), findsOneWidget);
      expect(find.byKey(const Key('profile-name-field')), findsNothing);
      expect(find.byKey(const Key('organization-name-field')), findsNothing);
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
          // Tasks is the app's landing screen now (#427, D-29) — stub its
          // stream so the boot pumpAndSettle doesn't hang on the real,
          // never-resolving todos repository chain before router.go(...).
          todosStreamProvider.overrideWith(
            (ref) => Stream.value(const <Todo>[]),
          ),
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
