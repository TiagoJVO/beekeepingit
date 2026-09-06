import 'dart:async';

import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/core/widgets/field_action_button.dart';
import 'package:beekeepingit_client/features/account/account_screen.dart';
import 'package:beekeepingit_client/features/notifications/notification_events.dart';
import 'package:beekeepingit_client/features/notifications/notification_preferences_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/settings/notification_settings_repository.dart';
import 'package:beekeepingit_client/features/settings/sync_settings_repository.dart';
import 'package:beekeepingit_client/features/sync/sync_rejected_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/shell/sync_status.dart';
import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/a11y_matchers.dart';

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

/// A [ProfileController] that never resolves, so the screen stays on its
/// `loading` branch — the branch #769 must leave vertically centred.
class _LoadingProfileController extends ProfileController {
  @override
  Future<Profile> build() => Completer<Profile>().future;
}

/// A [ProfileController] that fails, so the screen stays on its `error`
/// branch — the other branch #769 must leave vertically centred.
class _FailingProfileController extends ProfileController {
  @override
  Future<Profile> build() async => throw Exception('boom');
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
      // Per-event notification-toggle list (#288): shares the same fake
      // prefs store as the settings sections above, so a tap on either
      // section is asserted against the same durable backing store.
      notificationPreferencesRepositoryProvider.overrideWithValue(
        NotificationPreferencesRepository(prefs: prefs),
      ),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      home: AccountScreen(),
    ),
  );
}

