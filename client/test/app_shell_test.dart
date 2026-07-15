import 'dart:async';

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/sync/sync_rejected_repository.dart';
import 'package:beekeepingit_client/shell/sync_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'widget_test.dart' show FakeDeviceLocationService;

/// A test-controlled stand-in for the real, PowerSync-backed
/// [syncStatusProvider] (#58) — a plain [StateProvider] so a test can push a
/// new [SyncStatus] value *after* the initial pump (unlike
/// `overrideWithValue`, which is fixed for the container's lifetime), to
/// exercise HIGH-4's rebuild-scoping regression below.
final _testSyncStatus = StateProvider<SyncStatus>(
  (ref) =>
      const SyncStatus(connectivity: SyncConnectivity.online, pendingCount: 0),
);

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
///
/// [syncStatus] overrides the real PowerSync-backed [syncStatusProvider]
/// (#58) — tests isolate the shell from a real PowerSync database/network
/// the same way [apiariesStreamProvider] is already overridden above.
/// Defaults to "online, nothing pending" so tests that don't care about sync
/// state see the same fixed status #197's stub used to provide.
/// [supersededChanges] similarly overrides the notify-and-fix event stream.
Widget _buildShellApp({
  List<Apiary>? apiaries,
  SyncStatus? syncStatus,
  Stream<SupersededChange>? supersededChanges,
  Stream<RejectedChange>? rejectedChanges,
  int needsFixCount = 0,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      deviceLocationServiceProvider.overrideWithValue(
        const FakeDeviceLocationService(),
      ),
      apiariesStreamProvider.overrideWith(
        (ref) => Stream.value(apiaries ?? const []),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      syncStatusProvider.overrideWithValue(
        syncStatus ??
            const SyncStatus(
              connectivity: SyncConnectivity.online,
              pendingCount: 0,
            ),
      ),
      supersededNotificationProvider.overrideWith(
        (ref) => supersededChanges ?? const Stream.empty(),
      ),
      // The notify-and-fix seams the shell now watches (D-12): the rejection
      // toast stream and the account-button badge count. Overridden so shell
      // tests never touch a real PowerSync database, like the two above.
      rejectedNotificationProvider.overrideWith(
        (ref) => rejectedChanges ?? const Stream.empty(),
      ),
      syncNeedsFixCountProvider.overrideWith(
        (ref) => Stream.value(needsFixCount),
      ),
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
    'the FAB hides while the apiaries map view is showing, and returns when back on the list (#35)',
    (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-fab')), findsOneWidget);

      await tester.tap(find.byKey(const Key('apiaries-view-map-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-fab')), findsNothing);

      await tester.tap(find.byKey(const Key('apiaries-view-list-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-fab')), findsOneWidget);
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

  testWidgets('the offline banner is hidden when sync status is online', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildShellApp(
        syncStatus: const SyncStatus(
          connectivity: SyncConnectivity.online,
          pendingCount: 0,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shell-offline-banner')), findsNothing);
  });

  testWidgets(
    'the offline banner shows the pending count when sync status is offline',
    (tester) async {
      await tester.pumpWidget(
        _buildShellApp(
          syncStatus: const SyncStatus(
            connectivity: SyncConnectivity.offline,
            pendingCount: 3,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-offline-banner')), findsOneWidget);
      expect(find.textContaining('3'), findsWidgets);
    },
  );

  testWidgets('the sync-status pill reflects offline with a pending count', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildShellApp(
        syncStatus: const SyncStatus(
          connectivity: SyncConnectivity.offline,
          pendingCount: 2,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Offline · 2'), findsOneWidget);
  });

  testWidgets(
    'the sync-status pill shows "Syncing…" while an upload/download is in flight',
    (tester) async {
      await tester.pumpWidget(
        _buildShellApp(
          syncStatus: const SyncStatus(
            connectivity: SyncConnectivity.online,
            pendingCount: 1,
            syncing: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Syncing…'), findsOneWidget);
    },
  );

  testWidgets('the sync-status pill shows "Waiting for better signal" when the '
      'connection-quality gate is backing off (FR-OF-3, #55)', (tester) async {
    await tester.pumpWidget(
      _buildShellApp(
        syncStatus: const SyncStatus(
          connectivity: SyncConnectivity.offline,
          pendingCount: 1,
          gateState: SyncGateState.waitingForSignal,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Waiting for better signal'), findsOneWidget);
  });

  testWidgets(
    'the sync-status pill shows a distinct error state when the last sync '
    "attempt errored — not the same 'Offline' pill as no-signal-at-all",
    (tester) async {
      await tester.pumpWidget(
        _buildShellApp(
          syncStatus: const SyncStatus(
            connectivity: SyncConnectivity.online,
            pendingCount: 2,
            hasError: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sync error'), findsOneWidget);
      expect(find.text('Online'), findsNothing);
    },
  );

  testWidgets(
    'the offline banner shows a distinct message when offline with a sync '
    'error, not the generic offline-changes-saved-locally message',
    (tester) async {
      await tester.pumpWidget(
        _buildShellApp(
          syncStatus: const SyncStatus(
            connectivity: SyncConnectivity.offline,
            pendingCount: 2,
            hasError: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-offline-banner')), findsOneWidget);
      expect(
        find.text('Some changes failed to sync and PowerSync is retrying.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a superseded change surfaces a non-blocking toast notification',
    (tester) async {
      final controller = StreamController<SupersededChange>();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _buildShellApp(supersededChanges: controller.stream),
      );
      await tester.pumpAndSettle();

      controller.add(
        const SupersededChange(entityType: 'apiary', entityId: 'a1'),
      );
      await tester.pump(); // deliver the ref.listen callback
      await tester.pump(); // let the SnackBar animate in

      expect(
        find.text(
          'One of your offline changes was overwritten by a newer edit.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('a rejected change surfaces a notify-and-fix toast with a Fix '
      'action (D-12, #256/#260)', (tester) async {
    final controller = StreamController<RejectedChange>();
    addTearDown(controller.close);

    await tester.pumpWidget(_buildShellApp(rejectedChanges: controller.stream));
    await tester.pumpAndSettle();

    controller.add(
      const RejectedChange(
        entityType: 'apiary_counter',
        entityId: 'apiary-1',
        errorCode: 'validation.failed',
      ),
    );
    await tester.pump(); // deliver the ref.listen callback
    await tester.pump(); // let the SnackBar animate in

    expect(
      find.text('One of your changes was rejected and needs fixing.'),
      findsOneWidget,
    );
    // Carries the "Fix" action that routes into the needs-fix flow.
    expect(find.widgetWithText(SnackBarAction, 'Fix'), findsOneWidget);
  });

  testWidgets('the account button is badged with the needs-fix count', (
    tester,
  ) async {
    await tester.pumpWidget(_buildShellApp(needsFixCount: 3));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('shell-needs-fix-badge')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('shell-needs-fix-badge')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'a sync-status change does not force AppShell.build() to reconstruct '
    'unrelated chrome (the bottom nav) — HIGH-4: syncStatusProvider must be '
    'watched by the smaller widget that needs it (_ShellHeader/'
    '_OfflineBanner), not threaded through AppShell.build() itself',
    (tester) async {
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
            profileProvider.overrideWith(_CompleteProfileController.new),
            organizationProvider.overrideWith(
              _ExistingOrganizationController.new,
            ),
            // Dynamic (unlike overrideWithValue) so the test can push a new
            // value after the initial pump.
            syncStatusProvider.overrideWith(
              (ref) => ref.watch(_testSyncStatus),
            ),
            supersededNotificationProvider.overrideWith(
              (ref) => const Stream.empty(),
            ),
            rejectedNotificationProvider.overrideWith(
              (ref) => const Stream.empty(),
            ),
            syncNeedsFixCountProvider.overrideWith((ref) => Stream.value(0)),
          ],
          child: const BeekeepingitApp(),
        ),
      );
      await tester.pumpAndSettle();

      // AppShell.build() constructs a brand-new (non-const) NavigationBar
      // every time it runs, so capturing the mounted widget instance and
      // comparing identity across a provider change tells us whether
      // AppShell.build() itself re-ran — a widget-tree-observable proxy for
      // "did the whole shell rebuild", with no test-only instrumentation
      // needed in production code.
      final navBefore = tester.widget<NavigationBar>(
        find.byKey(const Key('shell-bottom-nav')),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(BeekeepingitApp)),
      );

      container.read(_testSyncStatus.notifier).state = const SyncStatus(
        connectivity: SyncConnectivity.offline,
        pendingCount: 3,
        hasError: true,
      );
      await tester.pump();

      final navAfter = tester.widget<NavigationBar>(
        find.byKey(const Key('shell-bottom-nav')),
      );
      expect(
        identical(navBefore, navAfter),
        isTrue,
        reason:
            'AppShell.build() re-ran (a new NavigationBar instance was '
            'constructed) even though nothing it directly needs changed — '
            'syncStatusProvider is being watched too high up the tree',
      );

      // Sanity: the new status DID reach the widgets that are actually
      // supposed to react to it.
      expect(find.byKey(const Key('shell-offline-banner')), findsOneWidget);
      expect(find.text('Sync error'), findsOneWidget);
    },
  );
}
