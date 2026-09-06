/// Where a confirmation toast is allowed to land (#631, FR-UX-2).
///
/// The toast is the app's only "your save worked" signal, and it is shown from
/// 56 `ScaffoldMessenger.showSnackBar` call sites that none of them position —
/// the enclosing `Scaffold` does. So this pins the placement contract once, on
/// the real app shell, at the layer that actually decides it, rather than 56
/// times at the call sites (where the 57th would reintroduce the bug).
///
/// The two acceptance criteria pull against each other, which is the whole
/// difficulty: a toast can only clear the bottom navigation by moving up, and
/// every pixel it moves up is content it covers instead. Both directions are
/// asserted here.
library;

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/notifications/notification_check_provider.dart';
import 'package:beekeepingit_client/features/notifications/notification_dedup_store.dart';
import 'package:beekeepingit_client/features/notifications/notification_preferences_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/settings/notification_settings_repository.dart';
import 'package:beekeepingit_client/features/sync/sync_rejected_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/shell/sync_status.dart';
import 'package:beekeepingit_client/theming/brand_dimens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../widget_test.dart' show FakeDeviceLocationService;

/// Fixtures mirroring app_shell_test.dart's — kept local rather than imported
/// because that file's are private to it, the convention this suite already
/// follows.
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

class _FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> _store = {};

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

const _apiary = Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3);

Widget _buildApp() {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      deviceLocationServiceProvider.overrideWithValue(
        const FakeDeviceLocationService(),
      ),
      apiariesStreamProvider.overrideWith(
        (ref) => Stream.value(const [_apiary]),
      ),
      apiaryByIdProvider.overrideWith(
        (ref, apiaryId) =>
            Stream.value(apiaryId == _apiary.id ? _apiary : null),
      ),
      apiaryCountersProvider.overrideWith(
        (ref, apiaryId) => Stream.value(const <ApiaryCounter>[]),
      ),
      activitiesStreamProvider.overrideWith(
        (ref) => Stream.value(const <Activity>[]),
      ),
      activitiesByApiaryProvider.overrideWith(
        (ref, apiaryId) => Stream.value(const <Activity>[]),
      ),
      journeysStreamProvider.overrideWith(
        (ref) => Stream.value(const <Journey>[]),
      ),
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
      notificationDedupStoreProvider.overrideWithValue(
        NotificationDedupStore(prefs: _FakeLocalPrefs()),
      ),
      notificationPreferencesRepositoryProvider.overrideWithValue(
        NotificationPreferencesRepository(prefs: _FakeLocalPrefs()),
      ),
      notificationSettingsRepositoryProvider.overrideWithValue(
        NotificationSettingsRepository(prefs: _FakeLocalPrefs()),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      syncStatusProvider.overrideWithValue(
        const SyncStatus(
          connectivity: SyncConnectivity.online,
          pendingCount: 0,
        ),
      ),
      supersededNotificationProvider.overrideWith(
        (ref) => const Stream.empty(),
      ),
      rejectedNotificationProvider.overrideWith((ref) => const Stream.empty()),
      syncNeedsFixCountProvider.overrideWith((ref) => Stream.value(0)),
    ],
    child: const BeekeepingitApp(),
  );
}

