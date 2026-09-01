import 'package:beekeepingit_client/features/organization/organization_details_screen.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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
  Future<void> saveDetails({
    required Organization from,
    required String name,
    required String address,
    required String registrationNumber,
  }) async {
    if (failSave) throw Exception('offline');
    savedFrom = from;
    saved = (
      name: name,
      address: address,
      registrationNumber: registrationNumber,
    );
  }
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
      supportedLocales: AppLocalizations.supportedLocales,
      home: OrganizationDetailsScreen(),
    ),
  );
}

const _nameField = Key('organization-details-name-field');
const _addressField = Key('organization-details-address-field');
const _numberField = Key('organization-details-registration-number-field');
const _saveButton = Key('organization-details-save-button');

void main() {
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
}
