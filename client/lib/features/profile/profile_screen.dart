import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import 'profile_repository.dart';

/// Create-or-edit profile screen (FR-ONB-1, #25). Serves both "first login,
/// complete your profile" (AC bullet 1/2) and "revisit and edit after
/// onboarding" (AC bullet 6) — one screen, since the form always reflects the
/// current profile state and lets the user submit changes. The router's
/// completion gate (see app_router.dart) is what forces an incomplete profile
/// back here; this screen itself doesn't need a separate "mode".
class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
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
      final complete = ref.read(profileCompleteProvider);
      if (complete) {
        // Next onboarding step: the router's own redirect (app_router.dart)
        // sends a profile-complete, no-organization user to
        // /organization/new (FR-ONB-2, #26) and everyone else to /apiaries,
        // so a plain '/apiaries' navigation here always lands wherever the
        // router's gates currently require.
        context.go('/apiaries');
      }
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final profileAsync = ref.watch(profileProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.profileTitle)),
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
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!profile.profileComplete) ...[
                        Text(
                          l10n.profileOnboardingIntro,
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        key: const Key('profile-name-field'),
                        controller: _nameController,
                        autofocus: !profile.profileComplete,
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
                        key: const Key('profile-email-field'),
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: l10n.profileEmailLabel,
                          border: const OutlineInputBorder(),
                          errorText: _fieldErrors['email'],
                        ),
                        validator: (v) {
                          final value = (v ?? '').trim();
                          if (value.isEmpty) return l10n.profileEmailRequired;
                          if (!_looksLikeEmail(value)) {
                            return l10n.profileEmailInvalid;
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        key: const Key('profile-locale-field'),
                        initialValue: _locale,
                        decoration: InputDecoration(
                          labelText: l10n.profileLocaleLabel,
                          border: const OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(value: 'en', child: Text('English')),
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
                      PrimaryActionButton(
                        key: const Key('profile-save-button'),
                        label: l10n.profileSaveButton,
                        busy: _saving,
                        onPressed: () => _save(l10n),
                      ),
                    ],
                  ),
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
