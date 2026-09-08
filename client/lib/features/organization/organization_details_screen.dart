import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/widgets/field_action_button.dart';
import '../../core/widgets/field_error.dart';
import '../../core/widgets/unsaved_changes.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
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
      appBar: AppBar(
        // Same dead end #639 fixed on the stock-declaration log, and for the
        // same reason: an out-of-shell route has no bottom navigation, and a
        // standalone-display PWA has no browser back button. Back to Account,
        // the only screen that links here (FR-UX-2).
        //
        // Unlike the other four out-of-shell screens this is an EDIT FORM, so
        // the exit is guarded: a one-tap control that silently discards typed
        // edits trades a dead end for data loss (#345's rule, FR-UX-1).
        leading: IconButton(
          key: const Key('organization-details-back-button'),
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: _leave,
        ),
        title: Text(l10n.organizationDetailsTitle),
      ),
      // Horizontally centred (so the 480px column stays middle-of-page on a
      // wide window) but TOP-aligned, the shape #630 settled on for profile
      // and new-organization (#769, FR-UX-1). A plain `Center` split the
      // leftover height into equal bands and left a measured 178.5px of dead
      // space under the header on a 375x812 phone — this three-field form is
      // shorter than a handset viewport, so the band was always on screen.
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            // The bottom gutter is the chrome band, not a gutter (#789):
            // nothing stood between the "Organization details saved" toast
            // this screen raises and the Save button it reports on. Three
            // fields do not fill a 375x812 phone, so the band is inert there
            // today — it earns its place on a shorter window, and the moment
            // a fourth field lands. No FAB and no bottom navigation here —
            // the route is declared outside the shell — so the band is the
            // toast's own height, which out here includes the home-indicator
            // inset the toast's bar carries; `scrollBottomInsetOf` adds it.
            //
            // What it deliberately does NOT do is clear that message at 200%
            // text: `organizationDetailsSaved` wraps to three lines there and
            // measures 182, past any fixed band. That is #790, and no
            // per-screen padding closes it.
            padding: EdgeInsets.fromLTRB(
              24,
              24,
              24,
              BrandDimens.scrollBottomInsetOf(context),
            ),
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
                  // One label pattern throughout (#629, FR-UX-1): every label
                  // sits ABOVE its field, never animated into the box border.
                  LabeledField(
                    label: l10n.organizationNameLabel,
                    child: TextFormField(
                      key: const Key('organization-details-name-field'),
                      controller: _nameController,
                      enabled: editable,
                      onChanged: _markEdited,
                      // Announced, not just painted (#750, FR-AX-1, D-18).
                      errorBuilder: announcedFieldError,
                      validator: (v) => (v == null || v.trim().isEmpty)
                          ? l10n.organizationNameRequired
                          : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabeledField(
                    label: l10n.organizationAddressLabel,
                    child: TextFormField(
                      key: const Key('organization-details-address-field'),
                      controller: _addressController,
                      enabled: editable,
                      onChanged: _markEdited,
                    ),
                  ),
                  const SizedBox(height: 16),
                  LabeledField(
                    label: l10n.organizationRegistrationNumberLabel,
                    child: TextFormField(
                      key: const Key(
                        'organization-details-registration-number-field',
                      ),
                      controller: _registrationNumberController,
                      enabled: editable,
                      onChanged: _markEdited,
                      maxLength: 50,
                      decoration: InputDecoration(
                        helperText: l10n.organizationRegistrationNumberHint,
                      ),
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

  /// Leaves for Account, confirming first if there are unsaved edits (#345).
  ///
  /// Reuses [_userHasEdited] — already the screen's record of "the user has
  /// touched this form and a save has not reconciled it since", which is
  /// exactly the dirty question — rather than introducing a second flag that
  /// could disagree with it. `_save` clears it, so leaving right after a save
  /// does not prompt.
  ///
  /// Not while [_busy]: a save is already in flight and will complete whatever
  /// this screen does next, so "discard your changes?" would be asking about
  /// edits that are on their way to the server — the prompt would state the
  /// opposite of what happens. Leaving stays available rather than being
  /// disabled during the save; a control that goes dead mid-request is the
  /// dead end this issue is about, only briefer.
  ///
  /// This is the deliberately narrow version of the guard: it covers the
  /// control #639 adds. The OS/browser back gesture still bypasses it, because
  /// that needs the `PopScope` half of the full `UnsavedChangesMixin` wiring
  /// this screen has never had — tracked in #829.
  Future<void> _leave() async {
    if (!_busy && _userHasEdited && !await showDiscardChangesDialog(context)) {
      return;
    }
    if (!mounted) return;
    context.go('/account');
  }

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
      showAppToast(
        messenger,
        sent
            ? l10n.organizationDetailsSaved
            : l10n.organizationDetailsNoChanges,
      );
    } on ApiException catch (e) {
      // A 409 means the `If-Match` this save carried is stale: another admin
      // changed the organization since this screen read it (#601). That is
      // the one failure with different advice — "try again" would either lose
      // their change or fail identically — so it gets its own copy, and the
      // form is deliberately left as the user typed it (the baseline and the
      // edited flag are NOT reset here, so the next build cannot re-seed over
      // what they still have on screen).
      showAppToast(
        messenger,
        e.statusCode == 409
            ? l10n.organizationDetailsSaveConflict
            : l10n.organizationDetailsSaveFailed,
      );
    } on Exception {
      // Offline, a 403 for a non-admin, or a 422 for an over-long value — all
      // surface the same way rather than leaving the button spinning. The
      // specific cause is not actionable to the beekeeper beyond "try again".
      showAppToast(messenger, l10n.organizationDetailsSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
