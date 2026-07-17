import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import 'activities_repository.dart';
import 'activity_attributes.dart';
import 'activity_types.dart';

/// Add an activity to [apiaryId] (#39, FR-AC-2): select the activity type,
/// fill in an attribute form that ADAPTS to the selected type (only that
/// type's own fields, driven by activity_types.dart/activity_attributes.dart
/// — the same registry the server's api/types.go mirrors), and save.
/// Editing/deleting/listing activities are later EPIC-03 stories (#40-#43);
/// this screen only adds.
///
/// Offline-first (FR-OF-1/Q-SYNC): the write goes straight to the local
/// store via [ActivitiesRepository.create] — queued for the write-back seam
/// like every other local-first write in this app (apiary_form_screen.dart's
/// own doc comment) — never a direct REST call. Attribution
/// (FR-TEN-2: "recorded against the user who performed it") is derived
/// server-side from the caller's token once the queued write reconciles,
/// not from anything this screen sends.
class AddActivityScreen extends ConsumerStatefulWidget {
  const AddActivityScreen({required this.apiaryId, super.key});

  final String apiaryId;

  @override
  ConsumerState<AddActivityScreen> createState() => _AddActivityScreenState();
}

class _AddActivityScreenState extends ConsumerState<AddActivityScreen> {
  final _formKey = GlobalKey<FormState>();

  String _selectedType = activityTypeHarvest;
  DateTime _occurredAt = DateTime.now();
  bool _busy = false;

  // One controller per possible attribute key across every type (#38's
  // FR-AC-1 schema) — only the ones relevant to [_selectedType] are shown
  // and read at save time (_buildAttributes), so stale text left in a
  // hidden field from a previous type selection is simply never read.
  final _honeySupersController = TextEditingController();
  final _honeyKgController = TextEditingController();
  final _hivesInvolvedController = TextEditingController();
  final _feedAmountController = TextEditingController();
  final _diseaseController = TextEditingController();
  final _notesController = TextEditingController();
  String? _feedType;
  String? _treatmentContext;
  String? _treatmentType;

