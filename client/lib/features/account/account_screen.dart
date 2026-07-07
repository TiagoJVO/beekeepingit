import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/config/app_config.dart';
import '../../l10n/gen/app_localizations.dart';
import '../profile/profile_repository.dart';
import 'account_platform.dart';

/// Account settings screen (FR-AU-1, #29): update profile information
/// in-app, and change password by delegating to Keycloak's own Account
/// Console (auth.md §7 — "use Keycloak's built-ins, no custom auth build";
/// Keycloak's console already requires re-entering + confirming the new
/// password and surfaces policy-violation/wrong-current-password errors
/// itself, so those ACs are satisfied by that built-in flow, not a form
/// built here). Reuses `features/profile`'s `profileProvider`/
/// `ProfileController` directly rather than duplicating profile state —
/// this screen is a second **place** to edit the same profile, not a
/// second **model** of it.
///
/// Subscription management is intentionally absent (D-4, "no billing UI
/// in v1 — everything free") — there is no such section on this screen.
///
/// History recording (FR-HIS-1) for profile updates made from here is the
/// same deferred seam as `features/profile` (#165) — no separate handling
/// needed, since both paths go through the same `PATCH /v1/profile`.
class AccountScreen extends ConsumerStatefulWidget {
  const AccountScreen({super.key});

  @override
  ConsumerState<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends ConsumerState<AccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  String _locale = 'en';
  bool _saving = false;
  bool _initialized = false;
  Map<String, String> _fieldErrors = {};

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _syncFromProfile(Profile profile) {
    if (_initialized) return;
    _initialized = true;
    _nameController.text = profile.name;
    _emailController.text = profile.email;
    _locale = profile.locale;
  }

  Future<void> _save(AppLocalizations l10n) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _fieldErrors = {};
    });
    try {
      await ref
          .read(profileProvider.notifier)
          .submit(
            name: _nameController.text.trim(),
            email: _emailController.text.trim(),
            locale: _locale,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.profileSaveSuccess)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _fieldErrors = {for (final fe in e.fieldErrors) fe.field: fe.message};
      });
      if (_fieldErrors.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.profileSaveError(e.detail))));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.profileSaveError('$e'))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _openChangePassword() {
    createAccountPlatform().openInNewTab(AppConfig.oidcAccountConsoleUrl);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final profileAsync = ref.watch(profileProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/apiaries'),
        ),
        title: Text(l10n.accountTitle),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text(l10n.profileSaveError('$err'))),
        data: (profile) {
          _syncFromProfile(profile);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.accountProfileSectionTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 16),
                    Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            key: const Key('account-name-field'),
                            controller: _nameController,
                            decoration: InputDecoration(
                              labelText: l10n.profileNameLabel,
                              border: const OutlineInputBorder(),
                              errorText: _fieldErrors['name'],
                            ),
                            validator: (v) => (v == null || v.trim().isEmpty)
                                ? l10n.profileNameRequired
                                : null,
                          ),
                          const SizedBox(height: 16),
                          TextFormField(
                            key: const Key('account-email-field'),
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            decoration: InputDecoration(
                              labelText: l10n.profileEmailLabel,
                              border: const OutlineInputBorder(),
                              errorText: _fieldErrors['email'],
                            ),
                            validator: (v) {
                              final value = (v ?? '').trim();
                              if (value.isEmpty) {
                                return l10n.profileEmailRequired;
                              }
                              if (!_looksLikeEmail(value)) {
                                return l10n.profileEmailInvalid;
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          DropdownButtonFormField<String>(
                            key: const Key('account-locale-field'),
                            initialValue: _locale,
                            decoration: InputDecoration(
                              labelText: l10n.profileLocaleLabel,
                              border: const OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'en',
                                child: Text('English'),
                              ),
                              DropdownMenuItem(
                                value: 'pt',
                                child: Text('Português'),
                              ),
                            ],
                            onChanged: (v) {
                              if (v != null) setState(() => _locale = v);
                            },
                          ),
                          const SizedBox(height: 24),
                          FilledButton(
                            key: const Key('account-save-button'),
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(56),
                            ),
                            onPressed: _saving ? null : () => _save(l10n),
                            child: _saving
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(l10n.profileSaveButton),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    const Divider(),
                    const SizedBox(height: 16),
                    Text(
                      l10n.accountSecuritySectionTitle,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l10n.accountChangePasswordHint,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      key: const Key('account-change-password-button'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(56),
                      ),
                      onPressed: _openChangePassword,
                      icon: const Icon(Icons.lock_outline),
                      label: Text(l10n.accountChangePasswordButton),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  bool _looksLikeEmail(String value) {
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value);
  }
}
