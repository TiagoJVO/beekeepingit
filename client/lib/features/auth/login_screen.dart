import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';

/// Login entry point: a single "sign in" action that starts the OIDC
/// Authorization Code + PKCE redirect to the identity provider (auth.md §3.2).
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l10n.appTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.loginPrompt,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 24),
                // Large, gloves-friendly primary action (WCAG 2.2 AA target
                // size) — see core/widgets/field_action_button.dart.
                PrimaryActionButton(
                  key: const Key('login-button'),
                  label: l10n.loginButton,
                  icon: Icons.login,
                  onPressed: () =>
                      ref.read(authControllerProvider.notifier).login(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
