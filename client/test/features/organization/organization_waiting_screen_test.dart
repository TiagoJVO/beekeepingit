import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_waiting_screen.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/bottom_chrome.dart';

/// Counts [refresh] calls and controls what the next one resolves to.
///
/// The count is the load-bearing assertion of this file: it proves the
/// "check again" affordance goes through `GET /v1/organizations/me` — which
/// is *itself* the server's accept-on-login step — and not through some
/// bespoke accept endpoint. If anyone later adds one, this goes red.
class _CountingOrganizationController extends OrganizationController {
  _CountingOrganizationController({this.resolvesTo, this.throws});

  final Organization? resolvesTo;
  final Object? throws;
  int refreshCount = 0;

  @override
  Future<Organization?> build() async => null;

  @override
  Future<void> refresh() async {
    refreshCount++;
    if (throws != null) {
      state = AsyncValue.error(throws!, StackTrace.current);
      throw throws! as Exception;
    }
    state = AsyncData<Organization?>(resolvesTo);
  }
}

Widget _buildScreen(OrganizationController controller) {
  return ProviderScope(
    overrides: [organizationProvider.overrideWith(() => controller)],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      // Watching organizationProvider here stands in for the router, which
      // listens to it in production. Without a listener the provider would
      // auto-dispose between reads and rebuild to null, so a resolved
      // organization would silently look like no organization.
      home: Consumer(
        builder: (context, ref, child) {
          ref.watch(organizationProvider);
          return const OrganizationWaitingScreen();
        },
      ),
    ),
  );
}

void main() {
  testWidgets(
    'checking re-asks the organization endpoint exactly once — the same call '
    'that performs accept-on-login, so no new endpoint is needed',
    (tester) async {
      final controller = _CountingOrganizationController();
      await tester.pumpWidget(_buildScreen(controller));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('organization-waiting-check-button')),
      );
      await tester.pumpAndSettle();

      expect(controller.refreshCount, 1);
    },
  );

  testWidgets('a check that finds nothing says so', (tester) async {
    await tester.pumpWidget(_buildScreen(_CountingOrganizationController()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('organization-waiting-still-none')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const Key('organization-waiting-check-button')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('organization-waiting-still-none')),
      findsOneWidget,
    );
  });

  testWidgets(
    'a failed check shows a fixed localized message, never the raw exception',
    (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          _CountingOrganizationController(
            throws: const ApiException(
              statusCode: 500,
              code: 'internal',
              detail: 'pgx: connection refused on 10.0.0.5:5432',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('organization-waiting-check-button')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        find.text('Could not check for an invitation right now. Try again.'),
        findsOneWidget,
      );
      // Infrastructure detail must never reach a field user.
      expect(find.textContaining('pgx'), findsNothing);
      expect(find.textContaining('10.0.0.5'), findsNothing);
    },
  );

  testWidgets(
    'a successful check does NOT navigate — the router redirect owns that',
    (tester) async {
      final controller = _CountingOrganizationController(
        resolvesTo: Organization(
          id: 'org-1',
          name: 'Melgar',
          address: '',
          createdBy: 'u1',
          role: 'user',
          createdAt: DateTime.utc(2026, 1, 1),
          updatedAt: DateTime.utc(2026, 1, 1),
        ),
      );
      await tester.pumpWidget(_buildScreen(controller));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('organization-waiting-check-button')),
      );
      await tester.pumpAndSettle();

      // Still on this screen: navigation is not this widget's job, and a
      // context.go() here would fight the redirect. No "still none" message
      // either — an organization did resolve.
      expect(
        find.byKey(const Key('organization-waiting-check-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('organization-waiting-still-none')),
        findsNothing,
      );
    },
  );

  // #789 (FR-UX-2, FR-AX-1): this holding page padded a flat 24 at the
  // bottom, so its one toast — "Could not check for an invitation right now.
  // Try again.", a two-line message even at 1x — landed on the Log out row
  // that ends it. That row is this screen's only escape hatch: it sits
  // outside the shell, so there is no bottom navigation and no account screen
  // to reach past it. No FAB either, so the band is the toast's own height
  // plus the home-indicator inset its bar carries out here.
  group('the bottom chrome band (#789, FR-UX-2)', () {
    testWidgets('a toast does not cover the Log out row', (tester) async {
      useFieldPhone(tester);

      await tester.pumpWidget(_buildScreen(_CountingOrganizationController()));
      await tester.pumpAndSettle();

      await scrollToEnd(tester, find.byType(SingleChildScrollView));

      // `organizationWaitingCheckError` — the copy this screen actually shows
      // when the check cannot reach the server (app_en.arb). Two lines even
      // at 1x, which is why a flat 24 was not enough: it covered the Log out
      // row by a measured 57.
      await showToast(
        tester,
        message: 'Could not check for an invitation right now. Try again.',
      );

      expectToastClearsLastRow(
        tester,
        find.byKey(const Key('organization-waiting-logout-button')),
        reason:
            'the check-failed toast must land in the band this page '
            'reserves, not on the only escape hatch it offers',
      );
    });

    // The 200% case is asserted structurally, not by raising that same
    // message: at 200% text on a 375pt phone it wraps to seven lines and
    // measures 302, past any fixed band. That is a property of the sentence,
    // not of what this page reserves — #790, deliberately not fixed here.
    testWidgets('the page reserves the bottom chrome band under Log out, at '
        '2x text', (tester) async {
      useFieldPhone(tester, textScale: 2);

      await tester.pumpWidget(_buildScreen(_CountingOrganizationController()));
      await tester.pumpAndSettle();

      final scroll = find.byType(SingleChildScrollView);
      await scrollToEnd(tester, scroll);

      expectReservesBottomBand(
        tester,
        lastRow: find.byKey(const Key('organization-waiting-logout-button')),
        scrollable: scroll,
        reason:
            'the page must leave a toast a band of its own below Log out, '
            'not end flush against the window bottom',
      );
    });
  });
}
