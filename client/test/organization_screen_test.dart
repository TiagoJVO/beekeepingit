import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_screen.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake controller so tests drive [OrganizationScreen] without a real
/// [ApiClient]/network call, matching profile_screen_test.dart's
/// override-providers-not-network convention.
class _FakeOrganizationController extends OrganizationController {
  _FakeOrganizationController({this.onSubmit});

  final Future<void> Function({required String name, String? address})?
  onSubmit;

  @override
  Future<Organization?> build() async => null;

  @override
  Future<void> submit({required String name, String? address}) async {
    if (onSubmit != null) {
      await onSubmit!(name: name, address: address);
      return;
    }
    state = AsyncData(
      Organization(
        id: 'org-1',
        name: name,
        address: address ?? '',
        createdBy: 'u1',
        role: 'admin', // the creator is always admin (D-3)
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
      ),
    );
  }
}

Widget _buildScreen(OrganizationController controller) {
  return ProviderScope(
    overrides: [organizationProvider.overrideWith(() => controller)],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: OrganizationScreen(),
    ),
  );
}

void main() {
  testWidgets('renders the organization creation form', (tester) async {
    await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('organization-name-field')), findsOneWidget);
    expect(find.byKey(const Key('organization-address-field')), findsOneWidget);
    expect(
      find.text('Create your organization to start managing apiaries.'),
      findsOneWidget,
    );
  });

  testWidgets('validates an empty organization name client-side', (
    tester,
  ) async {
    await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('organization-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter an organization name.'), findsOneWidget);
  });

  testWidgets('submits a valid name and shows success', (tester) async {
    await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('organization-name-field')),
      'Dev Apiary Co.',
    );
    await tester.tap(find.byKey(const Key('organization-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('Organization created.'), findsOneWidget);
  });

  testWidgets('address is optional', (tester) async {
    String? submittedAddress = 'not set';
    await tester.pumpWidget(
      _buildScreen(
        _FakeOrganizationController(
          onSubmit: ({required name, address}) async {
            submittedAddress = address;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('organization-name-field')),
      'Dev Apiary Co.',
    );
    await tester.tap(find.byKey(const Key('organization-save-button')));
    await tester.pumpAndSettle();

    expect(submittedAddress, '');
  });

  testWidgets('surfaces a mocked 422 field error from the server', (
    tester,
  ) async {
    final controller = _FakeOrganizationController(
      onSubmit: ({required name, address}) async {
        throw const ApiException(
          statusCode: 422,
          code: 'validation.failed',
          detail: 'one or more fields are invalid',
          fieldErrors: [
            ApiFieldError(
              field: 'name',
              code: 'too_long',
              message: 'name must be at most 200 characters',
            ),
          ],
        );
      },
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('organization-name-field')),
      'Dev Apiary Co.',
    );
    await tester.tap(find.byKey(const Key('organization-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('name must be at most 200 characters'), findsOneWidget);
  });
}
