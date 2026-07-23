import 'dart:convert';

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
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
