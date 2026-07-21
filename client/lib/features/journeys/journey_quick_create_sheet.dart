import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_widgets.dart';
import '../activities/activity_types.dart';
import 'apiary_multi_select_field.dart';
import 'journeys_repository.dart';

/// The #46 activity-form picker's inline "create a new journey" shortcut
/// (AC: "name + apiaries + main activity") — creates the journey WITHOUT
/// leaving the activity form, then the caller (add_activity_screen.dart)
/// attaches the just-created journey to the activity being logged.
///
/// Deliberately a NEW, smaller widget rather than reusing
/// [JourneyFormScreen] directly: that screen is coupled to full-page routing
/// (`context.go('/journeys')` on save, its own app-bar title, delete/close
/// actions that don't apply here) — none of which belongs in a bottom sheet
/// launched mid-way through logging an activity. Instead this reuses the
/// same UNDERLYING pieces [JourneyFormScreen] itself uses for the fields
/// this shortcut actually needs (name + main activity type + apiaries):
/// [ApiaryMultiSelectField] verbatim, the same activity-type dropdown
/// pattern, and [JourneysRepository.create] — the same validation rules
/// (name required, at least one apiary), just condensed into a sheet that
/// returns the new journey's id (or null if canceled) instead of navigating
/// anywhere.
///
/// [initialApiaryId] pre-selects the apiary the activity is being logged
/// against (the natural default — this journey is being created FOR this
/// apiary); it remains editable, since a user might genuinely want the plan
/// to span more apiaries.
///
/// [mainActivityType] is the activity's own type and is **locked** here (not
/// merely pre-filled): an activity can only attach to a journey whose main
/// activity type matches it (D-21 — the normal picker only ever offers
/// type-matching journeys via `journeyMatchesProvider`), so letting this
/// inline shortcut pick a *different* type would create a journey the
/// activity cannot correctly attach to (#343). The field is shown read-only
/// so the user sees what type the new journey will carry, without being able
/// to diverge from the activity being registered.
///
/// Returns both the new journey's id AND its entered name (not just the id):
/// the caller (add_activity_screen.dart) displays the name immediately in
/// its "attached to" summary, before the local store's own live query
/// (journey_picker.dart's `journeyMatchesProvider`) necessarily catches up
/// with the just-created row — returning the name sidesteps that race
/// instead of the display briefly showing a raw id or "unknown".
Future<({String id, String name})?> showJourneyQuickCreateSheet(
  BuildContext context, {
  required String initialApiaryId,
  required String mainActivityType,
}) {
  return showModalBottomSheet<({String id, String name})>(
    context: context,
    isScrollControlled: true,
    // A quick-create form mid-flow shouldn't vanish on an accidental
    // outside tap — mirrors a full-page form's own "you must explicitly
    // cancel/save" expectation, unlike the plain picker list above.
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _JourneyQuickCreateSheet(
      initialApiaryId: initialApiaryId,
      mainActivityType: mainActivityType,
    ),
  );
}

class _JourneyQuickCreateSheet extends ConsumerStatefulWidget {
  const _JourneyQuickCreateSheet({
    required this.initialApiaryId,
    required this.mainActivityType,
  });

  final String initialApiaryId;
  final String mainActivityType;

  @override
  ConsumerState<_JourneyQuickCreateSheet> createState() =>
      _JourneyQuickCreateSheetState();
}

class _JourneyQuickCreateSheetState
    extends ConsumerState<_JourneyQuickCreateSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  late Set<String> _apiaryIds = {widget.initialApiaryId};
  bool _busy = false;
  String? _apiaryIdsError;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool _validate(AppLocalizations l10n) {
    final formOk = _formKey.currentState!.validate();
    final hasApiary = _apiaryIds.isNotEmpty;
    setState(() {
      _apiaryIdsError = hasApiary ? null : l10n.journeyApiariesRequired;
    });
    return formOk && hasApiary;
  }

  Future<void> _create() async {
    final l10n = AppLocalizations.of(context);
    if (!_validate(l10n)) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(journeysRepositoryProvider.future);
      final name = _nameController.text.trim();
      final id = await repo.create(
        name: name,
        mainActivityType: widget.mainActivityType,
        apiaryIds: _apiaryIds.toList(),
      );
      if (!mounted) return;
      Navigator.of(context).pop((id: id, name: name));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.journeySaveError('$e'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          BrandDimens.gutter,
          BrandDimens.gutter,
          BrandDimens.gutter,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        // The fields scroll, the action row stays pinned: with the
        // gloves-friendly control heights (58px fields, 60px primary button —
        // BrandDimens) this sheet's natural height exceeds a small phone's
        // viewport, and a single scroll view around EVERYTHING would push
        // Save/Cancel below the fold where a user in the field can't reach
        // them. Keeping the actions outside the scrollable keeps them
        // reachable at any screen size, text scale, or future field count —
        // the same structure todo_quick_create_sheet.dart uses.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SectionHeader(l10n.journeyQuickCreateTitle),
                      const SizedBox(height: BrandDimens.gapField),
                      LabeledField(
                        label: l10n.journeyNameLabel,
                        child: TextFormField(
                          key: const Key('journey-quick-create-name-field'),
                          controller: _nameController,
                          maxLength: 200,
                          autovalidateMode: AutovalidateMode.onUserInteraction,
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? l10n.journeyNameRequired
                              : null,
                        ),
                      ),
                      const SizedBox(height: BrandDimens.gapField),
                      LabeledField(
                        label: l10n.journeyMainActivityTypeLabel,
                        // Locked to the activity being registered (#343): an
                        // activity can only attach to a type-matching journey
                        // (D-21), so this inline shortcut must not be able to
                        // pick a divergent type. Rendered as a disabled
                        // dropdown (onChanged: null) — visible and
                        // screen-reader-legible, but not changeable.
                        child: DropdownButtonFormField<String>(
                          key: const Key(
                            'journey-quick-create-main-activity-type-field',
                          ),
                          initialValue: widget.mainActivityType,
                          isExpanded: true,
                          items: [
                            DropdownMenuItem(
                              value: widget.mainActivityType,
                              child: Text(
                                activityTypeLabel(
                                      l10n,
                                      widget.mainActivityType,
                                    ) ??
                                    widget.mainActivityType,
                              ),
                            ),
                          ],
                          onChanged: null,
                          disabledHint: Text(
                            activityTypeLabel(l10n, widget.mainActivityType) ??
                                widget.mainActivityType,
                          ),
                        ),
                      ),
                      const SizedBox(height: BrandDimens.gapField),
                      ApiaryMultiSelectField(
                        selectedApiaryIds: _apiaryIds,
                        onChanged: (ids) => setState(() {
                          _apiaryIds = ids;
                          _apiaryIdsError = null;
                        }),
                      ),
                      if (_apiaryIdsError != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, left: 4),
                          child: Text(
                            _apiaryIdsError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: SecondaryActionButton(
                    key: const Key('journey-quick-create-cancel-button'),
                    label: l10n.journeyQuickCreateCancelAction,
                    busy: false,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PrimaryActionButton(
                    key: const Key('journey-quick-create-save-button'),
                    label: l10n.saveButton,
                    busy: _busy,
                    onPressed: _create,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
