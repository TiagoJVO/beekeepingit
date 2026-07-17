import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/field_action_button.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import 'activities_repository.dart';
import 'activity_attributes.dart';
import 'activity_types.dart';

/// Add an activity to [apiaryId] (#39, FR-AC-2), or — when [activityId] is
/// given — edit an existing one (#40, FR-AC-3): select the activity type,
/// fill in an attribute form that ADAPTS to the selected type (only that
/// type's own fields, driven by activity_types.dart/activity_attributes.dart
/// — the same registry the server's api/types.go mirrors), and save.
/// Mirrors apiary_form_screen.dart's own single-screen create/edit pattern
/// ([isEdit]) rather than a separate edit widget, so the adaptive form/
/// validation logic has exactly one implementation for both flows. Delete
/// (#41, FR-AC-4) rides along here too, as a destructive action only shown
/// in edit mode — mirroring [ApiaryFormScreen]'s own delete-button-on-the-
/// edit-form placement, since there is no activities LIST screen yet
/// (#42/#43) to host a swipe-to-delete affordance instead.
///
/// Offline-first (FR-OF-1/Q-SYNC): every write goes straight to the local
/// store via [ActivitiesRepository] — queued for the write-back seam like
/// every other local-first write in this app (apiary_form_screen.dart's own
/// doc comment) — never a direct REST call. Attribution (FR-TEN-2:
/// "recorded against the user who performed it") is derived server-side
/// from the caller's token once the queued write reconciles, not from
/// anything this screen sends.
class AddActivityScreen extends ConsumerStatefulWidget {
  const AddActivityScreen({
    required this.apiaryId,
    this.activityId,
    super.key,
  });

  final String apiaryId;

  /// Null for add (#39); the activity being edited/deleted for edit (#40/#41).
  final String? activityId;

  bool get isEdit => activityId != null;

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
  final _lotBatchController = TextEditingController();
  final _feedAmountController = TextEditingController();
  final _notesController = TextEditingController();
  String? _feedType;
  String? _treatmentContext;
  String? _treatmentType;
  String? _disease;

  @override
  void initState() {
    super.initState();
    if (widget.isEdit) _loadExisting();
  }

