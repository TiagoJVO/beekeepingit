import 'dart:async';
import 'dart:convert';

import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/organization/organization_details_screen.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/a11y_matchers.dart';
import '../../support/bottom_chrome.dart';

/// FR-ONB-2 + FR-AP-9 (#296): the organization-details screen — the
/// re-enterable settings view of an organization that already exists (name,
/// address, registration number), as distinct from `organization_screen.dart`'s
/// one-shot onboarding CREATE form.
///
/// Mounted directly rather than through the router: it is a leaf screen reached
/// from Account, and mounting it directly keeps these tests hermetic.
class _FakeOrganizationController extends OrganizationController {
  _FakeOrganizationController({
    this.name = 'Apiários do Montargil',
    this.address = 'Montargil, Ponte de Sor',
    this.registrationNumber = '',
    this.role = 'admin',
  });

  final String name;
  final String address;
  final String registrationNumber;
  final String role;

  /// What [saveDetails] was last called with, so a test can assert the screen
  /// sends all three fields in one save rather than only the number.
  ({String name, String address, String registrationNumber})? saved;

  /// When true, [saveDetails] throws — the offline / 403 / 422 path.
  bool failSave = false;

  /// When set, [saveDetails] parks on this before returning, so a test can
  /// hold the screen in its `_busy` state and act on it MID-save. Without it
  /// the save resolves within the same `pump`, and the in-flight window the
  /// back control has to behave correctly in is unreachable from a test.
  Completer<void>? holdSave;

  @override
  Future<Organization?> build() async => Organization(
    id: 'org-1',
    name: name,
    address: address,
    registrationNumber: registrationNumber,
    createdBy: 'user-1',
    role: role,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );

  /// Simulates what a [refresh] does — a NEWER organization arriving from the
  /// server (e.g. another admin renamed it) while this screen is open.
  void emit(Organization organization) => state = AsyncData(organization);

  /// The baseline [saveDetails] was handed — the organization the screen's
  /// fields were SEEDED from, which is what the repository diffs the PATCH
  /// body against.
  Organization? savedFrom;

  @override
  Future<bool> saveDetails({
    required Organization from,
    required String name,
    required String address,
    required String registrationNumber,
  }) async {
    final hold = holdSave;
    if (hold != null) await hold.future;
    if (failSave) throw Exception('offline');
    savedFrom = from;
    saved = (
      name: name,
      address: address,
      registrationNumber: registrationNumber,
    );
    // Mirrors the real controller: a PATCH goes out only when something
    // actually differs from the baseline the screen was seeded from.
    return name.trim() != from.name ||
        address.trim() != from.address ||
        registrationNumber.trim() != from.registrationNumber;
  }
}

/// A minimal [AuthController] stand-in returning a fixed token, so the real
/// [ApiClient] can authorize its requests — mirrors
/// organization_repository_test.dart's own fake of the same name.
class _FakeAuthController extends AuthController {
  @override
  Future<AuthSession?> build() async => null;

  @override
  Future<String?> accessToken() async => 'tok';
}

/// In-memory [LocalPrefs] so the repository's offline-cache write needs no
/// platform channel.
class _FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> _store = {};

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

Widget _buildScreen(_FakeOrganizationController controller) {
  return ProviderScope(
    overrides: [organizationProvider.overrideWith(() => controller)],
    child: const MaterialApp(
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: kSupportedLocales,
      home: OrganizationDetailsScreen(),
    ),
  );
}

