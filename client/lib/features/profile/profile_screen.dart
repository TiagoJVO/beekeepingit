import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/config/app_config.dart';
import '../../core/l10n/supported_locales.dart';
import '../../core/platform/external_link_platform.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_widgets.dart';
import '../organization/organization_repository.dart';
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
  String _locale = kDefaultLocaleTag;
  bool _saving = false;
  bool _initialized = false;
  Map<String, String> _fieldErrors = {};

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _syncFromProfile(Profile profile) {
    if (_initialized) return;
    _initialized = true;
    _nameController.text = profile.name;
    // See account_screen.dart — a legacy `pt`/`en` is mapped onto a
    // supported tag before it reaches the dropdown (#656/D-34).
    _locale = canonicalLocaleTag(profile.locale) ?? kDefaultLocaleTag;
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
          .submit(name: _nameController.text.trim(), locale: _locale);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.profileSaveSuccess)));
      final complete = ref.read(profileCompleteProvider);
      if (complete) {
        // Re-fetch the organization state before moving on (#366): for a
        // BRAND-NEW user the router's boot-time `GET /v1/organizations/me`
        // races the identity-row-creating first `GET /v1/profile` — the
        // organizations service then can't resolve the caller yet, answers
        // the same 404 as "no org", and that resolved answer stays cached,
        // permanently routing a user with a pending invitation to
        // /organization/new instead of auto-joining (FR-ONB-3
        // accept-on-login; caught live by the registration e2e's trace).
        // Profile completion is the first moment the identity row is
        // GUARANTEED to exist server-side, so refreshing here makes the org
        // gate's answer — join via invitation, or genuinely create — always
        // computed from a resolvable caller. The router treats the resulting
        // loading state as "wait, don't bounce" (app_router.dart).
        ref.invalidate(organizationProvider);
        // Next onboarding step: the router's own redirect (app_router.dart)
        // sends a profile-complete, no-organization user to
        // /organization/new (FR-ONB-2, #26) and everyone else to the Tasks
        // home (/todos, D-29/#427), so a plain '/todos' navigation here always
        // lands wherever the router's gates currently require.
        context.go('/todos');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _fieldErrors = {for (final fe in e.fieldErrors) fe.field: fe.message};
      });
      // Only `name` has a field on this form that renders its own
      // `errorText` below. Any other field the server rejects (e.g.
      // `locale`, which has no dedicated error slot) would otherwise be
      // silently dropped entirely once `_fieldErrors` is non-empty (the
      // generic snackbar below used to be suppressed whenever *any* field
      // error came back) — surface those unrendered field errors via the
      // snackbar too.
      final unrendered = _fieldErrors.keys.where((k) => k != 'name');
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
                    accountEmail: profile.email,
                    onManageAccount: () => ref
                        .read(externalLinkPlatformProvider)
                        .openInNewTab(AppConfig.oidcAccountUrl),
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
    required this.accountEmail,
    required this.onManageAccount,
    required this.locale,
    required this.fieldErrors,
    required this.saving,
    required this.showOnboardingIntro,
    required this.onLocaleChanged,
    required this.onSave,
  });

  final AppLocalizations l10n;
  final TextEditingController nameController;

  /// The IdP-verified account address, rendered read-only: the provider owns
  /// it and the API refuses to set it (D-7, FR-ONB-1).
  final String accountEmail;
  final VoidCallback onManageAccount;
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
            errorText: fieldErrors['name'],
          ),
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? l10n.profileNameRequired : null,
        ),
        const SizedBox(height: 16),
        // Read-only: the account address comes from the verified token and is
        // changed at the identity provider, never here. A disabled
        // TextFormField would still announce as an editable input to a screen
        // reader, so this is a labelled value with its own semantics.
        LabeledField(
          label: l10n.profileAccountEmailLabel,
          child: Semantics(
            readOnly: true,
            label: l10n.profileAccountEmailSemantics(accountEmail),
            child: ExcludeSemantics(
              child: Text(
                accountEmail,
                key: const Key('profile-account-email-value'),
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.profileAccountEmailHint,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        SecondaryActionButton(
          key: const Key('profile-manage-account-button'),
          label: l10n.profileManageAccountButton,
          icon: Icons.open_in_new,
          onPressed: onManageAccount,
        ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: const Key('profile-locale-field'),
          initialValue: locale,
          decoration: InputDecoration(labelText: l10n.profileLocaleLabel),
          // Endonyms with the supported BCP 47 tags as values (D-34) —
          // `en-GB`/`pt-PT`, never the generic `en`/`pt`.
          items: const [
            DropdownMenuItem(value: kDefaultLocaleTag, child: Text('English')),
            DropdownMenuItem(
              value: kPortugueseLocaleTag,
              child: Text('Português'),
            ),
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
