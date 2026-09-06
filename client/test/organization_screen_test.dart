import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_screen.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/a11y_matchers.dart';

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
      supportedLocales: kSupportedLocales,
      home: OrganizationScreen(),
    ),
  );
}

void main() {
  // #629 (FR-UX-1, FR-AX-1): the onboarding org form floated both its
  // labels, so it read differently from every other form in the app.
  group('one field-label pattern (#629, FR-UX-1)', () {
    Future<void> pumpForm(WidgetTester tester) async {
      await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
      await tester.pumpAndSettle();
    }

    testWidgets('no field on the form paints a floating Material label', (
      tester,
    ) async {
      await pumpForm(tester);

      expectNoFloatingFieldLabels(tester, find.byType(OrganizationScreen));
    });

    testWidgets('every label sits above its field, via LabeledField', (
      tester,
    ) async {
      await pumpForm(tester);

      for (final label in const ['Organization name', 'Address (optional)']) {
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

    testWidgets('the fields keep the accessible name their floating labels '
        'used to give them — the registration e2e types into this form via '
        'getByLabel("Organization name", exact) (FR-AX-1)', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(tester);

      expectFieldAccessibleName(
        tester,
        const Key('organization-name-field'),
        'Organization name',
      );
      expectFieldAccessibleName(
        tester,
        const Key('organization-address-field'),
        'Address (optional)',
      );
      handle.dispose();
    });
  });

  testWidgets(
    'the create form warns that creating an organization is a one-way choice',
    (tester) async {
      await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('organization-create-blocks-invite-warning')),
        findsOneWidget,
      );
    },
  );

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

  // #649 (FR-ONB-2, FR-UX-1): a blocked save raises the required-name error,
  // and that error has to disappear the moment the field holds a valid name
  // — not survive until the next save attempt, contradicting the value the
  // user can plainly see sitting in the field.
  testWidgets('clears the name error as soon as the name becomes valid', (
    tester,
  ) async {
    await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('organization-save-button')));
    await tester.pumpAndSettle();
    expect(find.text('Enter an organization name.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('organization-name-field')),
      'Dev Apiary Co.',
    );
    await tester.pumpAndSettle();

    expect(find.text('Enter an organization name.'), findsNothing);
  });

  // #649's second criterion, within one field: a value that is still not
  // valid (whitespace only — the validator trims) keeps its error.
  testWidgets('keeps the name error while the value is still invalid', (
    tester,
  ) async {
    await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('organization-save-button')));
    await tester.pumpAndSettle();
    expect(find.text('Enter an organization name.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('organization-name-field')),
      '   ',
    );
    await tester.pumpAndSettle();

    expect(find.text('Enter an organization name.'), findsOneWidget);
  });

  // #649's second criterion, across fields: fixing the name must not sweep
  // away the error still standing on the address field.
  testWidgets('fixing the name leaves another field error standing', (
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
            ApiFieldError(
              field: 'address',
              code: 'too_long',
              message: 'address must be at most 500 characters',
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
    expect(find.text('address must be at most 500 characters'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('organization-name-field')),
      'Dev Apiary Cooperative',
    );
    await tester.pumpAndSettle();

    expect(find.text('address must be at most 500 characters'), findsOneWidget);
    // ...and the name's own server verdict goes, because that value changed.
    expect(find.text('name must be at most 200 characters'), findsNothing);
  });

  // The other half of #649: a save-time verdict from the server is just as
  // stale once the user edits the value it judged, so it must go the moment
  // the field changes — the same rule apiary_form_screen.dart applies in its
  // Form.onChanged. The client can't know the new value passes, so this
  // clears on edit rather than on validity.
  testWidgets('drops a server field error once the user edits that field', (
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
              field: 'address',
              code: 'too_long',
              message: 'address must be at most 500 characters',
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
    expect(find.text('address must be at most 500 characters'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('organization-address-field')),
      'Rua das Abelhas 1',
    );
    await tester.pumpAndSettle();

    expect(find.text('address must be at most 500 characters'), findsNothing);
  });
}