void main() {
  /// A field phone with an iOS-style home-indicator inset, so the navigation
  /// bar measures its real height (80 + safe area) rather than a test-only 80:
  /// the toast's clearance has to hold against whatever the bar actually is.
  void useFieldPhone(WidgetTester tester, {double textScale = 1}) {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    tester.view.viewPadding = const FakeViewPadding(bottom: 34);
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  /// The toast's *visible* bar. `SnackBar` wraps its [Material] in the
  /// safe-area/margin padding that positions it, so the SnackBar's own rect
  /// would measure that padding too and hide the very gap under test.
  Rect toastRect(WidgetTester tester) => tester.getRect(
    find
        .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
        .first,
  );

  /// Raises a toast the way all 56 call sites do — hand it to the messenger
  /// from whatever screen is up, and let the `Scaffold` place it.
  Future<void> showToast(WidgetTester tester) async {
    ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
        .showSnackBar(const SnackBar(content: Text('Apiary saved')));
    await tester.pumpAndSettle();
  }

  Future<void> openApiaryDetail(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apiary-a1')));
    await tester.pumpAndSettle();
  }

  for (final textScale in [1.0, 2.0]) {
    testWidgets(
      'a toast clears the bottom navigation instead of resting on it, at '
      '${textScale}x text (#631, FR-UX-2)',
      (tester) async {
        useFieldPhone(tester, textScale: textScale);
        await tester.pumpWidget(_buildApp());
        await tester.pumpAndSettle();

        await showToast(tester);

        final navigation = tester.getRect(
          find.byKey(const Key('shell-bottom-nav')),
        );
        final toast = toastRect(tester);

        expect(
          toast.overlaps(navigation),
          isFalse,
          reason: 'the navigation bar must not be drawn over the toast',
        );
        // Not merely "does not overlap": flush on the bar's top edge is the
        // reported symptom — a plum-950 toast abutting the plum-800 navigation
        // reads as one block whose lower half is the navigation.
        expect(
          navigation.top - toast.bottom,
          greaterThanOrEqualTo(BrandDimens.gapToastNav),
          reason: 'the toast must sit clear of the navigation bar',
        );
      },
    );

    testWidgets(
      'a toast does not cover the change history it is confirming a save to, '
      'at ${textScale}x text (#631, FR-UX-2)',
      (tester) async {
        useFieldPhone(tester, textScale: textScale);
        await tester.pumpWidget(_buildApp());
        await tester.pumpAndSettle();
        await openApiaryDetail(tester);

        // Scroll to the end: the resting state where the content a save
        // confirmation reports on — the apiary's change history, the last card
        // on the screen — sits closest to the toast.
        await tester.drag(
          find.byKey(const Key('apiary-detail-header')),
          const Offset(0, -3000),
        );
        await tester.pumpAndSettle();

        await showToast(tester);

        expect(
          toastRect(
            tester,
          ).overlaps(tester.getRect(find.byKey(const Key('history-section')))),
          isFalse,
          reason:
              'the toast must stay inside the bottom band the screen '
              'reserves, not clip the card it is reporting on',
        );
      },
    );
  }

  testWidgets(
    'a toast is not lifted up into the content to clear the navigation '
    '(#631, FR-UX-2)',
    (tester) async {
      useFieldPhone(tester);
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
      await tester.pumpAndSettle();

      await showToast(tester);

      final navigation = tester.getRect(
        find.byKey(const Key('shell-bottom-nav')),
      );
      // The Apiaries tab root carries the shell FAB, which is what makes this
      // worth asserting: `SnackBarBehavior.floating` — the one-line theme fix
      // this looks like it wants — makes Flutter anchor the toast above the
      // *FAB*, measured 194px up into the list a save has just returned to.
      // Clearing the navigation by covering the content is the other half of
      // the bug, not a fix for it.
      expect(
        navigation.top - toastRect(tester).top,
        lessThanOrEqualTo(BrandDimens.scrollBottomInset),
        reason: 'the toast must stay within the bottom band screens reserve',
      );
    },
  );

  testWidgets(
    'a screen with no bottom navigation gets no phantom offset (#631, '
    'FR-UX-2)',
    (tester) async {
      useFieldPhone(tester);
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      // Account settings is outside the shell — no bottom navigation, so
      // nothing for a toast to clear.
      await tester.tap(find.byKey(const Key('shell-account-button')));
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);

      await showToast(tester);

      // A fixed SnackBar owns the safe-area inset itself, so its bar reaches
      // the window bottom here. Any clearance at all would be a
      // navigation-sized offset applied where there is no navigation, leaving
      // the toast hovering over a gap.
      expect(
        toastRect(tester).bottom,
        closeTo(tester.view.physicalSize.height, 1),
        reason: 'the clearance must come from the screen\'s own bottom chrome',
      );
    },
  );
}
