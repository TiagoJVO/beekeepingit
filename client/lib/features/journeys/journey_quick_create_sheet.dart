import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
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
/// apiary) and [initialMainActivityType] pre-fills the activity's own type
/// (the natural default for "a journey to match this activity") — both
/// remain editable, since a user might genuinely want a different plan.
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
  required String initialMainActivityType,
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
      initialMainActivityType: initialMainActivityType,
    ),
  );
}

class _JourneyQuickCreateSheet extends ConsumerStatefulWidget {
  const _JourneyQuickCreateSheet({
    required this.initialApiaryId,
    required this.initialMainActivityType,
  });

  final String initialApiaryId;
  final String initialMainActivityType;

  @override
  ConsumerState<_JourneyQuickCreateSheet> createState() =>
      _JourneyQuickCreateSheetState();
}

class _JourneyQuickCreateSheetState
    extends ConsumerState<_JourneyQuickCreateSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  late String _mainActivityType = widget.initialMainActivityType;
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
        mainActivityType: _mainActivityType,
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
          16,
          16,
          16,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.journeyQuickCreateTitle,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('journey-quick-create-name-field'),
                  controller: _nameController,
                  maxLength: 200,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? l10n.journeyNameRequired
                      : null,
                  decoration: InputDecoration(
                    labelText: l10n.journeyNameLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: const Key(
                    'journey-quick-create-main-activity-type-field',
                  ),
                  initialValue: _mainActivityType,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.journeyMainActivityTypeLabel,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final type in knownActivityTypes)
                      DropdownMenuItem(
                        value: type,
                        child: Text(activityTypeLabel(l10n, type) ?? type),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _mainActivityType = value);
                    }
                  },
                ),
                const SizedBox(height: 16),
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
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: SecondaryActionButton(
                        key: const Key('journey-quick-create-cancel-button'),
                        label: l10n.journeyQuickCreateCancelAction,
                        busy: false,
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).pop(),
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
        ),
      ),
    );
  }
}
