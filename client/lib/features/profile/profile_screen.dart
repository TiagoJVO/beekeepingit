import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/validation/email.dart';
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
      // Only `name`/`email` have a field on this form that renders its own
      // `errorText` below. Any other field the server rejects (e.g.
      // `locale`, which has no dedicated error slot) would otherwise be
      // silently dropped entirely once `_fieldErrors` is non-empty (the
      // generic snackbar below used to be suppressed whenever *any* field
      // error came back) — surface those unrendered field errors via the
      // snackbar too.
      final unrendered = _fieldErrors.keys.where(
        (k) => k != 'name' && k != 'email',
      );
      if (_fieldErrors.isEmpty || unrendered.isNotEmpty) {
        final msg = unrendered.isNotEmpty
            ? unrendered.map((k) => _fieldErrors[k]).join('\n')
            : e.detail;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.profileSaveError(msg))));
      }
    } on Exception catch (_) {
      // Narrowed to `Exception` (not a bare `catch`, which also matches
      // `Error` subtypes): a programming bug surfacing as an `Error` (e.g. a
      // null-check/type failure) should propagate — visible as a crash/error
      // report — rather than being swallowed and rendered as if it were a
      // normal, expected failure. And even for a genuine `Exception`, show a
      // fixed, localized message instead of its raw `toString()`: only
      // `ApiException.detail`/field messages above are structured enough to
      // show to the user verbatim.
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.profileGenericError)));
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
        // A fixed, localized message — never the raw error object. This is
        // a rendering callback rather than a `catch`, so it can't be
        // narrowed the way `_save`'s error handling above is, but an
        // unexpected profile-load failure (e.g. a decode bug) is the same
        // shape of leak and gets the same fix.
        error: (_, _) => Center(child: Text(l10n.profileGenericError)),
        data: (profile) {
          _syncFromProfile(profile);
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: _ProfileFormFields(
                    l10n: l10n,
                    nameController: _nameController,
                    emailController: _emailController,
                    locale: _locale,
                    fieldErrors: _fieldErrors,
                    saving: _saving,
                    showOnboardingIntro: !profile.profileComplete,
                    onLocaleChanged: (v) => setState(() => _locale = v),
                    onSave: () => _save(l10n),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The form's own column of fields (name/email/locale + save button),
/// extracted out of [_ProfileScreenState.build] so that method stays focused
/// on the async/error-branch wiring rather than also laying out ~95 lines of
/// form UI.
class _ProfileFormFields extends StatelessWidget {
  const _ProfileFormFields({
    required this.l10n,
    required this.nameController,
    required this.emailController,
    required this.locale,
    required this.fieldErrors,
    required this.saving,
    required this.showOnboardingIntro,
    required this.onLocaleChanged,
    required this.onSave,
  });

  final AppLocalizations l10n;
  final TextEditingController nameController;
  final TextEditingController emailController;
  final String locale;
  final Map<String, String> fieldErrors;
  final bool saving;
  final bool showOnboardingIntro;
  final ValueChanged<String> onLocaleChanged;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showOnboardingIntro) ...[
          Text(
            l10n.profileOnboardingIntro,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const SizedBox(height: 16),
        ],
        TextFormField(
          key: const Key('profile-name-field'),
          controller: nameController,
          autofocus: showOnboardingIntro,
          decoration: InputDecoration(
            labelText: l10n.profileNameLabel,
            border: const OutlineInputBorder(),
            errorText: fieldErrors['name'],
          ),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? l10n.profileNameRequired : null,
        ),
        const SizedBox(height: 16),
        TextFormField(
          key: const Key('profile-email-field'),
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: InputDecoration(
            labelText: l10n.profileEmailLabel,
            border: const OutlineInputBorder(),
            errorText: fieldErrors['email'],
          ),
          validator: (v) {
            final value = (v ?? '').trim();
            if (value.isEmpty) return l10n.profileEmailRequired;
            if (!looksLikeEmail(value)) {
              return l10n.profileEmailInvalid;
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: const Key('profile-locale-field'),
          initialValue: locale,
          decoration: InputDecoration(
            labelText: l10n.profileLocaleLabel,
            border: const OutlineInputBorder(),
          ),
          items: const [
            DropdownMenuItem(value: 'en', child: Text('English')),
            DropdownMenuItem(value: 'pt', child: Text('Português')),
          ],
          onChanged: (v) {
            if (v != null) onLocaleChanged(v);
          },
        ),
        const SizedBox(height: 24),
        PrimaryActionButton(
          key: const Key('profile-save-button'),
          label: l10n.profileSaveButton,
          busy: saving,
          onPressed: onSave,
        ),
      ],
    );
  }
}
