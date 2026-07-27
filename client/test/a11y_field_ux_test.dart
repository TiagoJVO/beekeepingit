// Systematic accessibility + field-first UX sweep (#79, #80, D-18) across the
// app's main flows: login, apiaries list/form, profile, organization,
// account, members. Generalizes the single tap-target check
// `apiaries_list_screen_test.dart` already had (the toggle segments) into a
// shared assertion (`test/support/a11y_matchers.dart`) applied consistently,
// plus semantics-label and keyboard-focus-order checks per the checklist:
// `docs/design/accessibility-field-ux-checklist.md`.
//
// One sweep file rather than scattering into each screen's own test file:
// these are cross-cutting checks (the same shape of assertion, repeated per
// screen) rather than screen-specific behavior, so they're easier to keep
// consistent and to extend for a new screen in one place.
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/features/account/account_screen.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_list_screen.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_form_screen.dart';
import 'package:beekeepingit_client/features/auth/login_screen.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/members/members_screen.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_screen.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_screen.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/shell/sync_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/a11y_matchers.dart';

class _FakeDeviceLocationService implements DeviceLocationService {
  const _FakeDeviceLocationService();
  @override
  Future<DeviceLocation> current() async => const DeviceLocationUnavailable();
}

class _CompleteProfileController extends ProfileController {
  @override
  Future<Profile> build() async => Profile(
    id: 'u1',
    name: 'Ana',
    email: 'ana@example.com',
    locale: 'en',
    profileComplete: true,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _IncompleteProfileController extends ProfileController {
  @override
  Future<Profile> build() async => Profile(
    id: 'u1',
    name: '',
    email: '',
    locale: 'en',
    profileComplete: false,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _ExistingOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => Organization(
    id: 'org-1',
    name: 'Test Apiary Co.',
    address: '',
    createdBy: 'u1',
    role: 'admin',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _EmptyOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => null;
}

class _EmptyMembersController extends MembersController {
  @override
  Future<MembersState> build() async =>
      const MembersState(members: [], invitations: []);
}

// `List<Object>` + `.cast()` below because Riverpod 3 no longer exports the
// `Override` type by name — `cast()`'s target is inferred from
// `ProviderScope.overrides`' own declared type.
Widget _withMaterial(Widget child, {List<Object> overrides = const []}) {
  return ProviderScope(
    overrides: overrides.cast(),
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
}

void main() {
  group('tap targets (>= 44x44) — #80 AC "large tap targets"', () {
    testWidgets('login screen primary action', (tester) async {
      await tester.pumpWidget(_withMaterial(const LoginScreen()));
      await tester.pumpAndSettle();

      expectMinTapTarget(tester, find.byKey(const Key('login-button')));
    });

    testWidgets('apiaries list view-toggle segments', (tester) async {
      final router = GoRouter(
        initialLocation: '/apiaries',
        routes: [
          GoRoute(
            path: '/apiaries',
            builder: (context, state) =>
                const Scaffold(body: ApiariesListScreen()),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiariesStreamProvider.overrideWith(
              (ref) => Stream.value(const []),
            ),
            deviceLocationServiceProvider.overrideWithValue(
              const _FakeDeviceLocationService(),
            ),
          ],
          child: MaterialApp.router(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expectMinTapTarget(
        tester,
        find.byKey(const Key('apiaries-view-list-button')),
      );
      expectMinTapTarget(
        tester,
        find.byKey(const Key('apiaries-view-map-button')),
      );
    });

    testWidgets('apiary form save button (create mode)', (tester) async {
      // The form screen relies on the app shell's Scaffold for its Material
      // ancestor — supply one here like the shell does.
      await tester.pumpWidget(
        _withMaterial(const Scaffold(body: ApiaryFormScreen())),
      );
      await tester.pumpAndSettle();

      expectMinTapTarget(tester, find.byKey(const Key('apiary-save-button')));
    });

    testWidgets('profile screen save button', (tester) async {
      await tester.pumpWidget(
        _withMaterial(
          const ProfileScreen(),
          overrides: [
            profileProvider.overrideWith(_IncompleteProfileController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expectMinTapTarget(tester, find.byKey(const Key('profile-save-button')));
    });

    testWidgets('organization screen save button', (tester) async {
      await tester.pumpWidget(
        _withMaterial(
          const OrganizationScreen(),
          overrides: [
            organizationProvider.overrideWith(_EmptyOrganizationController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expectMinTapTarget(
        tester,
        find.byKey(const Key('organization-save-button')),
      );
    });

    testWidgets('account screen actions', (tester) async {
      await tester.pumpWidget(
        _withMaterial(
          const AccountScreen(),
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            profileProvider.overrideWith(_CompleteProfileController.new),
            organizationProvider.overrideWith(
              _ExistingOrganizationController.new,
            ),
            syncStatusProvider.overrideWithValue(
              const SyncStatus(
                connectivity: SyncConnectivity.online,
                pendingCount: 0,
              ),
            ),
            syncNowProvider.overrideWithValue(() async {}),
          ],
        ),
      );
      await tester.pumpAndSettle();

      for (final key in [
        'account-save-button',
        'account-change-password-button',
        'account-manage-members-button',
        'account-logout-button',
      ]) {
        await tester.ensureVisible(find.byKey(Key(key)));
        await tester.pumpAndSettle();
        expectMinTapTarget(tester, find.byKey(Key(key)));
      }
    });

    testWidgets('members invite button (not full-width, still >= 44x44)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _withMaterial(
          const MembersScreen(),
          overrides: [
            membersProvider.overrideWith(_EmptyMembersController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expectMinTapTarget(tester, find.byKey(const Key('invite-submit-button')));
    });
  });

  group(
    'semantics labels — #79 AC "screens expose proper semantics/labels"',
    () {
      testWidgets('login button announces its action', (tester) async {
        await tester.pumpWidget(_withMaterial(const LoginScreen()));
        await tester.pumpAndSettle();

        expectHasSemanticsLabel(tester, const Key('login-button'));
      });

      testWidgets('apiaries view toggle segments announce list/map', (
        tester,
      ) async {
        final router = GoRouter(
          initialLocation: '/apiaries',
          routes: [
            GoRoute(
              path: '/apiaries',
              builder: (context, state) =>
                  const Scaffold(body: ApiariesListScreen()),
            ),
          ],
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiariesStreamProvider.overrideWith(
                (ref) => Stream.value(const []),
              ),
              deviceLocationServiceProvider.overrideWithValue(
                const _FakeDeviceLocationService(),
              ),
            ],
            child: MaterialApp.router(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expectHasSemanticsLabel(tester, const Key('apiaries-view-list-button'));
        expectHasSemanticsLabel(tester, const Key('apiaries-view-map-button'));
      });

      testWidgets('account screen logout announces as a button', (
        tester,
      ) async {
        await tester.pumpWidget(
          _withMaterial(
            const AccountScreen(),
            overrides: [
              isAuthenticatedProvider.overrideWithValue(true),
              profileProvider.overrideWith(_CompleteProfileController.new),
              organizationProvider.overrideWith(
                _ExistingOrganizationController.new,
              ),
              syncStatusProvider.overrideWithValue(
                const SyncStatus(
                  connectivity: SyncConnectivity.online,
                  pendingCount: 0,
                ),
              ),
              syncNowProvider.overrideWithValue(() async {}),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('account-logout-button')),
        );
        await tester.pumpAndSettle();
        expectHasSemanticsLabel(tester, const Key('account-logout-button'));
      });
    },
  );

  group('keyboard focus order — #79 AC "reachable and operable by keyboard '
      'with ... a logical focus order"', () {
    // FocusManager.instance.primaryFocus is the FocusNode that actually owns
    // keyboard input right now. Checking whether *that* node's context sits
    // inside the keyed widget's own subtree (rather than asking the keyed
    // element itself, via Focus.of, which walks *up* the tree and would
    // report an ancestor FocusScope instead of a descendant control's own
    // node) is the precise way to assert "this exact field/button is the one
    // currently focused" for both TextFormFields and the FilledButton/
    // OutlinedButton wrapped inside PrimaryActionButton/SecondaryActionButton.
    bool fieldHasFocus(WidgetTester tester, Key key) {
      final focusedContext = FocusManager.instance.primaryFocus?.context;
      if (focusedContext == null) return false;
      final target = find.byKey(key).evaluate().single;
      if (focusedContext == target) return true;
      var found = false;
      focusedContext.visitAncestorElements((ancestor) {
        if (ancestor == target) {
          found = true;
          return false;
        }
        return true;
      });
      return found;
    }

    testWidgets('organization form: name field is focused first, address '
        'next, then save', (tester) async {
      await tester.pumpWidget(
        _withMaterial(
          const OrganizationScreen(),
          overrides: [
            organizationProvider.overrideWith(_EmptyOrganizationController.new),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // The name field has autofocus: true (organization_screen.dart) — it's
      // the logical first stop for a keyboard/screen-reader user landing on
      // this onboarding-gate screen.
      expect(
        fieldHasFocus(tester, const Key('organization-name-field')),
        isTrue,
      );

      // Tab moves focus forward in visual order: name -> address -> save.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        fieldHasFocus(tester, const Key('organization-address-field')),
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        fieldHasFocus(tester, const Key('organization-save-button')),
        isTrue,
      );
    });
  });
}