  @override
  void dispose() {
    _honeySupersController.dispose();
    _honeyKgController.dispose();
    _hivesInvolvedController.dispose();
    _feedAmountController.dispose();
    _diseaseController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _occurredAt = picked);
  }

  /// Builds the per-[_selectedType] attribute bag — ONLY that type's own
  /// keys (an extra key is rejected server-side, api/types.go's
  /// ValidateActivity), omitting a field entirely when it's empty/unset
  /// rather than sending an empty string/null, so [validateActivityAttributes]
  /// treats it as "absent" (its own required-field check, not a
  /// present-but-blank value).
  Map<String, dynamic> _buildAttributes() {
    final notes = _notesController.text.trim();
    switch (_selectedType) {
      case activityTypeHarvest:
        return {
          if (int.tryParse(_honeySupersController.text.trim()) != null)
            'honey_supers': int.parse(_honeySupersController.text.trim()),
          if (double.tryParse(_honeyKgController.text.trim()) != null)
            'honey_kg': double.parse(_honeyKgController.text.trim()),
          if (int.tryParse(_hivesInvolvedController.text.trim()) != null)
            'hives_involved': int.parse(_hivesInvolvedController.text.trim()),
          if (notes.isNotEmpty) 'notes': notes,
        };
      case activityTypeFeeding:
        return {
          if (_feedType != null) 'feed_type': _feedType,
          if (double.tryParse(_feedAmountController.text.trim()) != null)
            'feed_amount': double.parse(_feedAmountController.text.trim()),
          if (int.tryParse(_hivesInvolvedController.text.trim()) != null)
            'hives_involved': int.parse(_hivesInvolvedController.text.trim()),
          if (notes.isNotEmpty) 'notes': notes,
        };
      case activityTypeTreatment:
        return {
          if (_treatmentContext != null) 'treatment_context': _treatmentContext,
          if (_treatmentType != null) 'treatment_type': _treatmentType,
          if (_diseaseController.text.trim().isNotEmpty)
            'disease': _diseaseController.text.trim(),
          if (int.tryParse(_hivesInvolvedController.text.trim()) != null)
            'hives_involved': int.parse(_hivesInvolvedController.text.trim()),
          if (notes.isNotEmpty) 'notes': notes,
        };
      default: // activityTypeGeneric
        return {if (notes.isNotEmpty) 'notes': notes};
    }
  }

  /// A field's validation message from the shared client-side mirror
  /// (activity_attributes.dart's [validateActivityAttributes] — the same
  /// rules services/activities/api/types.go's ValidateActivity enforces
  /// server-side, D-12's "client revalidates against the same rules"), or
  /// null when [key] is currently valid. [ActivityAttributeError.message]
  /// itself is plain (server-mirroring) English, not localized, so this
  /// maps by [ActivityAttributeError.code] to a localized string instead of
  /// displaying it directly.
  ///
  /// This is wired as each field's `validator:` (not merely as a cosmetic
  /// `errorText`), so `_formKey.currentState!.validate()` in [_save]
  /// genuinely returns false — and blocks the write — when a required
  /// attribute (e.g. `honey_supers`, `feed_type`, `feed_amount`,
  /// `treatment_context`/`treatment_type`, the conditionally-required
  /// `disease`) is missing or invalid, rather than queuing a payload the
  /// server would only reject at sync time (D-12: catch it on the client
  /// against the same rules the server applies).
  String? _attrError(AppLocalizations l10n, String key) {
    for (final e in validateActivityAttributes(
      _selectedType,
      _buildAttributes(),
    )) {
      if (e.field == 'attributes.$key') {
        return e.code == 'required'
            ? l10n.activityFieldRequired
            : l10n.activityFieldInvalid;
      }
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(activitiesRepositoryProvider.future);
      await repo.create(
        apiaryId: widget.apiaryId,
        type: _selectedType,
        occurredAt: _isoDate(_occurredAt),
        attributes: _buildAttributes(),
      );
      if (!mounted) return;
      context.go('/apiaries/${widget.apiaryId}');
      messenger.showSnackBar(SnackBar(content: Text(l10n.activitySaveSuccess)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.activitySaveError('$e'))),
      );
    }
  }

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return _busy
        ? const Center(child: CircularProgressIndicator())
        : Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      DropdownButtonFormField<String>(
                        key: const Key('activity-type-field'),
                        initialValue: _selectedType,
                        // isExpanded: a treatment-context/type option's
                        // localized label (e.g. "Specific disease/condition")
                        // can be longer than the field's intrinsic width —
                        // without this the dropdown's internal Row overflows
                        // rather than truncating/wrapping to the available
                        // width.
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: l10n.activityTypeFieldLabel,
                          border: const OutlineInputBorder(),
                        ),
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
                            setState(() => _selectedType = value);
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      InkWell(
                        key: const Key('activity-occurred-at-field'),
                        onTap: _pickDate,
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: l10n.activityOccurredAtLabel,
                            border: const OutlineInputBorder(),
                          ),
                          child: Text(
                            LocaleFormatting.of(context).date(_occurredAt),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ..._attributeFields(l10n),
                      const SizedBox(height: 24),
                      PrimaryActionButton(
                        key: const Key('activity-save-button'),
                        label: l10n.saveButton,
                        onPressed: _save,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
  }

  /// The adaptive attribute-field list for [_selectedType] (#39 AC: "the
  /// attribute form adapts to the selected type, showing only that type's
  /// relevant fields") — every list ends with the shared free-text notes
  /// field (FR-AC-1: every type carries notes).
  List<Widget> _attributeFields(AppLocalizations l10n) {
    switch (_selectedType) {
      case activityTypeHarvest:
        return [
          _numberField(
            l10n: l10n,
            key: 'activity-honey-supers-field',
            controller: _honeySupersController,
            label: l10n.activityHoneySupersLabel,
            attrKey: 'honey_supers',
            integerOnly: true,
          ),
          const SizedBox(height: 16),
          _numberField(
            l10n: l10n,
            key: 'activity-honey-kg-field',
            controller: _honeyKgController,
            label: l10n.activityHoneyKgLabel,
            attrKey: 'honey_kg',
          ),
          const SizedBox(height: 16),
          _numberField(
            l10n: l10n,
            key: 'activity-hives-involved-field',
            controller: _hivesInvolvedController,
            label: l10n.activityHivesInvolvedLabel,
            attrKey: 'hives_involved',
            integerOnly: true,
          ),
          const SizedBox(height: 16),
          _notesField(l10n),
        ];
      case activityTypeFeeding:
        return [
          _dropdownField(
            l10n: l10n,
            key: 'activity-feed-type-field',
            label: l10n.activityFeedTypeLabel,
            value: _feedType,
            options: feedTypes,
            attrKey: 'feed_type',
            onChanged: (v) => setState(() => _feedType = v),
          ),
          const SizedBox(height: 16),
          _numberField(
            l10n: l10n,
            key: 'activity-feed-amount-field',
            controller: _feedAmountController,
            label: l10n.activityFeedAmountLabel,
            attrKey: 'feed_amount',
          ),
          const SizedBox(height: 16),
          _numberField(
            l10n: l10n,
            key: 'activity-hives-involved-field',
            controller: _hivesInvolvedController,
            label: l10n.activityHivesInvolvedLabel,
            attrKey: 'hives_involved',
            integerOnly: true,
          ),
          const SizedBox(height: 16),
          _notesField(l10n),
        ];
      case activityTypeTreatment:
        final requiresDisease =
            _treatmentContext == treatmentContextDiseaseSpecific ||
            _treatmentContext == treatmentContextDetectionOnly;
        return [
          _dropdownField(
            l10n: l10n,
            key: 'activity-treatment-context-field',
            label: l10n.activityTreatmentContextFieldLabel,
            value: _treatmentContext,
            options: treatmentContexts,
            attrKey: 'treatment_context',
            optionLabel: (v) => treatmentContextLabel(l10n, v) ?? v,
            onChanged: (v) => setState(() => _treatmentContext = v),
          ),
          const SizedBox(height: 16),
          _dropdownField(
            l10n: l10n,
            key: 'activity-treatment-type-field',
            label: l10n.activityTreatmentTypeLabel,
            value: _treatmentType,
            options: treatmentTypes,
            attrKey: 'treatment_type',
            onChanged: (v) => setState(() => _treatmentType = v),
          ),
          if (requiresDisease) ...[
            const SizedBox(height: 16),
            TextFormField(
              key: const Key('activity-disease-field'),
              controller: _diseaseController,
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (_) => _attrError(l10n, 'disease'),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: l10n.activityDiseaseLabel,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 16),
          _numberField(
            l10n: l10n,
            key: 'activity-hives-involved-field',
            controller: _hivesInvolvedController,
            label: l10n.activityHivesInvolvedLabel,
            attrKey: 'hives_involved',
            integerOnly: true,
          ),
          const SizedBox(height: 16),
          _notesField(l10n),
        ];
      default: // activityTypeGeneric
        return [_notesField(l10n)];
    }
  }

  Widget _notesField(AppLocalizations l10n) => TextFormField(
    key: const Key('activity-notes-field'),
    controller: _notesController,
    minLines: 3,
    maxLines: 6,
    maxLength: 10000,
    textInputAction: TextInputAction.newline,
    autovalidateMode: AutovalidateMode.onUserInteraction,
    validator: (_) => _attrError(l10n, 'notes'),
    decoration: InputDecoration(
      labelText: l10n.activityNotesLabel,
      border: const OutlineInputBorder(),
      alignLabelWithHint: true,
    ),
  );

  Widget _numberField({
    required AppLocalizations l10n,
    required String key,
    required TextEditingController controller,
    required String label,
    required String attrKey,
    bool integerOnly = false,
  }) {
    return TextFormField(
      key: Key(key),
      controller: controller,
      keyboardType: TextInputType.numberWithOptions(decimal: !integerOnly),
      inputFormatters: integerOnly
          ? [FilteringTextInputFormatter.digitsOnly]
          : [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
      // A real validator (not a cosmetic errorText) so Form.validate() in
      // _save() genuinely blocks submission when a required numeric
      // attribute is missing/invalid (HIGH review fix).
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (_) => _attrError(l10n, attrKey),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _dropdownField({
    required AppLocalizations l10n,
    required String key,
    required String label,
    required String? value,
    required List<String> options,
    required String attrKey,
    required void Function(String?) onChanged,
    String Function(String)? optionLabel,
  }) {
    return DropdownButtonFormField<String>(
      key: Key(key),
      initialValue: value,
      isExpanded: true, // see the type-field dropdown's own doc comment above
      // A real validator so an unselected required dropdown (feed_type,
      // treatment_context, treatment_type) blocks Form.validate() (HIGH fix).
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (_) => _attrError(l10n, attrKey),
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final option in options)
          DropdownMenuItem(
            value: option,
            child: Text(optionLabel == null ? option : optionLabel(option)),
          ),
      ],
      onChanged: (v) => setState(() => onChanged(v)),
    );
  }
}
