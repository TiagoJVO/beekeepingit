import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/auth/login_screen.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:openid_client/openid_client.dart';

/// [LoginScreen] rendered on its own (no router/onboarding gates) with a
/// controllable [oidcIssuerProvider] override, so a discovery/network
/// failure on tapping "Sign in" can be exercised without a real `.well-known`
/// fetch and without any other app machinery (matches
/// auth_controller_test.dart's own no-network-fixture approach).
Widget _buildLoginScreen({required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: LoginScreen(),
    ),
  );
}

void main() {
  testWidgets(
    'tapping "Sign in" while offline (discovery fails) shows an error '
    'instead of an unhandled exception',
    (tester) async {
      await tester.pumpWidget(
        _buildLoginScreen(
          overrides: [
            oidcIssuerProvider.overrideWith(
              (ref) => Future<Issuer>.error(
                Exception('discovery unreachable while offline'),
              ),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // No error surfaced yet — the attempt hasn't been made.
      expect(find.byKey(const Key('login-error-message')), findsNothing);

      await tester.tap(find.byKey(const Key('login-button')));
      await tester.pumpAndSettle();

      // The discovery failure must not escape as an unhandled zone error —
      // it should be caught and surfaced as visible, actionable UI state.
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('login-error-message')), findsOneWidget);
      // The "Sign in" button remains — tapping it again is the retry
      // affordance (login() resets the error at the start of each attempt).
      expect(find.byKey(const Key('login-button')), findsOneWidget);
    },
  );
}
