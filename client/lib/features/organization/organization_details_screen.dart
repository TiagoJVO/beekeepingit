import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_widgets.dart';
import 'organization_repository.dart';

/// The organization's own details (FR-ONB-2 + FR-AP-9, #296), reached from
/// Account: its name, address, and the beekeeper registration-number default
/// its apiaries inherit.
///
/// **Not the onboarding form.** `organization_screen.dart` creates an
/// organization once and then leaves for the app home; this screen is the
/// re-enterable settings view of the same record, so it edits rather than
/// creates and stays where it is after a save.
///
/// Editing is a REST PATCH, so it needs connectivity — unlike the field-recorded
/// entities, which are local-first. That is the accepted trade-off for reference
/// data entered once (the values are still READ offline, from the organization
/// cache written by [OrganizationRepository.fetchMine]), and a failed save says
/// so rather than pretending.
///
/// Admin-only to EDIT (auth.md §5.3 — the server enforces it regardless): a
/// non-admin member sees the same values, read-only, with a note saying why.
class OrganizationDetailsScreen extends ConsumerStatefulWidget {
  const OrganizationDetailsScreen({super.key});

  @override
  ConsumerState<OrganizationDetailsScreen> createState() =>
      _OrganizationDetailsScreenState();
}

class _OrganizationDetailsScreenState
    extends ConsumerState<OrganizationDetailsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _registrationNumberController = TextEditingController();
  bool _busy = false;

  /// The organization the three controllers were last seeded FROM — not just
  /// its id. It is both the re-seed trigger (a newer organization is a
  /// different value, `Organization` having value equality) and the baseline
  /// a save diffs against, so an untouched field is omitted from the PATCH
  /// rather than sent stale (see [OrganizationController.saveDetails]).
  Organization? _seededFrom;

  /// Whether the user has touched this form since the last seed — set from the
  /// fields' `onChanged`, i.e. from the user's actual INTENT, not inferred by
  /// comparing the controllers against the baseline.
  ///
  /// The comparison this replaces answered a subtly different question ("does
  /// the form still hold exactly the seeded values?") and so said "not edited"
  /// in two cases where the user very much is editing: while `_seededFrom` is
  /// still null (nothing to compare against, so it defaulted to "clean"), and
  /// after the user has typed their way back to a seeded value mid-edit. In
  /// both, a provider emission landing at that moment would re-seed straight
  /// over the open form. An explicit flag cannot drift from intent that way:
  /// the screen stops re-seeding the moment the user starts editing and
  /// resumes only once a save has reconciled the form with the server.
  ///
  /// Deliberately not a `setState` — it changes nothing that is rendered, only
  /// whether the NEXT build is allowed to re-seed.
  bool _userHasEdited = false;

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _registrationNumberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final organization = ref.watch(organizationProvider).value;

    // Seed the controllers from the loaded organization, and RE-seed whenever
    // a newer one arrives — but never over an open edit. Seeding only once per
    // organization id (the original rule) meant a later refresh could never
    // re-seed, so the fields could stay stale indefinitely; seeding on every
    // rebuild would clobber what the user is halfway through typing. So:
    // re-seed only while the user has not touched the form (see
    // [_userHasEdited]).
    if (organization != null &&
        organization != _seededFrom &&
        !_userHasEdited) {
      _seededFrom = organization;
      _nameController.text = organization.name;
      _addressController.text = organization.address;
      _registrationNumberController.text = organization.registrationNumber;
    }

    final isAdmin = organization?.role == 'admin';
    final editable = isAdmin && !_busy;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.organizationDetailsTitle)),
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
                  if (!isAdmin) ...[
                    NotesCard(
                      key: const Key('organization-details-admin-only-note'),
                      icon: Icons.info_outlined,
                      text: l10n.organizationDetailsAdminOnly,
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextFormField(
                    key: const Key('organization-details-name-field'),
                    controller: _nameController,
                    enabled: editable,
                    onChanged: _markEdited,
                    decoration: InputDecoration(
                      labelText: l10n.organizationNameLabel,
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? l10n.organizationNameRequired
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('organization-details-address-field'),
                    controller: _addressController,
                    enabled: editable,
                    onChanged: _markEdited,
                    decoration: InputDecoration(
                      labelText: l10n.organizationAddressLabel,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key(
                      'organization-details-registration-number-field',
                    ),
                    controller: _registrationNumberController,
                    enabled: editable,
                    onChanged: _markEdited,
                    maxLength: 50,
                    decoration: InputDecoration(
                      labelText: l10n.organizationRegistrationNumberLabel,
                      helperText: l10n.organizationRegistrationNumberHint,
                    ),
                  ),
                  if (isAdmin) ...[
                    const SizedBox(height: 24),
                    PrimaryActionButton(
                      key: const Key('organization-details-save-button'),
                      label: MaterialLocalizations.of(context).saveButtonLabel,
                      busy: _busy,
                      onPressed: _save,
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

  /// Records that the user is editing this form. Takes (and ignores) the new
  /// value so it can be passed straight as a field's `onChanged`: WHAT they
  /// typed is irrelevant here, only THAT they typed.
  void _markEdited(String _) => _userHasEdited = true;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final seeded = _seededFrom;
    if (seeded == null) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final sent = await ref
          .read(organizationProvider.notifier)
          .saveDetails(
            from: seeded,
            name: _nameController.text,
            address: _addressController.text,
            registrationNumber: _registrationNumberController.text,
          );
      // Reconciled with the server either way — a PATCH went out and state
      // now holds its response, or nothing differed from the baseline in the
      // first place. So drop both the baseline and the edited flag and let the
      // next build re-seed: the canonical (trimmed, possibly
      // concurrently-changed by another admin) values are what this screen
      // should now show.
      _seededFrom = null;
      _userHasEdited = false;
      // A distinct message when no request was sent, never the success one.
      // Saying "saved" for a no-op is how the silent-failure this fixes stayed
      // invisible: it makes "your edit was lost" indistinguishable from "your
      // edit was stored", for the user AND for the e2e asserting on it. Not
      // simply staying silent either — the user pressed a button and a button
      // that answers nothing reads as broken, especially on the flaky
      // connectivity this screen already warns about.
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            sent
                ? l10n.organizationDetailsSaved
                : l10n.organizationDetailsNoChanges,
          ),
        ),
      );
    } on Exception {
      // Offline, a 403 for a non-admin, or a 422 for an over-long value — all
      // surface the same way rather than leaving the button spinning. The
      // specific cause is not actionable to the beekeeper beyond "try again".
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.organizationDetailsSaveFailed)),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
