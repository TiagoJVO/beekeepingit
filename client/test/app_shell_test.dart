import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixtures mirroring widget_test.dart's/app_router_test.dart's own — kept
/// local rather than imported since those files' fixtures are file-private.
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

/// Builds the full app (shell included) as an authenticated, onboarded user —
/// the app shell (FR-UX-2, #197) only appears once onboarding is done, so
/// every shell test needs the same auth/profile/org stubbing as
/// widget_test.dart's buildApp().
Widget _buildShellApp({List<Apiary>? apiaries}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith(
        (ref) => Stream.value(apiaries ?? const []),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

void main() {
  testWidgets(
    'the bottom nav shows all 5 tabs with Apiaries selected by default',
    (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-bottom-nav')), findsOneWidget);
      for (final route in [
        'apiaries',
        'activities',
        'journeys',
        'todos',
        'assistant',
      ]) {
        expect(find.byKey(Key('shell-tab-$route')), findsOneWidget);
      }
      final nav = tester.widget<NavigationBar>(
        find.byKey(const Key('shell-bottom-nav')),
      );
      expect(nav.selectedIndex, 0);
    },
  );

  testWidgets('switching tabs updates the active branch and header title', (
    tester,
  ) async {
    await tester.pumpWidget(_buildShellApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('shell-tab-activities')));
    await tester.pumpAndSettle();

    expect(find.text('Activities — coming soon'), findsOneWidget);
    var nav = tester.widget<NavigationBar>(
      find.byKey(const Key('shell-bottom-nav')),
    );
    expect(nav.selectedIndex, 1);

    await tester.tap(find.byKey(const Key('shell-tab-todos')));
    await tester.pumpAndSettle();

    expect(find.text('Todos — coming soon'), findsOneWidget);
    nav = tester.widget<NavigationBar>(
      find.byKey(const Key('shell-bottom-nav')),
    );
    expect(nav.selectedIndex, 3);
  });

  testWidgets(
    'each tab preserves its own navigation state when switching away and back',
    (tester) async {
      await tester.pumpWidget(
        _buildShellApp(
          apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)],
        ),
      );
      await tester.pumpAndSettle();

      // Push into the Apiaries branch's detail/form stack.
      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);

      // Switch away to another tab and back.
      await tester.tap(find.byKey(const Key('shell-tab-journeys')));
      await tester.pumpAndSettle();
      expect(find.text('Journeys — coming soon'), findsOneWidget);

      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
      await tester.pumpAndSettle();

      // StatefulShellRoute.indexedStack keeps each branch's own Navigator
      // alive (IndexedStack, not a rebuild) — the pushed apiary form is
      // still on top of the Apiaries tab's stack, not reset to its root.
      expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
    },
  );

  testWidgets(
    'the FAB shows the Apiaries-tab label and navigates to the new-apiary form',
    (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-fab')), findsOneWidget);
      expect(find.text('Add apiary'), findsOneWidget);

      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
      expect(find.text('New apiary'), findsOneWidget);
    },
  );

  testWidgets(
    'tabs without real content yet have no FAB (Activities/Journeys/Todos/Assistant)',
    (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      for (final route in ['activities', 'journeys', 'todos', 'assistant']) {
        await tester.tap(find.byKey(Key('shell-tab-$route')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('shell-fab')),
          findsNothing,
          reason: '$route tab should not show the contextual FAB',
        );
      }
    },
  );

  testWidgets(
    'the header has no back button at each tab root, but shows one after pushing into a stack',
    (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-back-button')), findsNothing);

      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-back-button')), findsOneWidget);
      expect(find.text('New apiary'), findsOneWidget);

      await tester.tap(find.byKey(const Key('shell-back-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-back-button')), findsNothing);
      expect(find.text('Apiaries'), findsWidgets);
    },
  );

  testWidgets('the header shows the sync-status pill and an account action', (
    tester,
  ) async {
    await tester.pumpWidget(_buildShellApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shell-sync-pill')), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.byKey(const Key('shell-account-button')), findsOneWidget);
  });

  testWidgets('tapping the sync-status pill navigates to account settings', (
    tester,
  ) async {
    await tester.pumpWidget(_buildShellApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('shell-sync-pill')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('account-name-field')), findsOneWidget);
  });

  testWidgets('all 4 placeholder tabs render without error', (tester) async {
    await tester.pumpWidget(_buildShellApp());
    await tester.pumpAndSettle();

    const expected = {
      'activities': 'Activities — coming soon',
      'journeys': 'Journeys — coming soon',
      'todos': 'Todos — coming soon',
      'assistant': 'Assistant — coming soon',
    };
    for (final entry in expected.entries) {
      await tester.tap(find.byKey(Key('shell-tab-${entry.key}')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(entry.value), findsOneWidget);
    }
  });

  testWidgets(
    'the offline banner is hidden when the stub sync status is online',
    (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      // sync_status.dart's provider is a fixed "online, nothing pending" stub
      // (#197; real wiring is #58) — the banner has nothing to show yet.
      expect(find.byKey(const Key('shell-offline-banner')), findsNothing);
    },
  );
}
