import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/app_toast.dart';
import '../../core/widgets/field_action_button.dart';
import '../../core/widgets/field_error.dart';
import '../../core/widgets/tap_target.dart';
import '../../core/widgets/unsaved_changes.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_widgets.dart';
import '../activities/activity_types.dart';
import '../sync/save_time_validation.dart';
import 'apiary_multi_select_field.dart';
import 'journey_default_attributes_section.dart';
import 'journey_status.dart';
import 'journeys_repository.dart';

/// The columns [JourneyFormScreen] binds to a control of its own, and can
/// therefore put a save-time parity error against (#597).
///
/// Two are deliberately absent. `status` is not editable here (it changes
/// through the close action), so an error on it would be unfixable in this
/// form. `default_attributes` is capped in BYTES of encoded JSON server-side, a
/// bound the defaults section cannot reach — its only free-text control is
/// itself capped at 100 characters — so binding it would add an error surface
/// for a failure no user can produce; it stays the pre-push pass's and the
/// server's business, like every other rule this form does not mirror.
///
/// Every name here must be a real column of [JourneysRepository.draftForSave] —
/// pinned by a test, because a column renamed there but not here would silently
/// turn the check off for that field rather than fail anything.
const journeyFormSyncCheckedColumns = {'name', 'main_activity_type'};

/// Create a journey (#45, FR-JO-4), or — when [journeyId] is given — edit an
/// existing one (name, main activity type, apiaries-to-visit plan) and
/// close it (D-21). Mirrors add_activity_screen.dart's own single-screen
/// create/edit pattern ([isEdit]) rather than two separate widgets, so the
/// validation/save logic has exactly one implementation for both flows.
/// Delete rides along here too, as a destructive action only shown in edit
/// mode — mirroring [AddActivityScreen]'s own delete-button-on-the-edit-form
/// placement, since there is no dedicated journey detail screen yet (#48).
///
/// Offline-first (FR-OF-1/Q-SYNC): every write goes straight to the local
/// store via [JourneysRepository] — queued for the write-back seam like
/// every other local-first write in this app. `organization_id` is derived
/// server-side from the caller's token once the queued write reconciles.
class JourneyFormScreen extends ConsumerStatefulWidget {
  const JourneyFormScreen({this.journeyId, super.key});

  /// Null for create; the journey being edited/closed/deleted for edit.
  final String? journeyId;

  bool get isEdit => journeyId != null;

  @override
  ConsumerState<JourneyFormScreen> createState() => _JourneyFormScreenState();
}

