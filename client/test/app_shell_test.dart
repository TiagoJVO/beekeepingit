import 'dart:async';

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/sync/sync_rejected_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
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

/// An always-empty [LocalStoreEngine] fake backing [syncRejectedRepositoryProvider]
/// in these shell tests — so navigating into `/sync-needs-fix` (the needs-fix
/// banner's own Fix action, #379) resolves to a real, renderable screen
/// (its empty state) rather than hanging on a real, never-configured
/// PowerSync database the way an unoverridden provider chain would.
/// [syncNeedsFixCountProvider] is overridden independently (see
/// `_buildShellApp`'s own `needsFixCount`/`needsFixCountStream`) — the two
/// aren't wired together here since these tests only care that the badge/
/// banner react to a count and that the Fix action lands somewhere real, not
/// that the two providers agree on a specific number.
class _EmptyRejectedStore implements LocalStoreEngine {
  const _EmptyRejectedStore();

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) {
    final isCount = sql.toUpperCase().contains('COUNT(*)');
    return Stream.value(
      isCount
          ? [
              {'c': 0},
            ]
          : const [],
    );
  }

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}

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
  Future<void> clear() async {}
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
  // Overrides the fixed needsFixCount value with a live stream a test can
  // push multiple values through after the initial pump (#379: the
  // needs-fix banner's own auto-clear regression guard needs a 1-then-0
  // transition, which a one-shot needsFixCount can't express).
  Stream<int>? needsFixCountStream,
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
      // The main Activities tab (#43) now renders real content in place of
      // the old ComingSoonScreen placeholder — overridden so switching to
      // it in these shell-focused tests doesn't hang on the real
      // (never-resolving here) activitiesRepositoryProvider chain.
      activitiesStreamProvider.overrideWith(
        (ref) => Stream.value(const <Activity>[]),
      ),
      // The main Journeys tab (#45) similarly now renders real content in
      // place of the old ComingSoonScreen placeholder — same rationale as
      // the activities override above.
      journeysStreamProvider.overrideWith(
        (ref) => Stream.value(const <Journey>[]),
      ),
      // The main Todos tab (#53) similarly now renders real content in
      // place of the old ComingSoonScreen placeholder — same rationale as
      // the activities/journeys overrides above.
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      // The full todo create/edit form's assignee picker (#293, now also
      // reachable from the FAB flows below since #389 retired #52's
      // quick-create sheet) watches memberNamesProvider — overridden so
      // opening it in these shell-focused tests doesn't attempt a real
      // fetch, matching todo_form_screen_test.dart's/
      // apiary_detail_screen_test.dart's own convention.
      memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
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
        (ref) => needsFixCountStream ?? Stream.value(needsFixCount),
      ),
      // See _EmptyRejectedStore's own doc: makes /sync-needs-fix (the needs-
      // fix banner's Fix destination, #379) a renderable real screen in
      // these shell tests instead of hanging on a real PowerSync database.
      syncRejectedRepositoryProvider.overrideWith(
        (ref) async => SyncRejectedRepository(const _EmptyRejectedStore()),
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

    // The Activities tab (#43) now renders real content — with the
    // overridden empty activities stream (see _buildShellApp), that's its
    // own empty state, not the old ComingSoonScreen placeholder text.
    expect(find.text('No activities yet.'), findsOneWidget);
    var nav = tester.widget<NavigationBar>(
      find.byKey(const Key('shell-bottom-nav')),
    );
    expect(nav.selectedIndex, 1);

    await tester.tap(find.byKey(const Key('shell-tab-todos')));
    await tester.pumpAndSettle();

    // The Todos tab (#53) now renders real content — with the overridden
    // empty todos stream (see _buildShellApp), that's its own empty state,
    // not the old ComingSoonScreen placeholder text.
    expect(find.text('No todos yet.'), findsOneWidget);
    nav = tester.widget<NavigationBar>(
      find.byKey(const Key('shell-bottom-nav')),
    );
    expect(nav.selectedIndex, 3);
  });

  testWidgets(
    'switching tabs resets the target tab to its root — no scope carried over '
    '(#345, FR-UX-2)',
    (tester) async {
      await tester.pumpWidget(
        _buildShellApp(
          apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)],
        ),
      );
      await tester.pumpAndSettle();

      // Push into the Apiaries branch's detail/form stack. The Apiaries tab's
      // two quick actions live behind the single "Actions" speed dial now
      // (#347) — expand it, then pick "New apiary". The form is left EMPTY so
      // the unsaved-changes guard (#345) doesn't fire on the tab switch below.
      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);

      // Switch away to another tab and back.
      await tester.tap(find.byKey(const Key('shell-tab-journeys')));
      await tester.pumpAndSettle();
      expect(
        find.text('No journeys yet. Tap “New journey” to create one.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
      await tester.pumpAndSettle();

      // Scope reset (#345, the product owner's directed change): switching
      // tabs no longer carries over the previously-active tab's scoped state.
      // `goBranch(index, initialLocation: true)` resets the target branch to
      // its root, so returning to Apiaries lands on the LIST, not the
      // still-pushed New-apiary form it was left on.
      expect(find.byKey(const Key('apiary-name-field')), findsNothing);
      expect(find.text('Serra Norte'), findsOneWidget);
    },
  );

  testWidgets('re-tapping the active tab also resets it to root (#345)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildShellApp(
        apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);

    // Re-tap the already-active Apiaries tab.
    await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('apiary-name-field')), findsNothing);
    expect(find.text('Serra Norte'), findsOneWidget);
  });

  group('unsaved-changes guard (#345, FR-UX-1/FR-UX-2/FR-AX-1, D-18)', () {
    testWidgets(
      'switching tabs with unsaved edits prompts confirm-discard; Keep editing '
      'stays on the form',
      (tester) async {
        await tester.pumpWidget(_buildShellApp());
        await tester.pumpAndSettle();

        // Open the New-apiary form and dirty it.
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          'Serra Nova',
        );
        await tester.pump();

        // Attempt to switch tabs — the guard intercepts.
        await tester.tap(find.byKey(const Key('shell-tab-journeys')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('discard-changes-dialog')), findsOneWidget);

        // "Keep editing" dismisses and leaves us on the (still-dirty) form.
        await tester.tap(find.byKey(const Key('discard-changes-cancel')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('discard-changes-dialog')), findsNothing);
        expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
        expect(find.text('Serra Nova'), findsOneWidget);
        // Still on the Apiaries tab.
        final nav = tester.widget<NavigationBar>(
          find.byKey(const Key('shell-bottom-nav')),
        );
        expect(nav.selectedIndex, 0);
      },
    );

    testWidgets(
      'switching tabs with unsaved edits and confirming Discard leaves the form',
      (tester) async {
        await tester.pumpWidget(_buildShellApp());
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          'Serra Nova',
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('shell-tab-journeys')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('discard-changes-dialog')), findsOneWidget);

        await tester.tap(find.byKey(const Key('discard-changes-confirm')));
        await tester.pumpAndSettle();

        // Discarded: we're on the Journeys tab, the form is gone.
        expect(find.byKey(const Key('apiary-name-field')), findsNothing);
        final nav = tester.widget<NavigationBar>(
          find.byKey(const Key('shell-bottom-nav')),
        );
        expect(nav.selectedIndex, 2);
      },
    );

    testWidgets('a pristine (untouched) form navigates freely with no prompt', (
      tester,
    ) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);

      // No edits made — switching tabs must NOT prompt.
      await tester.tap(find.byKey(const Key('shell-tab-journeys')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discard-changes-dialog')), findsNothing);
      expect(find.byKey(const Key('apiary-name-field')), findsNothing);
    });

    testWidgets(
      'the shell back button on a dirty form prompts confirm-discard',
      (tester) async {
        await tester.pumpWidget(_buildShellApp());
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          'Serra Nova',
        );
        await tester.pump();

        // The shell's own back button pops the branch navigator via maybePop,
        // which the form's PopScope guard intercepts (#345).
        await tester.tap(find.byKey(const Key('shell-back-button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('discard-changes-dialog')), findsOneWidget);

        await tester.tap(find.byKey(const Key('discard-changes-cancel')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
      },
    );
  });

  testWidgets(
    'the Apiaries "Actions" speed dial expands to the new-apiary option, which '
    'navigates to the new-apiary form (#347)',
    (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      // Collapsed: a single "Actions" control, not the raw quick-add FABs.
      expect(
        find.byKey(const Key('actions-speed-dial-toggle')),
        findsOneWidget,
      );
      expect(find.text('Actions'), findsOneWidget);

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Add apiary'), findsOneWidget);

      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
      expect(find.text('New apiary'), findsOneWidget);
    },
  );

  testWidgets(
    'the Actions control hides while the apiaries map view is showing, and returns when back on the list (#35)',
    (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('actions-speed-dial-toggle')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('apiaries-view-map-button')));
      await tester.pumpAndSettle();

      // The whole Actions control is suppressed on the map view — the toggle
      // and every option it would reveal live in the same _ShellFab return.
      expect(find.byKey(const Key('actions-speed-dial-toggle')), findsNothing);
      expect(find.byKey(const Key('shell-fab-new-todo')), findsNothing);

      await tester.tap(find.byKey(const Key('apiaries-view-list-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('actions-speed-dial-toggle')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'tabs without their own quick-add action have no FAB (Activities/Assistant)',
    (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      // Activities has no FAB (its create entry point lives on the apiary
      // detail page, since an activity always needs an apiary context
      // first); Assistant has no real screen yet. Journeys (#45) and Todos
      // (#52) DO have their own FAB — covered by their own tests below, not
      // this one.
      for (final route in ['activities', 'assistant']) {
        await tester.tap(find.byKey(Key('shell-tab-$route')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('shell-fab')),
          findsNothing,
          reason: '$route tab should not show the contextual FAB',
        );
        expect(
          find.byKey(const Key('actions-speed-dial-toggle')),
          findsNothing,
          reason: '$route tab should not show the Actions control',
        );
      }
    },
  );

  testWidgets('the Journeys tab shows its own "New journey" FAB (#45)', (
    tester,
  ) async {
    await tester.pumpWidget(_buildShellApp());
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('shell-tab-journeys')));
    await tester.pumpAndSettle();

    // A single action → rendered as a direct FAB (no "Actions" speed dial),
    // and no second action exists on Journeys — only Apiaries has one (#52).
    expect(find.byKey(const Key('shell-fab')), findsOneWidget);
    expect(find.byKey(const Key('actions-speed-dial-toggle')), findsNothing);
    expect(find.byKey(const Key('shell-fab-new-todo')), findsNothing);
  });

  group('create-todo FAB (#52/#389, FR-TD-1, FR-UX-1, FR-UX-2)', () {
    testWidgets('the Todos tab shows its own "New todo" FAB', (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell-tab-todos')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-fab')), findsOneWidget);
      expect(find.text('New todo'), findsOneWidget);
      expect(find.byKey(const Key('actions-speed-dial-toggle')), findsNothing);
    });

    testWidgets(
      'tapping the Todos tab FAB routes to the full create form (#389), '
      'with no apiary pre-selected',
      (tester) async {
        await tester.pumpWidget(_buildShellApp());
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('shell-tab-todos')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
        // The header title, from the pushed `todoNew` route (canGoBack is
        // now true, so the FAB itself — which also says "New todo" — is
        // gone, per _ShellFab's own doc comment).
        expect(find.text('New todo'), findsOneWidget);
        // "No apiary" (todo-apiary-option-none) renders selected — the
        // apiary picker's own default when no `?apiaryId=` was passed.
        expect(
          find.descendant(
            of: find.byKey(const Key('todo-apiary-option-none')),
            matching: find.byIcon(Icons.radio_button_checked),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the Apiaries tab "Actions" speed dial reveals BOTH its "Add apiary" '
      'and "New todo" options when expanded (#52, #347)',
      (tester) async {
        await tester.pumpWidget(_buildShellApp());
        await tester.pumpAndSettle();

        // Collapsed: neither option is in the tree yet.
        expect(find.byKey(const Key('shell-fab-new-apiary')), findsNothing);
        expect(find.byKey(const Key('shell-fab-new-todo')), findsNothing);

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('shell-fab-new-apiary')), findsOneWidget);
        expect(find.text('Add apiary'), findsOneWidget);
        expect(find.byKey(const Key('shell-fab-new-todo')), findsOneWidget);
        expect(find.text('New todo'), findsOneWidget);
      },
    );

    testWidgets(
      'the "Add apiary" option still navigates to the new-apiary form '
      'unchanged (regression guard)',
      (tester) async {
        await tester.pumpWidget(_buildShellApp());
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
        expect(find.text('New apiary'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping the Apiaries tab "New todo" option routes to the full create '
      'form (#389), with no apiary pre-selected',
      (tester) async {
        await tester.pumpWidget(_buildShellApp());
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-todo')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
        // The header title, from the pushed `todoNew` route (canGoBack is
        // now true, so the FAB itself — which also says "New todo" — is
        // gone, per _ShellFab's own doc comment).
        expect(find.text('New todo'), findsOneWidget);
        // "No apiary" (todo-apiary-option-none) renders selected — the
        // apiary picker's own default when no `?apiaryId=` was passed.
        expect(
          find.descendant(
            of: find.byKey(const Key('todo-apiary-option-none')),
            matching: find.byIcon(Icons.radio_button_checked),
          ),
          findsOneWidget,
        );
      },
    );
  });

  testWidgets(
    'the header has no back button at each tab root, but shows one after pushing into a stack',
    (tester) async {
      await tester.pumpWidget(_buildShellApp());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-back-button')), findsNothing);

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
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

  testWidgets('the remaining 1 placeholder tab renders without error '
      '(Activities, Journeys and Todos are real content since #43/#45/#53 — '
      'see the dedicated switching-tabs test above)', (tester) async {
    await tester.pumpWidget(_buildShellApp());
    await tester.pumpAndSettle();

    const expected = {'assistant': 'Assistant — coming soon'};
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
      // #426: the error banner must not leak the sync technology ("PowerSync")
      // to the beekeeper — it reads as plain, non-technical copy.
      expect(
        find.text("Some changes couldn't sync yet — retrying."),
        findsOneWidget,
      );
      expect(find.textContaining('PowerSync'), findsNothing);
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

  group('needs-fix banner (#379: replaces the one-shot rejected-change toast — '
      'see app_shell.dart\'s _listenForSyncToasts doc for why)', () {
    testWidgets('is hidden when nothing needs fixing', (tester) async {
      await tester.pumpWidget(_buildShellApp(needsFixCount: 0));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-needs-fix-banner')), findsNothing);
    });

    testWidgets(
      'shows the rejected-changes notice when something needs fixing',
      (tester) async {
        await tester.pumpWidget(_buildShellApp(needsFixCount: 2));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('shell-needs-fix-banner')), findsOneWidget);
        expect(
          find.text('One of your changes was rejected and needs fixing.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'auto-clears the moment the count drops to zero — no reload needed '
      '(#379\'s stale-banner regression: the old toast never hid itself '
      'on its own)',
      (tester) async {
        final controller = StreamController<int>();
        addTearDown(controller.close);
        controller.add(1);

        await tester.pumpWidget(
          _buildShellApp(needsFixCountStream: controller.stream),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('shell-needs-fix-banner')), findsOneWidget);

        controller.add(0);
        await tester.pump();
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('shell-needs-fix-banner')), findsNothing);
      },
    );

    testWidgets(
      'tapping the banner\'s Fix action navigates to the needs-fix list '
      'from a non-default tab (#379: the old toast\'s Fix action captured '
      'the tab-active-at-toast-time context and went stale off it)',
      (tester) async {
        await tester.pumpWidget(_buildShellApp(needsFixCount: 1));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('shell-tab-journeys')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('shell-needs-fix-banner')), findsOneWidget);

        await tester.tap(find.byKey(const Key('shell-needs-fix-banner-fix')));
        await tester.pumpAndSettle();

        // Left the shell entirely, landed on the standalone needs-fix
        // screen (its own empty state here — the fake repository backing
        // it in this harness has no rows).
        expect(find.byKey(const Key('shell-bottom-nav')), findsNothing);
        expect(find.byKey(const Key('needs-fix-empty')), findsOneWidget);
      },
    );
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
