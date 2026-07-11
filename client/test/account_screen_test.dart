import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/account/account_screen.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// An organization fixture so [AccountScreen]'s org-admin-only manage-members
/// action (relocated here by #197, see account_screen.dart) has something to
/// read `isOrgAdminProvider` from without touching a real ApiClient.
class _FixedOrganizationController extends OrganizationController {
  _FixedOrganizationController({this.role = 'admin'});
  final String role;

  @override
  Future<Organization?> build() async => Organization(
    id: 'org-1',
    name: 'Test Apiary Co.',
    address: '',
    createdBy: 'u1',
    role: role,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

Profile _profile({
  String name = 'Ana',
  String email = 'ana@example.com',
  String locale = 'en',
  bool complete = true,
}) {
  return Profile(
    id: 'u1',
    name: name,
    email: email,
    locale: locale,
    profileComplete: complete,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

/// A fake controller so tests drive [AccountScreen] without a real
/// [ApiClient]/network call — same convention as
/// `profile_screen_test.dart`'s `_FakeProfileController`, reused here rather
/// than duplicated since [AccountScreen] talks to the very same
/// `profileProvider`.
class _FakeProfileController extends ProfileController {
  _FakeProfileController(this._initial, {this.onSubmit});

  final Profile _initial;
  final Future<void> Function({String? name, String? email, String? locale})?
  onSubmit;

  @override
  Future<Profile> build() async => _initial;

  @override
  Future<void> submit({String? name, String? email, String? locale}) async {
    if (onSubmit != null) {
      await onSubmit!(name: name, email: email, locale: locale);
      return;
    }
    state = AsyncData(
      _profile(
        name: name ?? _initial.name,
        email: email ?? _initial.email,
        locale: locale ?? _initial.locale,
      ),
    );
  }
}

Widget _buildScreen(ProfileController controller, {String orgRole = 'admin'}) {
  return ProviderScope(
    overrides: [
      profileProvider.overrideWith(() => controller),
      isAuthenticatedProvider.overrideWithValue(true),
      organizationProvider.overrideWith(
        () => _FixedOrganizationController(role: orgRole),
      ),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AccountScreen(),
    ),
  );
}

void main() {
  testWidgets('renders current profile fields and the change-password action', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeProfileController(_profile(name: 'Ana', email: 'ana@example.com')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account-name-field')), findsOneWidget);
    expect(find.byKey(const Key('account-email-field')), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('ana@example.com'), findsOneWidget);
    // Presence/wiring only — not tapped: it opens a real browser tab via a
    // web-only platform call (see account_platform.dart), matching how
    // widget_test.dart never taps 'login-button' for the same reason.
    expect(
      find.byKey(const Key('account-change-password-button')),
      findsOneWidget,
    );
    expect(find.text('Change password'), findsOneWidget);
  });

  testWidgets('does not show a subscription/billing section (D-4)', (
    tester,
  ) async {
    await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
    await tester.pumpAndSettle();

    expect(find.textContaining('ubscription'), findsNothing);
    expect(find.textContaining('illing'), findsNothing);
  });

  testWidgets('validates empty name and email client-side', (tester) async {
    await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('account-name-field')), '');
    await tester.enterText(find.byKey(const Key('account-email-field')), '');
    await tester.tap(find.byKey(const Key('account-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter your name.'), findsOneWidget);
    expect(find.text('Enter your email.'), findsOneWidget);
  });

  testWidgets('submits updated profile fields and shows success', (
    tester,
  ) async {
    await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('account-name-field')),
      'Beatriz',
    );
    await tester.tap(find.byKey(const Key('account-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('Profile saved.'), findsOneWidget);
  });

  testWidgets('surfaces a mocked 422 field error from the server', (
    tester,
  ) async {
    final controller = _FakeProfileController(
      _profile(),
      onSubmit: ({name, email, locale}) async {
        throw const ApiException(
          statusCode: 422,
          code: 'validation.failed',
          detail: 'one or more fields are invalid',
          fieldErrors: [
            ApiFieldError(
              field: 'email',
              code: 'invalid',
              message: 'email must be a valid email address',
            ),
          ],
        );
      },
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('account-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('email must be a valid email address'), findsOneWidget);
  });

  testWidgets('org admins see the manage-members action (#172, #197)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildScreen(_FakeProfileController(_profile()), orgRole: 'admin'),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('account-manage-members-button')),
      findsOneWidget,
    );
  });

  testWidgets(
    'non-admin org members do not see the manage-members action (#172, #197)',
    (tester) async {
      await tester.pumpWidget(
        _buildScreen(_FakeProfileController(_profile()), orgRole: 'user'),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('account-manage-members-button')),
        findsNothing,
      );
    },
  );

  testWidgets('shows a sign-out action (#197)', (tester) async {
    await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account-logout-button')), findsOneWidget);
  });
}
