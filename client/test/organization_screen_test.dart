import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_screen.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'support/a11y_matchers.dart';
import 'support/bottom_chrome.dart';

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

/// A router, not a bare `home:` — the screen ends a successful save with
/// `context.go('/home')`, and with no `GoRouter` in the tree that call threw
/// straight into `_save`'s own `catch`, so the harness was quietly exercising
/// the failure path. It went unnoticed because `showSnackBar` **queued**: the
/// error toast parked behind the success one, and the assertion below read the
/// success message off a bar the code had already moved past. Toasts replace
/// now (#640), which surfaced it.
Widget _buildScreen(OrganizationController controller) {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const OrganizationScreen(),
      ),
      GoRoute(
        path: '/home',
        builder: (context, state) =>
            const Scaffold(body: Center(child: Text('home'))),
      ),
    ],
  );
  return ProviderScope(
    overrides: [organizationProvider.overrideWith(() => controller)],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      routerConfig: router,
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
    // The semantics tree has to be alive for the announcement assertion at
    // the end — same server verdict, and a message that is painted without
    // being announced is exactly the #750 bug.
    final handle = tester.ensureSemantics();
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

    // #750 (FR-AX-1, D-18): a server-supplied field error never passes
    // through `Form.validate()`, so the SDK's own announcement path never
    // sees it — it must carry the live region itself.
    expectLiveRegion(tester, find.text('name must be at most 200 characters'));
    expect(
      tester
          .getSemantics(find.text('name must be at most 200 characters'))
          .label,
      'name must be at most 200 characters',
    );
    // ...and the field must READ as failing, not just look it. Only
    // `forceErrorText` sets `FormFieldState._errorText`, which is what
    // `Semantics(validationResult:)` is derived from; a message pushed in
    // through `InputDecoration.error` leaves the field `valid` — on web,
    // `aria-invalid="false"` under a visibly red error.
    expect(
      tester
          .getSemantics(find.byKey(const Key('organization-name-field')))
          .getSemanticsData()
          .validationResult,
      SemanticsValidationResult.invalid,
    );
    handle.dispose();
  });

  // A DELIBERATE behaviour change that came with routing the server verdict
  // through `forceErrorText` (#750): while a server error still stands, the
  // field is genuinely invalid, so `Form.validate()` returns false and a
  // second Save WITHOUT editing the field is blocked client-side instead of
  // re-issuing a request the server has already rejected for that exact
  // value. `forceErrorText` also overrides the validator — note the local
  // validator would return null here, the name being perfectly well-formed —
  // so the block comes from the server's verdict alone. #649's
  // clear-on-edit is what releases it: the moment the user changes the
  // value, the verdict is dropped and the next Save goes through (asserted
  // below).
  testWidgets('a second save with the server verdict still standing is '
      'blocked client-side (#750)', (tester) async {
    var submissions = 0;
    final controller = _FakeOrganizationController(
      onSubmit: ({required name, address}) async {
        submissions++;
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
    expect(submissions, 1);
    expect(find.text('that name is reserved'), findsOneWidget);

    // Same value, second tap: the client already knows the answer.
    await tester.tap(find.byKey(const Key('organization-save-button')));
    await tester.pumpAndSettle();
    expect(submissions, 1);
    expect(find.text('that name is reserved'), findsOneWidget);

    // Edit it, and the block is released — the user is never stuck.
    await tester.enterText(
      find.byKey(const Key('organization-name-field')),
      'Dev Apiary Cooperative',
    );
    await tester.pumpAndSettle();
    expect(find.text('that name is reserved'), findsNothing);

    await tester.tap(find.byKey(const Key('organization-save-button')));
    await tester.pumpAndSettle();
    expect(submissions, 2);
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

  group('layout at 375x812 (#630, FR-UX-1)', () {
    // Same dead-band bug as the profile screen: a plain `Center` pushed this
    // onboarding form into the middle of the viewport instead of starting it
    // under the header the way every other form screen does.
    testWidgets('the form starts immediately under the header', (tester) async {
      useViewport(tester);

      await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
      await tester.pumpAndSettle();

      final headerBottom = tester.getRect(find.byType(AppBar)).bottom;
      final contentTop = tester.getRect(find.byType(SingleChildScrollView)).top;

      expect(
        contentTop - headerBottom,
        // Bounded at both ends: below catches the dead band, above catches
        // content rendering up over the header.
        inInclusiveRange(0.0, 1.0),
        reason:
            'the organization form must start just under the header like '
            'every other form screen; it started '
            '${contentTop - headerBottom}px below it',
      );
    });

    // A FORWARD guard, not a reproduction — see the profile screen's own
    // thumb-reach test: the centred layout passed this too, and what it
    // protects against is top-aligning the action up into the top third.
    testWidgets('the create action stays within comfortable thumb reach', (
      tester,
    ) async {
      useViewport(tester);

      await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
      await tester.pumpAndSettle();

      expectWithinThumbReach(
        tester,
        find.byKey(const Key('organization-save-button')),
        label: 'the create-organization action',
      );
    });
  });

  // #789 (FR-UX-2, FR-AX-1): the onboarding org form padded a flat 24 at the
  // bottom, so the "Organization created." toast it raises landed on the
  // "I'm waiting for an invitation" row underneath its create action — the
  // one escape hatch out of a screen the user is stuck on until they pick.
  // Outside the shell (no bottom navigation, no FAB), so the band is the
  // toast's own height plus the home-indicator inset its bar carries.
  group('the bottom chrome band (#789, FR-UX-2)', () {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'a toast does not cover the join-instead row, at ${textScale}x text',
        (tester) async {
          useFieldPhone(tester, textScale: textScale);

          await tester.pumpWidget(_buildScreen(_FakeOrganizationController()));
          await tester.pumpAndSettle();

          await scrollToEnd(tester, find.byType(SingleChildScrollView));

          // `organizationSaveSuccess` — the copy this screen actually shows
          // once the organization is created (app_en.arb).
          await showToast(tester, message: 'Organization created.');

          expectToastClearsLastRow(
            tester,
            find.byKey(const Key('organization-join-instead-button')),
            reason:
                'the create toast must land in the band the form reserves, '
                'not on the join-instead escape hatch below it',
          );
        },
      );
    }
  });
}
