import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A profile that is always complete, so these pre-existing "authenticated"
/// tests reach the apiaries home rather than being redirected to /profile by
/// the completion gate (#25) — this file predates profile onboarding and
/// isn't testing it, so it stubs profile as already done.
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

/// An organization that always exists, so these pre-existing "authenticated"
/// tests reach the apiaries home rather than being redirected to
/// /organization/new by the org-completion gate (#26) — this file predates
/// org onboarding and isn't testing it, so it stubs the org as already there.
/// Role defaults to "admin" (#172) so the manage-members app-bar action is
/// visible by default, matching this file's tests' original expectations
/// (written before that button existed) rather than silently hiding a
/// control they don't assert on either way.
class _ExistingOrganizationController extends OrganizationController {
  _ExistingOrganizationController({this.role = 'admin'});
  final String role;

  @override
  Future<Organization?> build() async => Organization(
    id: 'test-org',
    name: 'Test Apiary Co.',
    address: '',
    createdBy: 'test-user',
    role: role,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

/// Builds the app with auth + the local apiaries stream overridden, so no test
/// touches real OIDC or PowerSync. Profile and organization are stubbed as
/// already complete when authed so the router's completion gates (#25, #26)
/// don't redirect these pre-existing tests to /profile or /organization/new.
/// [orgRole] lets a test choose "admin" (default) or "user" to exercise
/// #172's admin-only nav gating.
Widget buildApp({
  required bool authed,
  List<Apiary>? apiaries,
  String orgRole = 'admin',
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(authed),
      if (apiaries != null)
        apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      if (authed) profileProvider.overrideWith(_CompleteProfileController.new),
      if (authed)
        organizationProvider.overrideWith(
          () => _ExistingOrganizationController(role: orgRole),
        ),
    ],
    child: const BeekeepingitApp(),
  );
}

void main() {
  testWidgets('unauthenticated users land on the login screen', (tester) async {
    await tester.pumpWidget(buildApp(authed: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login-button')), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('authenticated users see the apiaries list from local data', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        authed: true,
        apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)],
      ),
    );
    await tester.pumpAndSettle();

    // "Apiaries" now appears twice (shell header title + bottom-nav tab
    // label, #197) — findsWidgets rather than findsOneWidget.
    expect(find.text('Apiaries'), findsWidgets);
    expect(find.text('Serra Norte'), findsOneWidget);
    expect(find.text('3 hives'), findsOneWidget);
    expect(find.byKey(const Key('shell-fab')), findsOneWidget);
  });

  testWidgets('empty local data shows the empty state', (tester) async {
    await tester.pumpWidget(buildApp(authed: true, apiaries: const []));
    await tester.pumpAndSettle();

    expect(find.textContaining('No apiaries yet'), findsOneWidget);
  });

  testWidgets('light and dark themes are both wired', (tester) async {
    await tester.pumpWidget(buildApp(authed: false));
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme, isNotNull);
    expect(app.darkTheme, isNotNull);
  });

  testWidgets('tapping logout calls the auth controller without throwing', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        authed: true,
        apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)],
      ),
    );
    await tester.pumpAndSettle();

    // Logout lives on the account screen (#197 relocated it there from the
    // apiaries app bar, matching the prototype's "Conta" screen) — reached
    // via the shell header's account action.
    await tester.tap(find.byKey(const Key('shell-account-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account-logout-button')), findsOneWidget);

    // The account screen's actions sit below the fold in the test viewport's
    // SingleChildScrollView — scroll it into view before tapping.
    await tester.ensureVisible(find.byKey(const Key('account-logout-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-logout-button')));
    await tester.pumpAndSettle();

    // isAuthenticatedProvider is overridden to a fixed `true` in this harness
    // (see buildApp), so the router itself won't redirect on logout here —
    // this test only exercises that the logout control is wired to the
    // controller's logout() without throwing. The router's redirect-on-
    // logout behavior is covered by the real end-session/session-clearing
    // unit tests in test/core/auth/auth_controller_test.dart and by the
    // Playwright e2e (client/e2e/tests/slice.spec.ts), which drive the real
    // authControllerProvider end to end.
  });

  testWidgets(
    'org admins see the manage-members action on the account screen',
    (tester) async {
      await tester.pumpWidget(
        buildApp(authed: true, apiaries: const [], orgRole: 'admin'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell-account-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('account-manage-members-button')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'non-admin org members do not see the manage-members action (#172)',
    (tester) async {
      await tester.pumpWidget(
        buildApp(authed: true, apiaries: const [], orgRole: 'user'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell-account-button')));
      await tester.pumpAndSettle();

      // The link would only lead to a 403 for a non-admin (auth.md §5.3) —
      // hidden, not just disabled.
      expect(
        find.byKey(const Key('account-manage-members-button')),
        findsNothing,
      );
    },
  );
}
