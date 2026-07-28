import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_tokens.dart';

/// Login entry point: a single "sign in" action that starts the OIDC
/// Authorization Code + PKCE redirect to the identity provider (auth.md §3.2).
///
/// Styled as the prototype's plum hero (docs/design/prototype.md, and the
/// as-built docs/design/melargil-flutter-style.md): a full-bleed plum ground
/// with the brand mark, the Playfair wordmark, the tagline, and the single
/// honey sign-in action — no app chrome (this route sits outside the shell).
class LoginScreen extends ConsumerWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final brand = context.brand;
    // Non-null when the last login attempt failed (e.g. OIDC discovery
    // unreachable while offline, #HIGH-2) — surfaced through
    // [loginErrorProvider] rather than an unhandled thrown Future. Tapping
    // "Sign in" again is the retry affordance: login() resets this to null
    // at the start of every attempt.
    final loginError = ref.watch(loginErrorProvider);
    return Scaffold(
      backgroundColor: brand.heroSurface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Brand mark — a honey tile (no bundled logo asset; keeps
                  // the app offline-first with no runtime image fetch).
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: BrandTokens.honey,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: const Icon(
                      Icons.hive_rounded,
                      size: 56,
                      color: BrandTokens.onHoney,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l10n.appTitle,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: AppTheme.displayFontFamily,
                      fontWeight: FontWeight.w600,
                      fontSize: 40,
                      color: brand.onHeroSurface,
                    ),
                  ),
                  const SizedBox(height: 28),
                  Text(
                    l10n.loginPrompt,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: AppTheme.bodyFontFamily,
                      fontSize: 16,
                      height: 1.5,
                      color: brand.onHeroSurfaceMuted,
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Large, gloves-friendly honey primary action (WCAG 2.2 AA
                  // target size) — see core/widgets/field_action_button.dart.
                  PrimaryActionButton(
                    key: const Key('login-button'),
                    label: l10n.loginButton,
                    icon: Icons.login,
                    onPressed: () async {
                      await ref.read(authControllerProvider.notifier).login();
                    },
                  ),
                  const SizedBox(height: 12),
                  // Federated sign-in (#363, FR-ONB-1). Starts the SAME OIDC
                  // Authorization Code + PKCE redirect as the primary action,
                  // adding only the `beekeepingit_idp` hint so the provider
                  // sends the user straight to Google instead of showing its
                  // own login form (auth.md §8.12). Secondary emphasis: the
                  // password path stays the primary action, and both carry the
                  // same 56px gloves-friendly target and semantics wrapper
                  // (D-18, WCAG 2.2 AA) from core/widgets/field_action_button.
                  // If this deployment has no Google source configured, the
                  // provider ignores the hint and the user simply lands on the
                  // normal login page — never a dead end.
                  SecondaryActionButton(
                    key: const Key('login-google-button'),
                    label: l10n.loginWithGoogleButton,
                    icon: Icons.account_circle_outlined,
                    onPressed: () async {
                      await ref
                          .read(authControllerProvider.notifier)
                          .login(idpHint: kIdpHintGoogle);
                    },
                  ),
                  if (loginError != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      key: const Key('login-error-message'),
                      l10n.loginError,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: AppTheme.bodyFontFamily,
                        fontSize: 14,
                        color: BrandTokens.dangerDark,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
