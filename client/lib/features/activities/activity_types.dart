import '../../l10n/gen/app_localizations.dart';

/// The known activity types (#38, FR-AC-1) — the client mirror of the owning
/// service's registry (services/activities/api/types.go's typeSchemas).
/// Adding a future activity type is a code-only append: a new const + list
/// entry here and in the Go registry, a label case in [activityTypeLabel]
/// with its EN/PT `.arb` strings, and an entry in
/// [activity_attributes.dart]'s schema map — no migration to the
/// `activities.activities` table or its `attributes` JSONB column (FR-AC-1
/// AC: "new types = code-only"), mirroring how
/// features/apiaries/counter_types.dart mirrors counters.go.
const activityTypeHarvest = 'harvest';
const activityTypeFeeding = 'feeding';
const activityTypeTreatment = 'treatment';
const activityTypeGeneric = 'generic';

/// Ordered as a type picker would list them: the three attribute-carrying
/// types first (harvest, feeding, treatment — prototype.md's Cresta /
/// Alimentação / Tratamento), generic last as the catch-all.
const knownActivityTypes = [
  activityTypeHarvest,
  activityTypeFeeding,
  activityTypeTreatment,
  activityTypeGeneric,
];

/// The localized display label for an activity type, or null for a type this
/// client version doesn't know (an unknown/newer type replicated down from a
/// newer server — degrade gracefully rather than rendering raw internals,
/// same convention as counter_types.dart's counterValueLabel).
String? activityTypeLabel(AppLocalizations l10n, String type) {
  return switch (type) {
    activityTypeHarvest => l10n.activityTypeHarvestLabel,
    activityTypeFeeding => l10n.activityTypeFeedingLabel,
    activityTypeTreatment => l10n.activityTypeTreatmentLabel,
    activityTypeGeneric => l10n.activityTypeGenericLabel,
    _ => null,
  };
}

/// Controlled candidate vocabularies (FR-AC-1 AC: "extensible, not a closed
/// enum") — the client mirror of services/activities/api/types.go's
/// FeedTypes/TreatmentTypes. These are already human-readable PT product/
/// treatment names used directly as the stored attribute value (not
/// translated concepts, unlike the activity-type/treatment-context labels
/// above), so no `.arb` entry is needed per value — extending a vocabulary
/// is a code-only append here AND in the Go set, kept in lockstep by the
/// mirrored unit tests (activity_types_test.dart, types_test.go).
const feedTypes = ['Xarope 1:1', 'Xarope 2:1', 'Candi', 'Pólen'];
const treatmentTypes = ['Apivar/amitraz', 'Ácido oxálico', 'Timol', 'Outro'];

/// Treatment-context values (#38, FR-AC-1, confirmed 2026-07-16 as committed
/// v1 scope): whether a treatment is general/preventive, tied to a specific
/// named disease/condition, or a detection-only report. Mirrors
/// services/activities/api/types.go's TreatmentContext* constants.
const treatmentContextGeneral = 'general_preventive';
const treatmentContextDiseaseSpecific = 'disease_specific';
const treatmentContextDetectionOnly = 'detection_only';

const treatmentContexts = [
  treatmentContextGeneral,
  treatmentContextDiseaseSpecific,
  treatmentContextDetectionOnly,
];

/// The localized display label for a treatment context, or null for an
/// unknown value (same graceful-degradation convention as
/// [activityTypeLabel]).
String? treatmentContextLabel(AppLocalizations l10n, String context) {
  return switch (context) {
    treatmentContextGeneral => l10n.treatmentContextGeneralLabel,
    treatmentContextDiseaseSpecific => l10n.treatmentContextDiseaseSpecificLabel,
    treatmentContextDetectionOnly => l10n.treatmentContextDetectionOnlyLabel,
    _ => null,
  };
}