void main() {
  // #629 (FR-UX-1, FR-AX-1): the account screen's profile form floated both
  // its labels while the screens it links to wear theirs above.
  group('one field-label pattern (#629, FR-UX-1)', () {
    Future<void> pumpForm(WidgetTester tester) async {
      await tester.pumpWidget(
        _buildScreen(
          _FakeProfileController(
            _profile(name: 'Ana', email: 'ana@example.com'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'no field in the profile form paints a floating Material label',
      (tester) async {
        await pumpForm(tester);

        expectNoFloatingFieldLabels(tester, find.byType(Form));
      },
    );

    testWidgets('every label sits above its field, via LabeledField', (
      tester,
    ) async {
      await pumpForm(tester);

      for (final label in const ['Name', 'Preferred language']) {
        expect(
          find.descendant(
            of: find.byType(LabeledField),
            matching: find.text(label),
          ),
          findsOneWidget,
          reason: '"$label" must be a LabeledField label',
        );
      }
    });

    testWidgets(
      'the fields keep the accessible name their floating labels used to '
      'give them (FR-AX-1)',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pumpForm(tester);

        expectFieldAccessibleName(
          tester,
          const Key('account-name-field'),
          'Name',
        );
        expectFieldAccessibleName(
          tester,
          const Key('account-locale-field'),
          'Preferred language',
        );
        handle.dispose();
      },
    );
  });

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
    // The address is IdP-owned: the avatar header shows it, the form does
    // not offer it. PATCH would refuse it with 422 read_only.
    expect(find.byKey(const Key('account-email-field')), findsNothing);
    // The name still appears twice: once in the read-only avatar header (the
    // prototype's account card) and once in the editable field below. The
    // email appears ONCE — the header only — now that the field is gone.
    expect(find.text('Ana'), findsNWidgets(2));
    expect(find.text('ana@example.com'), findsOneWidget);
    // Presence/wiring only — not tapped: it opens a real browser tab via a
    // web-only platform call (see core/platform/external_link_platform.dart), matching how
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

  testWidgets('validates the empty name client-side', (tester) async {
    await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('account-name-field')), '');
    await tester.tap(find.byKey(const Key('account-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter your name.'), findsOneWidget);
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

  testWidgets('a profile written before #656 (locale "pt") opens the picker on '
      'Português and saves the supported tag (D-34)', (tester) async {
    String? submitted;
    final controller = _FakeProfileController(
      // The value every pre-#656 profile actually holds. The dropdown's
      // items are `en-GB`/`pt-PT` now, so an un-migrated `pt` reaching the
      // field unchanged is a Flutter assertion failure, not a soft
      // fallback — this test is what stops that regressing.
      _profile(locale: 'pt'),
      onSubmit: ({name, email, locale}) async {
        submitted = locale;
      },
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    // Shown as the language it always was, not reset to English.
    expect(find.text('Português'), findsOneWidget);

    await tester.tap(find.byKey(const Key('account-save-button')));
    await tester.pumpAndSettle();

    // ...and the next save writes the canonical tag back, so the legacy
    // value does not survive the round trip.
    expect(submitted, 'pt-PT');
  });

  testWidgets('surfaces a mocked 422 field error from the server', (
    tester,
  ) async {
    // The semantics tree has to be alive for the announcement assertions
    // below: a message that is painted without being announced, on a field
    // that still reads as valid, is exactly the #750 bug.
    final handle = tester.ensureSemantics();
    final controller = _FakeProfileController(
      _profile(),
      onSubmit: ({name, email, locale}) async {
        throw const ApiException(
          statusCode: 422,
          code: 'validation.failed',
          detail: 'one or more fields are invalid',
          fieldErrors: [
            ApiFieldError(
              field: 'name',
              code: 'invalid',
              message: 'name must not be empty',
            ),
          ],
        );
      },
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('account-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('name must not be empty'), findsOneWidget);

    // #750 (FR-AX-1, D-18): a server-supplied field error never passes
    // through `Form.validate()`, so the SDK's own announcement path never
    // sees it — the message node has to carry the live region itself, and
    // announce the MESSAGE only, not the field's name a second time (#629).
    expectLiveRegion(tester, find.text('name must not be empty'));
    expect(
      tester.getSemantics(find.text('name must not be empty')).label,
      'name must not be empty',
    );
    // And the field has to READ as failing. Only `forceErrorText` sets
    // `FormFieldState._errorText`, which is what `validationResult` is
    // derived from.
    expect(
      tester
          .getSemantics(find.byKey(const Key('account-name-field')))
          .getSemanticsData()
          .validationResult,
      SemanticsValidationResult.invalid,
    );
    handle.dispose();
  });

  // The counterpart of the block above: because `forceErrorText` makes the
  // field genuinely invalid, `Form.validate()` returns false while the
  // server's verdict stands — so the verdict MUST be dropped the moment the
  // user edits the value it judged (#649's rule, which profile and
  // organization already applied), or the Save button is dead for the rest
  // of the session (#750).
  testWidgets('editing the name after a server field error lets the next '
      'save through (#750, #649)', (tester) async {
    var submissions = 0;
    final controller = _FakeProfileController(
      _profile(),
      onSubmit: ({name, email, locale}) async {
        submissions++;
        if (submissions == 1) {
          throw const ApiException(
            statusCode: 422,
            code: 'validation.failed',
            detail: 'one or more fields are invalid',
            fieldErrors: [
              ApiFieldError(
                field: 'name',
                code: 'reserved',
                message: 'that name is reserved',
              ),
            ],
          );
        }
      },
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('account-name-field')),
      'Reserved',
    );
    await tester.tap(find.byKey(const Key('account-save-button')));
    await tester.pumpAndSettle();
    expect(submissions, 1);
    expect(find.text('that name is reserved'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('account-name-field')), 'Ana');
    await tester.pumpAndSettle();
    expect(find.text('that name is reserved'), findsNothing);

    await tester.tap(find.byKey(const Key('account-save-button')));
    await tester.pumpAndSettle();
    expect(submissions, 2);
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

  testWidgets(
    'every member sees BOTH the organization-details and stock-declarations '
    'actions, admin or not (#296/#298, FR-AP-9/FR-AP-10)',
    (tester) async {
      // Deliberately NOT gated behind isOrgAdminProvider, unlike manage-members
      // above: a non-admin can READ their organization's details and record
      // declarations. Only EDITING the organization's details is admin-only,
      // which the organization-details screen enforces on the fields themselves
      // (and the server enforces regardless of either).
      await tester.pumpWidget(
        _buildScreen(_FakeProfileController(_profile()), orgRole: 'user'),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('account-organization-details-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('account-stock-declarations-button')),
        findsOneWidget,
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

    testWidgets(
      'renders the per-event notification-toggle list inside the settings '
      'screen, backed by #82\'s preference contract (#288)',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(_FakeProfileController(_profile())),
        );
        await tester.pumpAndSettle();

        for (final eventKey in knownNotificationEvents) {
          expect(
            find.byKey(Key('settings-notification-event-toggle-$eventKey')),
            findsOneWidget,
          );
        }
      },
    );

    testWidgets('tapping a per-event toggle on the settings screen persists it '
        'through the same preferences store the notification engine reads '
        '(#82, #288)', (tester) async {
      final prefs = _FakeLocalPrefs();
      await tester.pumpWidget(
        _buildScreen(_FakeProfileController(_profile()), settingsPrefs: prefs),
      );
      await tester.pumpAndSettle();

      const toggleKey = Key(
        'settings-notification-event-toggle-$notificationEventSyncFailure',
      );
      await tester.ensureVisible(find.byKey(toggleKey));
      await tester.tap(find.byKey(toggleKey));
      await tester.pumpAndSettle();

      expect(
        NotificationPreferencesRepository(prefs: prefs)
            .isEnabled(notificationEventSyncFailure),
        isFalse,
      );
    });
  });

  // #769 (FR-UX-1): this screen hung its 480px column off a plain `Center`,
  // the shape #630 replaced on profile and new-organization. `Center` splits
  // the leftover vertical space into equal bands above and below the
  // content, so a screen shorter than its viewport starts mid-page instead
  // of under the header.
  group('layout at 375x812 (#769, FR-UX-1)', () {
    // A FORWARD guard, not a reproduction. Measured on this fixture, the
    // account screen's content is ~2285px tall, so at 375x812 (and at every
    // realistic viewport) the scroll view already fills the body and the
    // gap is 0px before AND after the change — the `Center` here was a
    // latent wrong idiom rather than a visible band. What this pins is that
    // the content never starts below the header, whatever the screen's
    // length becomes as sections are added or removed.
    testWidgets('the content starts immediately under the header', (
      tester,
    ) async {
      useViewport(tester);

      await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
      await tester.pumpAndSettle();

      final scroll = find.ancestor(
        of: find.byKey(const Key('account-name-field')),
        matching: find.byType(SingleChildScrollView),
      );
      // Guarded before getRect so a second wrapping scroll view fails here
      // rather than with an opaque "matched N widgets".
      expect(scroll, findsOneWidget);

      final headerBottom = tester.getRect(find.byType(AppBar)).bottom;
      final contentTop = tester.getRect(scroll).top;

      expect(
        contentTop - headerBottom,
        // Bounded at both ends: below catches the dead band, above catches
        // content rendering up over the header.
        inInclusiveRange(0.0, 1.0),
        reason:
            'the account screen must start its content just under the header '
            'like every other screen; it started '
            '${contentTop - headerBottom}px below it',
      );
    });

    // The other half of the change: only the `data` branch is top-aligned.
    // A lone spinner still belongs in the middle of the body, so this fails
    // if the alignment wrapper is ever hoisted above `profileAsync.when`.
    testWidgets('the loading spinner stays vertically centred', (tester) async {
      useViewport(tester);

      await tester.pumpWidget(_buildScreen(_LoadingProfileController()));
      await tester.pump();

      final spinner = find.byType(CircularProgressIndicator);
      expect(spinner, findsOneWidget);

      final headerBottom = tester.getRect(find.byType(AppBar)).bottom;
      // READ from the test view rather than assuming kHandsetViewport, the
      // rule `expectWithinThumbReach` documents in a11y_matchers.dart: an
      // assertion that hardcodes 812 silently measures against the wrong
      // centre the moment a caller passes `useViewport` another size.
      final viewportHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final bodyCentre = (headerBottom + viewportHeight) / 2;

      expect(
        (tester.getCenter(spinner).dy - bodyCentre).abs(),
        lessThan(1.0),
        reason:
            'a lone spinner must stay in the middle of the body; it '
            'rendered at ${tester.getCenter(spinner).dy}, body centre '
            '$bodyCentre',
      );
    });

    // Same for the error branch — AC 5 names spinners AND error messages.
    testWidgets('the error message stays vertically centred', (tester) async {
      useViewport(tester);

      await tester.pumpWidget(_buildScreen(_FailingProfileController()));
      await tester.pumpAndSettle();

      final message = find.textContaining('boom');
      expect(message, findsOneWidget);

      final headerBottom = tester.getRect(find.byType(AppBar)).bottom;
      final viewportHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final bodyCentre = (headerBottom + viewportHeight) / 2;

      expect(
        (tester.getCenter(message).dy - bodyCentre).abs(),
        lessThan(1.0),
        reason:
            'a lone error message must stay in the middle of the body; it '
            'rendered at ${tester.getCenter(message).dy}, body centre '
            '$bodyCentre',
      );
    });

    // The guard that actually FAILS if `Align(topCenter)` is reverted to
    // `Center` on this screen. 375x3000 is not a device — it is the smallest
    // round viewport taller than the ~2285px this screen's stacked sections
    // measure, and nothing shorter can tell the two alignments apart here
    // (which is exactly why the 375x812 case above is only a forward guard).
    // Under `Center` the leftover 659px splits into two ~329.5px bands; under
    // `Align(topCenter)` it all falls below the content.
    testWidgets('the content stays under the header on a viewport taller '
        'than the screen itself', (tester) async {
      useViewport(tester, size: const Size(375, 3000));

      await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
      await tester.pumpAndSettle();

      final scroll = find.ancestor(
        of: find.byKey(const Key('account-name-field')),
        matching: find.byType(SingleChildScrollView),
      );
      expect(scroll, findsOneWidget);

      final headerBottom = tester.getRect(find.byType(AppBar)).bottom;
      final contentTop = tester.getRect(scroll).top;

      expect(
        contentTop - headerBottom,
        inInclusiveRange(0.0, 1.0),
        reason:
            'once the viewport is taller than the content, a plain `Center` '
            'splits the slack into equal bands; the content started '
            '${contentTop - headerBottom}px below the header',
      );
    });
  });
}
