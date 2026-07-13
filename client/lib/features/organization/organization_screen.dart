import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
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
  ConsumerState<OrganizationScreen> createState() =>
      _OrganizationScreenState();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.organizationSaveSuccess)));
      context.go('/apiaries');
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
      body: Center(
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
                  TextFormField(
                    key: const Key('organization-name-field'),
                    controller: _nameController,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: l10n.organizationNameLabel,
                      border: const OutlineInputBorder(),
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
                    decoration: InputDecoration(
                      labelText: l10n.organizationAddressLabel,
                      border: const OutlineInputBorder(),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