/// The same screen behind a minimal router that declares `/account`, for the
/// two things [_buildScreen] cannot assert: that leaving actually navigates,
/// and where to. Everything else stays on the routerless harness, which is
/// cheaper and is what the rest of this file is written against.
Widget _buildRoutedScreen(_FakeOrganizationController controller) {
  final router = GoRouter(
    initialLocation: '/organization/details',
    routes: [
      GoRoute(
        path: '/organization/details',
        builder: (context, state) => const OrganizationDetailsScreen(),
      ),
      GoRoute(
        path: '/account',
        builder: (context, state) => const Scaffold(body: Text('account')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [organizationProvider.overrideWith(() => controller)],
    child: MaterialApp.router(
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: kSupportedLocales,
      routerConfig: router,
    ),
  );
}

const _nameField = Key('organization-details-name-field');
const _addressField = Key('organization-details-address-field');
const _numberField = Key('organization-details-registration-number-field');
const _saveButton = Key('organization-details-save-button');

void main() {
  // #629 (FR-UX-1, FR-AX-1): all three fields floated their labels.
  group('one field-label pattern (#629, FR-UX-1)', () {
    Future<void> pumpForm(WidgetTester tester) async {
      await tester.pumpWidget(
        _buildScreen(
          _FakeOrganizationController(
            name: 'Apiários do Montargil',
            address: 'Montargil, Ponte de Sor',
            registrationNumber: 'PT-123456',
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('no field on the form paints a floating Material label', (
      tester,
    ) async {
      await pumpForm(tester);

      expectNoFloatingFieldLabels(
        tester,
        find.byType(OrganizationDetailsScreen),
      );
    });

    testWidgets('every label sits above its field, via LabeledField', (
      tester,
    ) async {
      await pumpForm(tester);

      for (final label in const [
        'Organization name',
        'Address (optional)',
        'Registration number',
      ]) {
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

        expectFieldAccessibleName(tester, _nameField, 'Organization name');
        expectFieldAccessibleName(tester, _addressField, 'Address (optional)');
        expectFieldAccessibleName(tester, _numberField, 'Registration number');
        handle.dispose();
      },
    );
  });

  testWidgets('renders the organization name, address and registration '
      'number from the loaded organization', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeOrganizationController(
          name: 'Apiários do Montargil',
          address: 'Montargil, Ponte de Sor',
          registrationNumber: 'PT-123456',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextFormField>(find.byKey(_nameField)).controller?.text,
      'Apiários do Montargil',
    );
    expect(
      tester.widget<TextFormField>(find.byKey(_addressField)).controller?.text,
      'Montargil, Ponte de Sor',
    );
    expect(
      tester.widget<TextFormField>(find.byKey(_numberField)).controller?.text,
      'PT-123456',
    );
  });

  testWidgets('saves all three fields together in one call — the screen edits '
      'the organization, not just its number', (tester) async {
    final controller = _FakeOrganizationController(
      registrationNumber: 'PT-123456',
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_nameField), 'Apiários do Norte');
    await tester.enterText(find.byKey(_addressField), 'Bragança');
    await tester.enterText(find.byKey(_numberField), 'PT-654321');
    await tester.tap(find.byKey(_saveButton));
    await tester.pumpAndSettle();

    expect(controller.saved?.name, 'Apiários do Norte');
    expect(controller.saved?.address, 'Bragança');
    expect(controller.saved?.registrationNumber, 'PT-654321');
    expect(find.text('Organization details saved'), findsOneWidget);
  });

  testWidgets('hands the save the organization it SEEDED from, so the '
      'repository can omit untouched fields', (tester) async {
    final controller = _FakeOrganizationController(
      name: 'Apiários do Montargil',
      registrationNumber: 'PT-123456',
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_numberField), 'PT-654321');
    await tester.tap(find.byKey(_saveButton));
    await tester.pumpAndSettle();

    expect(controller.savedFrom?.name, 'Apiários do Montargil');
    expect(controller.savedFrom?.registrationNumber, 'PT-123456');
  });

  testWidgets('re-seeds the fields when a newer organization arrives and the '
      'user is not mid-edit', (tester) async {
    final controller = _FakeOrganizationController(
      name: 'Apiários do Montargil',
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    controller.emit(
      Organization(
        id: 'org-1',
        name: 'Renamed By Another Admin',
        address: 'Montargil, Ponte de Sor',
        createdBy: 'user-1',
        role: 'admin',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 2, 2),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextFormField>(find.byKey(_nameField)).controller?.text,
      'Renamed By Another Admin',
    );
  });

  testWidgets('a newer organization does NOT clobber what the user is '
      'typing', (tester) async {
    final controller = _FakeOrganizationController(
      name: 'Apiários do Montargil',
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_nameField), 'Half-typed name');
    controller.emit(
      Organization(
        id: 'org-1',
        name: 'Renamed By Another Admin',
        address: 'Montargil, Ponte de Sor',
        createdBy: 'user-1',
        role: 'admin',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 2, 2),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextFormField>(find.byKey(_nameField)).controller?.text,
      'Half-typed name',
    );
  });

  testWidgets('a newer organization does NOT clobber an open edit the user '
      'has typed back to its seeded value', (tester) async {
    final controller = _FakeOrganizationController(
      name: 'Apiários do Montargil',
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    // The user IS editing — they just happen to have arrived back at the
    // seeded text (typed, then undone). Comparing values calls this "clean"
    // and re-seeds; only tracking the edit itself gets it right.
    await tester.enterText(find.byKey(_nameField), 'Half-typed name');
    await tester.enterText(find.byKey(_nameField), 'Apiários do Montargil');
    controller.emit(
      Organization(
        id: 'org-1',
        name: 'Renamed By Another Admin',
        address: 'Montargil, Ponte de Sor',
        createdBy: 'user-1',
        role: 'admin',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 2, 2),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextFormField>(find.byKey(_nameField)).controller?.text,
      'Apiários do Montargil',
    );
  });

  testWidgets('re-seeds again once a save has reconciled the form with the '
      'server', (tester) async {
    final controller = _FakeOrganizationController(
      name: 'Apiários do Montargil',
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_nameField), 'Apiários do Norte');
    await tester.tap(find.byKey(_saveButton));
    await tester.pumpAndSettle();

    // The edit is settled, so the screen must follow the server again — the
    // edited flag must not latch on forever.
    controller.emit(
      Organization(
        id: 'org-1',
        name: 'Renamed By Another Admin',
        address: 'Montargil, Ponte de Sor',
        createdBy: 'user-1',
        role: 'admin',
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 2, 2),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextFormField>(find.byKey(_nameField)).controller?.text,
      'Renamed By Another Admin',
    );
  });

  testWidgets('refuses to save an empty name — the contract requires one', (
    tester,
  ) async {
    final controller = _FakeOrganizationController();
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(_nameField), '   ');
    await tester.tap(find.byKey(_saveButton));
    await tester.pumpAndSettle();

    expect(controller.saved, isNull);
  });

  testWidgets('surfaces a failed save rather than leaving the button '
      'spinning (offline, 403 or 422)', (tester) async {
    final controller = _FakeOrganizationController()..failSave = true;
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(_saveButton));
    await tester.pumpAndSettle();

    expect(
      find.text('Could not save the organization details'),
      findsOneWidget,
    );
  });

  testWidgets('a non-admin sees the values but cannot edit or save them '
      '(NFR-ROL-1)', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeOrganizationController(
          registrationNumber: 'PT-123456',
          role: 'user',
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final key in const [_nameField, _addressField, _numberField]) {
      expect(tester.widget<TextFormField>(find.byKey(key)).enabled, isFalse);
    }
    expect(
      tester.widget<TextFormField>(find.byKey(_numberField)).controller?.text,
      'PT-123456',
    );
    expect(find.byKey(_saveButton), findsNothing);
    expect(
      find.text('Only an organization admin can change these.'),
      findsOneWidget,
    );
  });

  testWidgets('the save action meets the 44x44 gloves-friendly minimum '
      '(D-18)', (tester) async {
    await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byKey(_saveButton)).height,
      greaterThanOrEqualTo(44),
    );
  });

  // Regression (#298, found by a live Helm-E2E run whose network trace showed
  // TWO `GET /v1/organizations/me` and ZERO PATCHes behind a "saved" snackbar):
  // a refresh landing between typing and Save must never discard the edit, and
  // Save must never claim success for a request it did not send. These drive
  // the REAL controller and the REAL repository against a MockClient, so what
  // they assert is the wire traffic, not a fake's bookkeeping.
  group('a refresh landing mid-edit', () {
    late List<Map<String, dynamic>> patchBodies;
    late int getCount;
    late Map<String, dynamic> serverOrg;

    ProviderContainer buildContainer() {
      patchBodies = [];
      getCount = 0;
      serverOrg = {
        'id': 'org-1',
        'name': 'Apiários do Montargil',
        'address': 'Montargil, Ponte de Sor',
        'registration_number': '',
        'created_by': 'user-1',
        'role': 'admin',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-02T00:00:00.000Z',
      };
      final client = MockClient((req) async {
        if (req.method == 'PATCH') {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          patchBodies.add(body);
          serverOrg = {
            ...serverOrg,
            for (final e in body.entries) e.key: e.value ?? '',
          };
        } else {
          getCount++;
        }
        return http.Response(
          jsonEncode(serverOrg),
          200,
          headers: {'content-type': 'application/json'},
          request: req,
        );
      });
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(_FakeAuthController.new),
          isAuthenticatedProvider.overrideWith((ref) => true),
          organizationRepositoryProvider.overrideWith(
            (ref) => OrganizationRepository(
              ApiClient(ref, httpClient: client),
              prefs: _FakeLocalPrefs(),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Widget wrap(ProviderContainer container) => UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: kSupportedLocales,
        home: OrganizationDetailsScreen(),
      ),
    );

    testWidgets('still PATCHes the typed registration number when a refresh '
        'lands between typing and Save', (tester) async {
      final container = buildContainer();
      await tester.pumpWidget(wrap(container));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_numberField), 'PT-654321');
      await tester.pump();

      // A second `GET /organizations/me` lands — the refresh the trace showed.
      // It has NOT seen the edit (the number is still empty server-side) and
      // carries a newer `updated_at`, so it is a genuinely new value.
      serverOrg = {...serverOrg, 'updated_at': '2026-02-02T00:00:00.000Z'};
      await container.read(organizationProvider.notifier).refresh();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_saveButton));
      await tester.pumpAndSettle();

      expect(getCount, 2, reason: 'the refresh really did land');
      expect(
        patchBodies.single['registration_number'],
        'PT-654321',
        reason: 'the typed value must reach the wire, not be silently dropped',
      );
    });

    testWidgets('does not claim a save happened when nothing changed and no '
        'request was sent', (tester) async {
      final container = buildContainer();
      await tester.pumpWidget(wrap(container));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_saveButton));
      await tester.pumpAndSettle();

      expect(patchBodies, isEmpty);
      expect(find.text('Organization details saved'), findsNothing);
      expect(find.text('No changes to save'), findsOneWidget);
    });
  });

  // #601: with `If-Match` now on the save, the server can answer 409 for the
  // one race the body diff cannot close — two admins editing the SAME field.
  // "Could not save" would send the user to retry a save that is guaranteed to
  // fail the same way (or to win by overwriting an edit they never saw), so
  // this failure gets its own copy. Drives the REAL controller and repository
  // against a MockClient, so it asserts the wire behavior.
  group('a stale save (409)', () {
    testWidgets('surfaces the conflict distinctly, not the generic '
        'save-failed message, and keeps the typed value on screen', (
      tester,
    ) async {
      final client = MockClient((req) async {
        if (req.method == 'PATCH') {
          return http.Response(
            jsonEncode({
              'code': 'conflict',
              'detail': 'If-Match does not match the current version',
            }),
            409,
            headers: {'content-type': 'application/json'},
            request: req,
          );
        }
        return http.Response(
          jsonEncode({
            'id': 'org-1',
            'name': 'Apiários do Montargil',
            'address': 'Montargil, Ponte de Sor',
            'registration_number': '',
            'created_by': 'user-1',
            'role': 'admin',
            'created_at': '2026-01-01T00:00:00.000Z',
            'updated_at': '2026-01-02T00:00:00.000Z',
          }),
          200,
          headers: {'content-type': 'application/json', 'etag': '"v1"'},
          request: req,
        );
      });
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(_FakeAuthController.new),
          isAuthenticatedProvider.overrideWith((ref) => true),
          organizationRepositoryProvider.overrideWith(
            (ref) => OrganizationRepository(
              ApiClient(ref, httpClient: client),
              prefs: _FakeLocalPrefs(),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: kSupportedLocales,
            home: OrganizationDetailsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_numberField), 'PT-654321');
      await tester.tap(find.byKey(_saveButton));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Someone else changed these details. Reopen this screen to see the '
          'latest, then make your change again.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Could not save the organization details'),
        findsNothing,
      );
      expect(
        tester.widget<TextFormField>(find.byKey(_numberField)).controller?.text,
        'PT-654321',
        reason: 'a rejected save must not discard what the user typed',
      );
    });
  });

  // #769 (FR-UX-1): this screen hung its 480px column off a plain `Center`,
  // the shape #630 replaced on profile and new-organization. Measured at
  // 375x812 the three-field form left a 178.5px dead band under the header.
  group('layout at 375x812 (#769, FR-UX-1)', () {
    Future<void> pumpDetails(WidgetTester tester) async {
      await tester.pumpWidget(
        _buildScreen(
          _FakeOrganizationController(
            name: 'Apiarios do Montargil',
            address: 'Montargil, Ponte de Sor',
            registrationNumber: 'PT-123456',
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the form starts immediately under the header', (tester) async {
      useViewport(tester);
      await pumpDetails(tester);

      final scroll = find.ancestor(
        of: find.byKey(_nameField),
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
            'the organization details form must start just under the header '
            'like every other form screen; it started '
            '${contentTop - headerBottom}px below it',
      );
    });

    // A FORWARD guard, not a reproduction — Save cleared both bars before
    // the change too. It protects the opposite failure: top-aligning a short
    // form hard enough to float its primary action up into the top third,
    // out of a one-handed thumb's reach.
    testWidgets('Save stays within comfortable thumb reach', (tester) async {
      useViewport(tester);
      await pumpDetails(tester);

      expectWithinThumbReach(
        tester,
        find.byKey(_saveButton),
        label: 'Save organization details',
      );
    });
  });

  // #789 (FR-UX-2, FR-AX-1): this form padded a flat 24 at the bottom, so
  // nothing stood between the "Organization details saved" toast it raises
  // and the Save button it reports on. Outside the shell (no bottom
  // navigation, no FAB), so the band is the toast's own height plus the
  // home-indicator inset its bar carries out here.
  //
  // Asserted structurally rather than by raising the toast, unlike the
  // sibling account/profile/create-organization screens. Two measurements
  // rule the behavioural form out here, and both are about the toast rather
  // than about what this screen reserves: `organizationDetailsSaved` wraps to
  // three lines at 200% text on a 375pt phone and measures 182 — past any
  // fixed band, which is #790, not this screen — and three fields do not fill
  // a 375x812 viewport at either scale, so the form never reaches its own
  // bottom there and no padding could change where the toast lands. On a
  // shorter window, or once a fourth field lands, it does: the reservation is
  // what this test pins.
  group('the bottom chrome band (#789, FR-UX-2)', () {
    for (final textScale in [1.0, 2.0]) {
      testWidgets('the form reserves the bottom chrome band under Save, at '
          '${textScale}x text', (tester) async {
        useFieldPhone(tester, textScale: textScale);

        await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
        await tester.pumpAndSettle();

        final scroll = find.byType(SingleChildScrollView);
        await scrollToEnd(tester, scroll);

        expectReservesBottomBand(
          tester,
          lastRow: find.byKey(_saveButton),
          scrollable: scroll,
          reason:
              'the form must leave a toast a band of its own below Save, '
              'not end flush against the window bottom',
        );
      });
    }
  });

  // #639 (FR-AP-9, FR-UX-2, FR-AX-1): this route is declared OUTSIDE the app
  // shell, so it carries neither the shell's bottom navigation nor its back
  // action — and its own AppBar had no `leading`. The whole file contained no
  // `context.go/pop/push` at all: saving left the user standing on the same
  // screen with no way out but the browser/OS back gesture.
  //
  // Mirrors the guard the members and account screens already carry
  // (`members-back-button`, `account-back-button`). Where it LANDS is pinned
  // by the live-router sweep in test/routing/pushed_screen_exit_test.dart;
  // this harness has no GoRouter, so it only pins presence + a11y label.
  group('the app bar offers a way back (#639, FR-UX-2)', () {
    testWidgets('the app bar has a back button', (tester) async {
      await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('organization-details-back-button')),
        findsOneWidget,
      );
    });

    testWidgets('the back button has a tooltip/semantic label', (tester) async {
      await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
      await tester.pumpAndSettle();

      final button = tester.widget<IconButton>(
        find.byKey(const Key('organization-details-back-button')),
      );
      expect(button.tooltip, isNotNull);
      expect(button.tooltip, isNotEmpty);
    });

    // Unlike the other four out-of-shell screens #639 swept, this one is an
    // EDIT FORM. A one-tap exit that silently drops typed edits would trade
    // the dead end for data loss, which #345 (FR-UX-1) already ruled out for
    // every other form in the app.
    testWidgets('leaving with unsaved edits asks before discarding them', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(_FakeOrganizationController(name: 'Apiário Velho')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_nameField), 'Apiário Novo');
      await tester.pump();

      await tester.tap(
        find.byKey(const Key('organization-details-back-button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('discard-changes-dialog')), findsOneWidget);
    });

    testWidgets('keeping editing returns to the form with the edit intact', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(_FakeOrganizationController(name: 'Apiário Velho')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_nameField), 'Apiário Novo');
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('organization-details-back-button')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('discard-changes-cancel')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('discard-changes-dialog')), findsNothing);
      // Still on the form, and the typed value survived the round trip — a
      // prompt that dropped the edit anyway would be worse than none.
      expect(find.byKey(_nameField), findsOneWidget);
      expect(
        tester.widget<TextFormField>(find.byKey(_nameField)).controller?.text,
        'Apiário Novo',
      );
    });

    // The converse — an UNTOUCHED form must leave without a prompt, or every
    // exit from a screen the user only read costs a pointless extra tap.
    // Asserting "no dialog" alone would pass just as happily if the button did
    // nothing at all, so these two run on [_buildRoutedScreen] and assert the
    // router actually ARRIVES; the sweep in
    // test/routing/pushed_screen_exit_test.dart pins the same landing against
    // the real router.
    testWidgets('an untouched form leaves for /account without a prompt', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildRoutedScreen(_FakeOrganizationController(name: 'Apiário Velho')),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('organization-details-back-button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('discard-changes-dialog')), findsNothing);
      expect(find.text('account'), findsOneWidget);
    });

    // Tapping Save and then back before the PATCH returns. The edits are
    // already on their way to the server, so "discard your changes?" would
    // state the opposite of what happens — and disabling the control for the
    // duration would be the dead end this issue is about, only briefer.
    testWidgets('leaving mid-save neither prompts nor traps the user', (
      tester,
    ) async {
      final hold = Completer<void>();
      final controller = _FakeOrganizationController(name: 'Apiário Velho')
        ..holdSave = hold;
      await tester.pumpWidget(_buildRoutedScreen(controller));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(_nameField), 'Apiário Novo');
      await tester.pump();
      await tester.tap(find.byKey(_saveButton));
      // One frame only: the save is now parked on `hold`, so the screen is
      // sitting in `_busy` — the window this test exists for.
      await tester.pump();

      await tester.tap(
        find.byKey(const Key('organization-details-back-button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('discard-changes-dialog')), findsNothing);
      expect(find.text('account'), findsOneWidget);

      // Let the save finish so the test does not end with a pending future,
      // and confirm it went through rather than being cancelled by leaving.
      hold.complete();
      await tester.pumpAndSettle();
      expect(controller.saved?.name, 'Apiário Novo');
    });
  });
}