class _JourneyFormScreenState extends ConsumerState<JourneyFormScreen>
    with UnsavedChangesMixin {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  String _mainActivityType = activityTypeHarvest;
  String _status = journeyStatusOpen;
  Set<String> _apiaryIds = {};
  bool _busy = false;

  // Journey-level subtype attribute defaults (#385) — see
  // journey_default_attributes_section.dart's own doc comment.
  final _defaultAttributes = JourneyDefaultAttributesController();

  /// Whatever the save-time validation-parity check found last time [_save]
  /// ran (#597, FR-OF-2, D-12): the same evaluator and the same shared
  /// description the pre-push pass uses, run here so a rule the server would
  /// break on is reported **in this form, with the journey still open**
  /// rather than as a needs-fix card after the next push.
  SaveTimeFieldErrors _syncErrors = const SaveTimeFieldErrors.none();

  @override
  void initState() {
    super.initState();
    if (widget.isEdit) _loadExisting();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _defaultAttributes.dispose();
    super.dispose();
  }

  /// Loads the existing journey and pre-fills the form (mirrors
  /// add_activity_screen.dart's own `_loadExisting`, including its error
  /// handling and its "l10n/messenger only read inside the catch block"
  /// rule).
  // Wrapped in [loadWithoutMarkingDirty] (#345) so pre-filling the form
  // doesn't arm the unsaved-changes guard.
  Future<void> _loadExisting() => loadWithoutMarkingDirty(_loadExistingInner);

  Future<void> _loadExistingInner() async {
    setState(() => _busy = true);
    try {
      final repo = await ref.read(journeysRepositoryProvider.future);
      final existing = await repo.getById(widget.journeyId!);
      if (!mounted) return;
      if (existing != null) {
        _nameController.text = existing.name;
        _mainActivityType = existing.mainActivityType;
        _status = existing.status;
        _apiaryIds = existing.apiaryIds.toSet();
        _defaultAttributes.populate(
          existing.mainActivityType,
          existing.defaultAttributes,
        );
      }
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showAppToast(ScaffoldMessenger.of(context), l10n.journeyLoadError('$e'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // A journey may be saved with an empty apiary plan (D-30, #428): only the
  // name is required at create time; apiaries can be added later via edit
  // ([JourneysRepository.create] already documents `apiaryIds` may be empty).
  bool _validate() => _formKey.currentState!.validate();

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final name = _nameController.text.trim();
    final defaultAttributes = _defaultAttributes.build(_mainActivityType);
    // Run the save-time parity check BEFORE the Form's own validate(), so the
    // field validators can read the result and report it inline (#597).
    setState(() {
      _syncErrors = SaveTimeFieldErrors.check(
        JourneysRepository.draftForSave(
          id: widget.journeyId,
          name: name,
          mainActivityType: _mainActivityType,
          status: _status,
          defaultAttributes: defaultAttributes,
        ),
        columns: journeyFormSyncCheckedColumns,
      );
    });
    if (!_validate()) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(journeysRepositoryProvider.future);
      if (widget.isEdit) {
        await repo.update(
          widget.journeyId!,
          name: name,
          mainActivityType: _mainActivityType,
          status: _status,
          apiaryIds: _apiaryIds.toList(),
          defaultAttributes: defaultAttributes,
        );
      } else {
        await repo.create(
          name: name,
          mainActivityType: _mainActivityType,
          apiaryIds: _apiaryIds.toList(),
          defaultAttributes: defaultAttributes,
        );
      }
      if (!mounted) return;
      clearUnsavedChanges();
      context.go('/journeys');
      showAppToast(messenger, l10n.journeySaveSuccess);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showAppToast(messenger, l10n.journeySaveError('$e'));
    }
  }

  /// Closes the journey in place (D-21) — no confirmation dialog (unlike
  /// delete): closing only changes visibility in the #46 activity-form
  /// picker's default view, it never discards data.
  Future<void> _close() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(journeysRepositoryProvider.future);
      await repo.close(widget.journeyId!);
      if (!mounted) return;
      setState(() {
        _status = journeyStatusClosed;
        _busy = false;
      });
      showAppToast(messenger, l10n.journeyCloseSuccess);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showAppToast(messenger, l10n.journeyCloseError('$e'));
    }
  }

  /// Delete confirmation — mirrors add_activity_screen.dart's
  /// [DeleteActivityConfirmDialog]/`_confirmDelete` exactly, including the
  /// post-await `mounted` re-check.
  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const DeleteJourneyConfirmDialog(),
    );
    if (!mounted) return;
    if (confirmed != true) return;
    await _delete();
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(journeysRepositoryProvider.future);
      await repo.delete(widget.journeyId!);
      if (!mounted) return;
      clearUnsavedChanges();
      context.go('/journeys');
      showAppToast(messenger, l10n.journeyDeleteSuccess);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showAppToast(messenger, l10n.journeyDeleteError('$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isClosed = _status == journeyStatusClosed;

    if (_busy && widget.isEdit && _nameController.text.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return buildUnsavedChangesGuard(
      // Still a `Center`, not the `Align(topCenter)` #630/#769 gave the
      // scroll-view screens: the Column below is mainAxisSize.max around an
      // Expanded field area, so it already fills the body height and the
      // vertical alignment never gets to apply — swapping it would render
      // identically (FR-UX-1, #769).
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          // The fields scroll, the actions stay pinned — the structure
          // apiary_form_screen.dart adopted for #341 and
          // journey_quick_create_sheet.dart already used (#357). With the
          // actions as the last children of the scroll view, reaching Save on
          // a short viewport meant a swipe that the apiary multi-select's
          // bounded inner list silently swallows whenever the drag starts
          // over it. Outside the scrollable they are in the same place at
          // every scroll offset, picker state, viewport height and text scale
          // (FR-UX-1, FR-AX-1, D-18).
          //
          // No `BrandDimens.scrollBottomInset` here any more: that inset
          // clears a floating action button, and the shell hides its FAB on a
          // pushed route like this form (`_ShellFab`'s `canGoBack`) — the
          // pinned bar below is what the scroll view now has to clear, and it
          // does so by sitting outside it.
          //
          // LayoutBuilder caps that bar at half the body. Edit mode stacks
          // three field actions (~220px); on a body shorter than that — a
          // handset in landscape, or a large text scale — an uncapped bar
          // would take the whole Column, leave the fields 0px, overflow, and
          // paint the destructive Delete clipped below the 44x44 floor
          // (D-18). Capped, the bar scrolls internally instead and Save
          // stays whole at the top of it. At any ordinary height the cap is
          // slack and the layout is exactly the reference's.
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(
                      BrandDimens.gutterForm,
                      BrandDimens.gutterForm,
                      BrandDimens.gutterForm,
                      8,
                    ),
                    child: Form(
                      key: _formKey,
                      // Any field edit arms the unsaved-changes guard (#345); the
                      // apiary multi-select below (outside the field tree) calls it
                      // directly. It also drops the last save attempt's parity verdict
                      // (#597): the name field autovalidates on interaction, so a
                      // stale message would otherwise sit under a value the user has
                      // already corrected until they press Save again.
                      onChanged: () {
                        markUnsavedChanges();
                        if (_syncErrors.isNotEmpty) {
                          setState(
                            () =>
                                _syncErrors = const SaveTimeFieldErrors.none(),
                          );
                        }
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (widget.isEdit)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: BrandDimens.gapField,
                              ),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: _StatusChip(status: _status),
                              ),
                            ),
                          LabeledField(
                            label: l10n.journeyNameLabel,
                            child: TextFormField(
                              key: const Key('journey-name-field'),
                              controller: _nameController,
                              maxLength: 200,
                              autovalidateMode:
                                  AutovalidateMode.onUserInteraction,
                              // The form's own "required" rule first, then whatever
                              // the shared sync description says about this column
                              // (#597) — e.g. a name under the field's 200-character
                              // allowance but over the server's 200-BYTE cap, which
                              // only a save-time check can catch.
                              // Announced, not just painted (#750, FR-AX-1,
                              // D-18) — this field autovalidates per
                              // interaction, which the SDK's own
                              // `Form.validate()` announcement never covers.
                              errorBuilder: announcedFieldError,
                              validator: (v) => (v == null || v.trim().isEmpty)
                                  ? l10n.journeyNameRequired
                                  : _syncErrors.messageFor(l10n, 'name'),
                            ),
                          ),
                          const SizedBox(height: BrandDimens.gapField),
                          LabeledField(
                            label: l10n.journeyMainActivityTypeLabel,
                            child: DropdownButtonFormField<String>(
                              key: const Key(
                                'journey-main-activity-type-field',
                              ),
                              initialValue: _mainActivityType,
                              isExpanded: true,
                              items: [
                                for (final type in knownActivityTypes)
                                  DropdownMenuItem(
                                    value: type,
                                    child: Text(
                                      activityTypeLabel(l10n, type) ?? type,
                                    ),
                                  ),
                              ],
                              onChanged: (value) {
                                if (value != null) {
                                  setState(() {
                                    _mainActivityType = value;
                                    // A different main_activity_type invalidates the
                                    // old type's default-attribute keys (#385's own
                                    // design decision) — reset rather than carry
                                    // stale/mismatched values forward.
                                    _defaultAttributes.reset();
                                  });
                                }
                              },
                              // Announced, not just painted (#750, FR-AX-1,
                              // D-18).
                              errorBuilder: announcedFieldError,
                              validator: (_) => _syncErrors.messageFor(
                                l10n,
                                'main_activity_type',
                              ),
                            ),
                          ),
                          JourneyDefaultAttributesSection(
                            type: _mainActivityType,
                            controller: _defaultAttributes,
                            onChanged: () => setState(() {}),
                          ),
                          const SizedBox(height: BrandDimens.gapField),
                          ApiaryMultiSelectField(
                            selectedApiaryIds: _apiaryIds,
                            onChanged: (ids) {
                              setState(() {
                                _apiaryIds = ids;
                              });
                              markUnsavedChanges();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Pinned action bar. SafeArea (bottom only — the top belongs to the
                // scroll view) keeps it clear of the home indicator / browser
                // chrome. Close and Delete are pinned alongside Save rather than
                // left trailing the scrollable: the same swipe the multi-select
                // swallows would strand them too. Delete is protected against a
                // gloved mis-tap by [DeleteJourneyConfirmDialog]; Close, by
                // this screen's existing design, is not (`_close` writes
                // straight through, see its own doc comment) — pinning does not
                // change that, and #752 tracks giving it a confirmation. All
                // three keep the shared field-action sizing (at least 56px
                // tall, well over the 44x44 floor — D-18, FR-UX-1) and their
                // own semantics labels.
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight / 2,
                  ),
                  child: SingleChildScrollView(
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          BrandDimens.gutterForm,
                          BrandDimens.gapField / 2,
                          BrandDimens.gutterForm,
                          BrandDimens.gapField,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            PrimaryActionButton(
                              key: const Key('journey-save-button'),
                              label: l10n.saveButton,
                              busy: _busy,
                              onPressed: _save,
                            ),
                            if (widget.isEdit && !isClosed) ...[
                              const SizedBox(height: 12),
                              SecondaryActionButton(
                                key: const Key('journey-close-button'),
                                label: l10n.closeJourneyAction,
                                icon: Icons.lock_outline,
                                busy: _busy,
                                onPressed: _close,
                              ),
                            ],
                            if (widget.isEdit) ...[
                              const SizedBox(height: 12),
                              SecondaryActionButton(
                                key: const Key('journey-delete-button'),
                                label: l10n.deleteJourney,
                                icon: Icons.delete_outline,
                                destructive: true,
                                busy: _busy,
                                onPressed: _confirmDelete,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// D-21's status indicator on the edit form — closed reads as muted, not
/// alarming (mirrors journeys_list_screen.dart's own `_StatusBadge`
/// styling), with a semantics label so a screen-reader user hears the
/// journey's current lifecycle state up front.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final closed = status == journeyStatusClosed;
    final label = journeyStatusLabel(l10n, status) ?? status;
    return Semantics(
      label: l10n.journeyStatusSemanticLabel(label),
      child: Container(
        key: const Key('journey-form-status-chip'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: closed
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(BrandDimens.radiusBadge),
        ),
        child: ExcludeSemantics(
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: closed
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

/// Confirmation dialog shown before deleting a journey — mirrors
/// add_activity_screen.dart's [DeleteActivityConfirmDialog] exactly (same
/// field-first-checklist rationale: danger styling via the theme's error
/// color, 44px+ tap targets via [kMinTapTarget], cancel/dismiss is always a
/// no-op). Pulled out as its own public widget for the same testability
/// reason [DeleteActivityConfirmDialog] is.
class DeleteJourneyConfirmDialog extends StatelessWidget {
  const DeleteJourneyConfirmDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('journey-delete-confirm-dialog'),
      icon: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
      title: Text(l10n.deleteJourneyConfirmTitle),
      content: Text(l10n.deleteJourneyConfirmMessage),
      actions: [
        TextButton(
          key: const Key('journey-delete-confirm-cancel'),
          style: TextButton.styleFrom(
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.deleteJourneyCancelAction),
        ),
        TextButton(
          key: const Key('journey-delete-confirm-delete'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.deleteJourneyConfirmAction),
        ),
      ],
    );
  }
}
