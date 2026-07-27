import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/core/widgets/field_action_button.dart';
import 'package:beekeepingit_client/features/account/account_screen.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/settings/notification_settings_repository.dart';
import 'package:beekeepingit_client/features/settings/sync_settings_repository.dart';
import 'package:beekeepingit_client/features/sync/sync_rejected_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/shell/sync_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalPrefs] fake — same convention as
/// `profile_repository_test.dart`/`auth_controller_test.dart` — backing the
/// settings sections' repositories (#81) so tests can assert real
/// persistence without touching browser localStorage.
class _FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> _store = {};

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

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

Widget _buildScreen(
  ProfileController controller, {
  String orgRole = 'admin',
  SyncStatus? syncStatus,
  Future<void> Function()? syncNow,
  int needsFixCount = 0,
  LocalPrefs? settingsPrefs,
}) {
  final prefs = settingsPrefs ?? _FakeLocalPrefs();
  return ProviderScope(
    overrides: [
      profileProvider.overrideWith(() => controller),
      isAuthenticatedProvider.overrideWithValue(true),
      organizationProvider.overrideWith(
        () => _FixedOrganizationController(role: orgRole),
      ),
      // Isolates the screen's new Sync section (#58) from a real PowerSync
      // database/network — same convention as app_shell_test.dart's
      // _buildShellApp override.
      syncStatusProvider.overrideWithValue(
        syncStatus ??
            const SyncStatus(
              connectivity: SyncConnectivity.online,
              pendingCount: 0,
            ),
      ),
      syncNowProvider.overrideWithValue(syncNow ?? () async {}),
      // The Sync section's needs-fix truthfulness fix (#379): isolated the
      // same way as syncStatusProvider above.
      syncNeedsFixCountProvider.overrideWith(
        (ref) => Stream.value(needsFixCount),
      ),
      // Settings sections (#81): a fake, in-memory LocalPrefs so persistence
      // is asserted for real without touching browser localStorage.
      syncSettingsRepositoryProvider.overrideWithValue(
        SyncSettingsRepository(prefs: prefs),
      ),
      notificationSettingsRepositoryProvider.overrideWithValue(
        NotificationSettingsRepository(prefs: prefs),
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
    // Name + email now appear twice: once in the read-only avatar header
    // (the prototype's account card) and once in the editable field below.
    expect(find.text('Ana'), findsNWidgets(2));
    expect(find.text('ana@example.com'), findsNWidgets(2));
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

  testWidgets(
    'the back button has a tooltip/semantic label (matches the shell\'s '
    'own back button)',
    (tester) async {
      await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
      await tester.pumpAndSettle();

      final button = tester.widget<IconButton>(
        find.byKey(const Key('account-back-button')),
      );
      expect(button.tooltip, isNotNull);
      expect(button.tooltip, isNotEmpty);
    },
  );

  group('Sync section (#58)', () {
    testWidgets('shows the current status and pending-change count', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(
          _FakeProfileController(_profile()),
          syncStatus: const SyncStatus(
            connectivity: SyncConnectivity.offline,
            pendingCount: 4,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Status: Offline'), findsOneWidget);
      expect(find.text('4 changes waiting to sync.'), findsOneWidget);
      expect(find.byKey(const Key('account-sync-now-button')), findsOneWidget);
    });

    testWidgets('shows "everything is synced" when nothing is pending', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(
          _FakeProfileController(_profile()),
          syncStatus: const SyncStatus(
            connectivity: SyncConnectivity.online,
            pendingCount: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Status: Online'), findsOneWidget);
      expect(find.text('Everything is synced.'), findsOneWidget);
    });

    testWidgets('tapping "Sync now" requests a manual sync and confirms it', (
      tester,
    ) async {
      var called = false;
      await tester.pumpWidget(
        _buildScreen(
          _FakeProfileController(_profile()),
          syncNow: () async {
            called = true;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('account-sync-now-button')),
      );
      await tester.tap(find.byKey(const Key('account-sync-now-button')));
      await tester.pumpAndSettle();

      expect(called, isTrue);
      expect(find.text('Sync requested.'), findsOneWidget);
    });

    testWidgets(
      'does NOT claim "Everything is synced." when there are rejected '
      'writes awaiting a fix, even though PowerSync\'s own upload queue is '
      'empty (#379: a rejected op already left pendingCount, so the plain '
      'pending-count line was misleadingly claiming full sync)',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(
            _FakeProfileController(_profile()),
            syncStatus: const SyncStatus(
              connectivity: SyncConnectivity.online,
              pendingCount: 0,
            ),
            needsFixCount: 1,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Everything is synced.'), findsNothing);
        expect(
          find.text('1 change was rejected and needs fixing.'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('account-needs-fix-button')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'shows the plural needs-fix status line for more than one rejection',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(_FakeProfileController(_profile()), needsFixCount: 3),
        );
        await tester.pumpAndSettle();

        expect(
          find.text('3 changes were rejected and need fixing.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'reverts to the plain pending-count line once needsFixCount returns '
      'to zero (regression guard: the old "Everything is synced." line '
      'still returns for the genuinely-fully-synced case)',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(
            _FakeProfileController(_profile()),
            syncStatus: const SyncStatus(
              connectivity: SyncConnectivity.online,
              pendingCount: 0,
            ),
            needsFixCount: 0,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Everything is synced.'), findsOneWidget);
        expect(find.byKey(const Key('account-needs-fix-button')), findsNothing);
      },
    );

    testWidgets('a failed manual sync surfaces a retry-able error toast', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(
          _FakeProfileController(_profile()),
          syncNow: () async {
            throw Exception('network unreachable');
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(const Key('account-sync-now-button')),
      );
      await tester.tap(find.byKey(const Key('account-sync-now-button')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not sync right now'), findsOneWidget);
      // The button is re-enabled afterwards, so the user can retry (AC: "a
      // failed sync can be retried").
      final button = tester.widget<SecondaryActionButton>(
        find.byKey(const Key('account-sync-now-button')),
      );
      expect(button.onPressed, isNotNull);
      expect(button.busy, isFalse);
    });

    testWidgets('shows the auto-sync setting, defaulting to enabled (#81)', (
      tester,
    ) async {
      await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
      await tester.pumpAndSettle();

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('settings-auto-sync-toggle')),
      );
      expect(toggle.value, isTrue);
      expect(find.text('Auto-sync'), findsOneWidget);
    });

    testWidgets(
      'tapping the auto-sync toggle persists the new value (honored by '
      'the EPIC-06 sync layer via autoSyncEnabledProvider, #81)',
      (tester) async {
        final prefs = _FakeLocalPrefs();
        await tester.pumpWidget(
          _buildScreen(
            _FakeProfileController(_profile()),
            settingsPrefs: prefs,
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('settings-auto-sync-toggle')),
        );
        await tester.tap(find.byKey(const Key('settings-auto-sync-toggle')));
        await tester.pumpAndSettle();

        expect(
          SyncSettingsRepository(prefs: prefs).isAutoSyncEnabled(),
          isFalse,
        );
        final toggle = tester.widget<SwitchListTile>(
          find.byKey(const Key('settings-auto-sync-toggle')),
        );
        expect(toggle.value, isFalse);
      },
    );

    testWidgets(
      'reflects a previously-persisted auto-sync-disabled preference (#81)',
      (tester) async {
        final prefs = _FakeLocalPrefs();
        SyncSettingsRepository(prefs: prefs).setAutoSyncEnabled(false);

        await tester.pumpWidget(
          _buildScreen(
            _FakeProfileController(_profile()),
            settingsPrefs: prefs,
          ),
        );
        await tester.pumpAndSettle();

        final toggle = tester.widget<SwitchListTile>(
          find.byKey(const Key('settings-auto-sync-toggle')),
        );
        expect(toggle.value, isFalse);
      },
    );
  });

  group('Notifications section (#81)', () {
    testWidgets('shows the section and the master switch, defaulting to '
        'enabled', (tester) async {
      await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
      await tester.pumpAndSettle();

      expect(find.text('Notifications'), findsOneWidget);
      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('settings-notifications-enabled-toggle')),
      );
      expect(toggle.value, isTrue);
    });

    testWidgets(
      'tapping the master switch persists the new value (honored by the '
      'notification engine, #82)',
      (tester) async {
        final prefs = _FakeLocalPrefs();
        await tester.pumpWidget(
          _buildScreen(
            _FakeProfileController(_profile()),
            settingsPrefs: prefs,
          ),
        );
        await tester.pumpAndSettle();

        await tester.ensureVisible(
          find.byKey(const Key('settings-notifications-enabled-toggle')),
        );
        await tester.tap(
          find.byKey(const Key('settings-notifications-enabled-toggle')),
        );
        await tester.pumpAndSettle();

        expect(
          NotificationSettingsRepository(prefs: prefs).isNotificationsEnabled(),
          isFalse,
        );
      },
    );

    testWidgets('provides the container the per-event notification-toggle list '
        'renders into (#288)', (tester) async {
      await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('settings-notification-events-slot')),
        findsOneWidget,
      );
    });
  });
}
