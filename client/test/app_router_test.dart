import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );
  }
}

Widget _buildApp({
  required bool profileComplete,
  bool hasOrganization = true,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
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

      expect(
        find.byKey(const Key('organization-name-field')),
        findsOneWidget,
      );
      expect(find.text('Apiaries'), findsNothing);
    },
  );

  testWidgets(
    'an authenticated user with a complete profile and an organization reaches the apiaries home',
    (tester) async {
      await tester.pumpWidget(_buildApp(profileComplete: true));
      await tester.pumpAndSettle();

      expect(find.text('Apiaries'), findsOneWidget);
      expect(find.byKey(const Key('profile-name-field')), findsNothing);
      expect(find.byKey(const Key('organization-name-field')), findsNothing);
    },
  );

  testWidgets(
    'tapping the account-settings action from the apiaries home reaches /account (#29)',
    (tester) async {
      await tester.pumpWidget(_buildApp(profileComplete: true));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('account-settings-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('account-name-field')), findsOneWidget);
      expect(find.text('Apiaries'), findsNothing);
    },
  );
}