  @override
  void dispose() {
    _honeySupersController.dispose();
    _honeyKgController.dispose();
    _hivesInvolvedController.dispose();
    _lotBatchController.dispose();
    _feedAmountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Loads the existing activity and pre-fills the form (#40 AC: "the edit
  /// form reflects the activity's current type and attribute values") —
  /// mirrors apiary_form_screen.dart's `_loadExisting`, including its error
  /// handling (a thrown lookup failure must not leave `_busy` stuck true
  /// forever with no way out) and its "l10n/messenger only read inside the
  /// catch block" rule (looking one up during initState's synchronous
  /// portion, before the first await, throws).
  Future<void> _loadExisting() async {
    setState(() => _busy = true);
    try {
      final repo = await ref.read(activitiesRepositoryProvider.future);
      final existing = await repo.getById(widget.activityId!);
      if (!mounted) return;
      if (existing != null) {
        _selectedType = existing.type;
        _occurredAt = DateTime.tryParse(existing.occurredAt) ?? DateTime.now();
        _populateFromAttributes(existing.type, existing.attributes);
      }
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.activityLoadError('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reverses [_buildAttributes] for [type]/[attrs] into this form's
  /// controllers/dropdown state — the pre-fill half of the edit flow.
  /// Numeric fields render without a trailing `.0` for a whole-number
  /// double (`honey_kg`/`feed_amount`) since the form's own input is
  /// plain decimal text, not a formatted display value.
  void _populateFromAttributes(String type, Map<String, dynamic> attrs) {
    switch (type) {
      case activityTypeHarvest:
        _honeySupersController.text = _numText(attrs['honey_supers']);
        _honeyKgController.text = _numText(attrs['honey_kg']);
        _hivesInvolvedController.text = _numText(attrs['hives_involved']);
        _lotBatchController.text = (attrs['lot_batch'] as String?) ?? '';
      case activityTypeFeeding:
        _feedType = attrs['feed_type'] as String?;
        _feedAmountController.text = _numText(attrs['feed_amount']);
        _hivesInvolvedController.text = _numText(attrs['hives_involved']);
      case activityTypeTreatment:
        _treatmentContext = attrs['treatment_context'] as String?;
        _treatmentType = attrs['treatment_type'] as String?;
        _disease = attrs['disease'] as String?;
        _hivesInvolvedController.text = _numText(attrs['hives_involved']);
    }
    _notesController.text = (attrs['notes'] as String?) ?? '';
  }

  String _numText(dynamic value) {
    if (value == null) return '';
    if (value is num) {
      return value == value.truncate() ? value.truncate().toString() : value.toString();
    }
    return '$value';
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
        final lotBatch = _lotBatchController.text.trim();
        return {
          if (int.tryParse(_honeySupersController.text.trim()) != null)
            'honey_supers': int.parse(_honeySupersController.text.trim()),
          if (double.tryParse(_honeyKgController.text.trim()) != null)
            'honey_kg': double.parse(_honeyKgController.text.trim()),
          if (int.tryParse(_hivesInvolvedController.text.trim()) != null)
            'hives_involved': int.parse(_hivesInvolvedController.text.trim()),
          if (lotBatch.isNotEmpty) 'lot_batch': lotBatch,
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
          if (_disease != null) 'disease': _disease,
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

  /// Saves via [ActivitiesRepository.create] (add) or
  /// [ActivitiesRepository.update] (#40, edit) depending on [isEdit] —
  /// mirrors apiary_form_screen.dart's own `_save`, including reusing the
  /// SAME success/error toast text for both flows (apiarySaveSuccess/Error's
  /// own precedent: one "saved"/"couldn't save" message covers create and
  /// update alike).
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(activitiesRepositoryProvider.future);
      if (widget.isEdit) {
        await repo.update(
          widget.activityId!,
          type: _selectedType,
          occurredAt: _isoDate(_occurredAt),
          attributes: _buildAttributes(),
        );
      } else {
        await repo.create(
          apiaryId: widget.apiaryId,
          type: _selectedType,
          occurredAt: _isoDate(_occurredAt),
          attributes: _buildAttributes(),
        );
      }
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

  /// Delete confirmation (#41 AC: "a confirmation step to prevent accidental
  /// deletion") — mirrors apiary_form_screen.dart's `_confirmDelete`/
  /// [DeleteApiaryConfirmDialog] exactly, including the post-await `mounted`
  /// re-check (the screen could be disposed while the dialog was open).
  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const DeleteActivityConfirmDialog(),
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
      final repo = await ref.read(activitiesRepositoryProvider.future);
      await repo.delete(widget.activityId!);
      if (!mounted) return;
      context.go('/apiaries/${widget.apiaryId}');
      messenger.showSnackBar(SnackBar(content: Text(l10n.activityDeleteSuccess)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(l10n.activityDeleteError('$e'))));
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
                      if (widget.isEdit) ...[
                        const SizedBox(height: 12),
                        SecondaryActionButton(
                          key: const Key('activity-delete-button'),
                          label: l10n.deleteActivity,
                          icon: Icons.delete_outline,
                          destructive: true,
                          onPressed: _confirmDelete,
                        ),
                      ],
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
          // lot_batch (#292, FR-AC-1, D-19): optional free-text lot/batch
          // identifier, capture-side only (export is a separate story).
          TextFormField(
            key: const Key('activity-lot-batch-field'),
            controller: _lotBatchController,
            maxLength: 100,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            validator: (_) => _attrError(l10n, 'lot_batch'),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: l10n.activityLotBatchLabel,
              border: const OutlineInputBorder(),
            ),
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
        // #291 AC: a detection can be logged with no treatment applied yet
        // — treatment_type is optional exactly when the context is
        // detection-only (mirrors the requiredIf in activity_attributes.dart
        // / api/types.go).
        final isDetectionOnly = _treatmentContext == treatmentContextDetectionOnly;
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
            helperText: isDetectionOnly ? l10n.activityTreatmentTypeOptionalForDetectionHint : null,
            onChanged: (v) => setState(() => _treatmentType = v),
          ),
          if (requiresDisease) ...[
            const SizedBox(height: 16),
            _dropdownField(
              l10n: l10n,
              key: 'activity-disease-field',
              label: l10n.activityDiseaseLabel,
              value: _disease,
              options: diseaseConditions,
              attrKey: 'disease',
              onChanged: (v) => setState(() => _disease = v),
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
    String? helperText,
  }) {
    return DropdownButtonFormField<String>(
      key: Key(key),
      initialValue: value,
      isExpanded: true, // see the type-field dropdown's own doc comment above
      // A real validator so an unselected required dropdown (feed_type,
      // treatment_context, treatment_type, disease) blocks Form.validate()
      // (HIGH fix) — a no-op when [attrKey] isn't currently required (e.g.
      // treatment_type for a detection-only report, #291 AC).
      autovalidateMode: AutovalidateMode.onUserInteraction,
      validator: (_) => _attrError(l10n, attrKey),
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
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

/// Confirmation dialog shown before deleting an activity (#41 AC: "a
/// confirmation step to prevent accidental deletion") — mirrors
/// apiary_form_screen.dart's [DeleteApiaryConfirmDialog] exactly (same
/// field-first-checklist rationale: destructive/hard-to-undo actions
/// reserve interruption, danger styling via the theme's error color, 44px+
/// tap targets via [kMinTapTarget], cancel/dismiss is always a no-op). No
/// name/label to interpolate (an activity has none, unlike an apiary) — the
/// message names the action generically instead. Pulled out as its own
/// public widget for the same testability reason
/// [DeleteApiaryConfirmDialog] is: pumpable/testable without the full
/// [AddActivityScreen] needing a real PowerSync-backed repository first.
class DeleteActivityConfirmDialog extends StatelessWidget {
  const DeleteActivityConfirmDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('activity-delete-confirm-dialog'),
      icon: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
      title: Text(l10n.deleteActivityConfirmTitle),
      content: Text(l10n.deleteActivityConfirmMessage),
      actions: [
        TextButton(
          key: const Key('activity-delete-confirm-cancel'),
          style: TextButton.styleFrom(
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.deleteActivityCancelAction),
        ),
        TextButton(
          key: const Key('activity-delete-confirm-delete'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.deleteActivityConfirmAction),
        ),
      ],
    );
  }
}
