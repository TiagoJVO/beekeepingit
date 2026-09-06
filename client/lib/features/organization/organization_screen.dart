import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_widgets.dart';
import 'organization_repository.dart';

/// Organization creation screen (FR-ONB-2, FR-TEN-2, NFR-ROL-1, #26). Reached
/// after profile completion (profile_screen.dart's save handler routes here)
/// and enforced by the router's org-completion gate (app_router.dart) for any
/// authenticated, profile-complete user with no organization yet — until
/// then, apiaries/main features stay blocked (AC bullet 3). There is no
/// "join an existing org" affordance here yet — invitations land with #27
/// (D-3: creator becomes admin; others join via email invite).
class OrganizationScreen extends ConsumerStatefulWidget {
  const OrganizationScreen({super.key});

  @override
  ConsumerState<OrganizationScreen> createState() => _OrganizationScreenState();
}

class _OrganizationScreenState extends ConsumerState<OrganizationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  bool _saving = false;
  Map<String, String> _fieldErrors = {};

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    super.dispose();
  }

  /// Drops the last save's server verdict for [field] once its value changes
  /// (#649) — the same rule apiary_form_screen.dart applies in its
  /// `Form.onChanged`. Server errors arrive as `InputDecoration.errorText`,
  /// which `InputDecoration.copyWith` preserves whenever the local validator
  /// passes, so autovalidation alone would leave a rejected-value message
  /// sitting under a value the user has already rewritten. The client can't
  /// know the new value satisfies the server, so this clears on edit rather
  /// than on validity: the next save re-asks.
  void _clearFieldError(String field) {
    if (!_fieldErrors.containsKey(field)) return;
    setState(() => _fieldErrors = {..._fieldErrors}..remove(field));
  }

  Future<void> _save(AppLocalizations l10n) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _fieldErrors = {};
    });
    try {
      await ref
          .read(organizationProvider.notifier)
          .submit(
            name: _nameController.text.trim(),
            address: _addressController.text.trim(),
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l10n.organizationSaveSuccess)));
      // Onboarding complete → the app's home, which is the Home tab now
      // (#658, D-35, amending D-29's Tasks landing) — and a brand-new
      // organization is exactly the case a task list can't answer: it has no
      // tasks yet, so Home's first-run state greets it instead.
      context.go('/home');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _fieldErrors = {for (final fe in e.fieldErrors) fe.field: fe.message};
      });
      if (_fieldErrors.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.organizationSaveError(e.detail))),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.organizationSaveError('$e'))));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.organizationTitle)),
      // Horizontally centred (so the 480px column stays middle-of-page on a
      // wide window) but TOP-aligned: a plain `Center` split the leftover
      // height into equal bands and left dead space under the header on a
      // phone, unlike every other form screen in the app (#630, FR-UX-1).
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.organizationOnboardingIntro,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 16),
                  // The warning belongs where the irreversible choice is
                  // made: creating an organization is a one-way door until
                  // #506 lands (D-3's single-active-membership block).
                  NotesCard(
                    key: const Key('organization-create-blocks-invite-warning'),
                    icon: Icons.info_outlined,
                    text: l10n.organizationCreateBlocksInvitationWarning,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('organization-name-field'),
                    controller: _nameController,
                    autofocus: true,
                    // Per-field, so a blocked save's "enter a name" error
                    // clears the moment the field holds one instead of
                    // waiting for the next save (#649, FR-UX-1) — matching
                    // journey/todo. Field-level rather than on the Form: a
                    // Form-level onUserInteraction validates every field as
                    // soon as ANY of them is touched, which would flag this
                    // still-untouched name the instant the user types an
                    // address.
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    onChanged: (_) => _clearFieldError('name'),
                    decoration: InputDecoration(
                      labelText: l10n.organizationNameLabel,
                      errorText: _fieldErrors['name'],
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? l10n.organizationNameRequired
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('organization-address-field'),
                    controller: _addressController,
                    onChanged: (_) => _clearFieldError('address'),
                    decoration: InputDecoration(
                      labelText: l10n.organizationAddressLabel,
                      errorText: _fieldErrors['address'],
                    ),
                  ),
                  const SizedBox(height: 24),
                  PrimaryActionButton(
                    key: const Key('organization-save-button'),
                    label: l10n.organizationSaveButton,
                    busy: _saving,
                    onPressed: () => _save(l10n),
                  ),
                  // AFTER the save button on purpose: the a11y focus-order
                  // test asserts name -> address -> save, and this must not
                  // come between them.
                  const SizedBox(height: 12),
                  SecondaryActionButton(
                    key: const Key('organization-join-instead-button'),
                    label: l10n.organizationJoinInsteadButton,
                    icon: Icons.mail_outline,
                    onPressed: () => context.go('/organization/waiting'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
