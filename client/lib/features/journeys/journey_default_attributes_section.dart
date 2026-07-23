import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../activities/activity_types.dart';

/// Mutable holder for the "Defaults for activities" form state (#385) —
/// shared by journey_form_screen.dart (create/edit, type editable) and
/// journey_quick_create_sheet.dart (create, type locked) so both screens
/// build/populate/reset the exact same per-type field set from ONE
/// implementation rather than two drifting copies. Every field mirrors an
/// activity attribute key (activity_attributes.dart's schema), but nothing
/// here is ever REQUIRED — these are optional journey-level defaults, not a
/// real activity's own attributes.
class JourneyDefaultAttributesController {
  String? treatmentContext;
  String? treatmentType;
  String? disease;
  String? feedType;
  final lotBatchController = TextEditingController();

  void dispose() => lotBatchController.dispose();

  /// Reverses [attrs] onto this controller's fields for [type] — the
  /// pre-fill half of the edit flow (mirrors add_activity_screen.dart's
  /// `_populateFromAttributes`). Always [reset]s first so stale state from a
  /// previously-loaded type never leaks through.
  void populate(String type, Map<String, dynamic> attrs) {
    reset();
    switch (type) {
      case activityTypeTreatment:
        treatmentContext = attrs['treatment_context'] as String?;
        treatmentType = attrs['treatment_type'] as String?;
        disease = attrs['disease'] as String?;
      case activityTypeFeeding:
        feedType = attrs['feed_type'] as String?;
      case activityTypeHarvest:
        lotBatchController.text = (attrs['lot_batch'] as String?) ?? '';
    }
  }

  /// Clears every field — called whenever the journey's main_activity_type
  /// changes (the old type's keys are invalid for the new type, #385's own
  /// design decision: "changing the type dropdown clears the defaults
  /// state").
  void reset() {
    treatmentContext = null;
    treatmentType = null;
    disease = null;
    feedType = null;
    lotBatchController.clear();
  }

  /// Builds the `default_attributes` map to persist for [type] — omits any
  /// field left unset (a null dropdown or blank text field never appears as
  /// a key), mirroring [Journey.defaultAttributes]'s "empty map means none"
  /// convention (journeys_repository.dart).
  Map<String, dynamic> build(String type) {
    switch (type) {
      case activityTypeTreatment:
        return {
          if (treatmentContext != null) 'treatment_context': treatmentContext,
          if (treatmentType != null) 'treatment_type': treatmentType,
          if (disease != null) 'disease': disease,
        };
      case activityTypeFeeding:
        return {if (feedType != null) 'feed_type': feedType};
      case activityTypeHarvest:
        final lotBatch = lotBatchController.text.trim();
        return {if (lotBatch.isNotEmpty) 'lot_batch': lotBatch};
      default: // generic — no subtype defaults
        return const {};
    }
  }
}

/// The optional "Defaults for activities" section (#385): adapts to [type],
/// rendering nothing (a zero-height [SizedBox]) for a type with no subtype
/// defaults (generic). Every field is OPTIONAL — no [TextFormField]/
/// [DropdownButtonFormField] validators here — this only ever prefills a
/// LATER activity's own (fully-validated) attribute fields (the separate
/// prefill issue); it never blocks saving the journey itself. A
/// [StatelessWidget]: [controller] is a mutable holder the caller owns, and
/// [onChanged] is expected to trigger the caller's own `setState` (or
/// equivalent) so a field edit here is reflected on rebuild — mirrors how
/// [ApiaryMultiSelectField]'s callback-driven state lives in its parent.
class JourneyDefaultAttributesSection extends StatelessWidget {
  const JourneyDefaultAttributesSection({
    required this.type,
    required this.controller,
    required this.onChanged,
    super.key,
  });

  final String type;
  final JourneyDefaultAttributesController controller;

  /// Called after any field changes.
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fields = _fields(context, l10n);
    if (fields.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: BrandDimens.gapField),
        Text(
          l10n.journeyDefaultAttributesSectionLabel,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        for (final field in fields) ...[
          field,
          const SizedBox(height: BrandDimens.gapField),
        ],
      ],
    );
  }

  List<Widget> _fields(BuildContext context, AppLocalizations l10n) {
    switch (type) {
      case activityTypeTreatment:
        final requiresDisease =
            controller.treatmentContext == treatmentContextDiseaseSpecific ||
            controller.treatmentContext == treatmentContextDetectionOnly;
        return [
          _dropdown(
            context,
            l10n: l10n,
            key: 'journey-default-treatment-context-field',
            label: l10n.activityTreatmentContextFieldLabel,
            value: controller.treatmentContext,
            options: treatmentContexts,
            optionLabel: (v) => treatmentContextLabel(l10n, v) ?? v,
            onChanged: (v) => controller.treatmentContext = v,
          ),
          _dropdown(
            context,
            l10n: l10n,
            key: 'journey-default-treatment-type-field',
            label: l10n.activityTreatmentTypeLabel,
            value: controller.treatmentType,
            options: treatmentTypes,
            onChanged: (v) => controller.treatmentType = v,
          ),
          if (requiresDisease)
            _dropdown(
              context,
              l10n: l10n,
              key: 'journey-default-disease-field',
              label: l10n.activityDiseaseLabel,
              value: controller.disease,
              options: diseaseConditions,
              onChanged: (v) => controller.disease = v,
            ),
        ];
      case activityTypeFeeding:
        return [
          _dropdown(
            context,
            l10n: l10n,
            key: 'journey-default-feed-type-field',
            label: l10n.activityFeedTypeLabel,
            value: controller.feedType,
            options: feedTypes,
            onChanged: (v) => controller.feedType = v,
          ),
        ];
      case activityTypeHarvest:
        return [
          TextFormField(
            key: const Key('journey-default-lot-batch-field'),
            controller: controller.lotBatchController,
            maxLength: 100,
            decoration: InputDecoration(labelText: l10n.activityLotBatchLabel),
            onChanged: (_) => onChanged(),
          ),
        ];
      default: // generic — no subtype defaults
        return const [];
    }
  }

  Widget _dropdown(
    BuildContext context, {
    required AppLocalizations l10n,
    required String key,
    required String label,
    required String? value,
    required List<String> options,
    required void Function(String?) onChanged,
    String Function(String)? optionLabel,
  }) {
    return DropdownButtonFormField<String>(
      key: Key(key),
      initialValue: value,
      isExpanded: true, // long localized labels can overflow otherwise
      decoration: InputDecoration(labelText: label),
      items: [
        DropdownMenuItem(child: Text(l10n.journeyDefaultsNotSetOption)),
        for (final option in options)
          DropdownMenuItem(
            value: option,
            child: Text(optionLabel == null ? option : optionLabel(option)),
          ),
      ],
      onChanged: (v) {
        onChanged(v);
        this.onChanged();
      },
    );
  }
}
