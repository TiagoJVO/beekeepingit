import '../../l10n/gen/app_localizations.dart';
import 'activities_repository.dart';
import 'activity_types.dart';

/// A short, list-row-sized summary of an activity's own type-specific
/// attributes (#42/#43) — reuses the SAME field labels the add-activity form
/// already shows (add_activity_screen.dart's `.arb` keys), rather than
/// inventing a second, parallel "list view" vocabulary that could drift out
/// of sync with the form's own labels. Free-text `notes` is deliberately
/// excluded from this one-line summary — it can be arbitrarily long (#38's
/// 10000-char cap) — full notes are for a future detail view, not this
/// compact row.
String activitySummaryLine(AppLocalizations l10n, Activity activity) {
  final parts = _typeSpecificParts(l10n, activity.type, activity.attributes);
  return parts.isEmpty ? l10n.activityNoAttributesSummary : parts.join(' · ');
}

List<String> _typeSpecificParts(
  AppLocalizations l10n,
  String type,
  Map<String, dynamic> attrs,
) {
  switch (type) {
    case activityTypeHarvest:
      return [
        if (attrs['honey_supers'] != null)
          '${l10n.activityHoneySupersLabel}: ${attrs['honey_supers']}',
        if (attrs['honey_kg'] != null)
          '${l10n.activityHoneyKgLabel}: ${attrs['honey_kg']}',
        if (attrs['hives_involved'] != null)
          '${l10n.activityHivesInvolvedLabel}: ${attrs['hives_involved']}',
        if (attrs['lot_batch'] != null)
          '${l10n.activityLotBatchLabel}: ${attrs['lot_batch']}',
      ];
    case activityTypeFeeding:
      return [
        if (attrs['feed_type'] != null)
          '${l10n.activityFeedTypeLabel}: ${attrs['feed_type']}',
        if (attrs['feed_amount'] != null)
          '${l10n.activityFeedAmountLabel}: ${attrs['feed_amount']}',
        if (attrs['hives_involved'] != null)
          '${l10n.activityHivesInvolvedLabel}: ${attrs['hives_involved']}',
      ];
    case activityTypeTreatment:
      final context = attrs['treatment_context'] as String?;
      return [
        if (attrs['treatment_type'] != null)
          '${l10n.activityTreatmentTypeLabel}: ${attrs['treatment_type']}',
        if (context != null) treatmentContextLabel(l10n, context) ?? context,
        if (attrs['disease'] != null)
          '${l10n.activityDiseaseLabel}: ${attrs['disease']}',
        if (attrs['hives_involved'] != null)
          '${l10n.activityHivesInvolvedLabel}: ${attrs['hives_involved']}',
      ];
    default: // activityTypeGeneric, and any unknown future type — nothing
      // beyond notes to summarize, and notes are excluded (see file doc).
      return const [];
  }
}

/// The attribution display text for one activity (#44, FR-TEN-2), resolved in
/// precedence order:
///
/// 1. [l10n]'s "Unknown" when [Activity.performedBy] is null/empty (an
///    optimistic local write not yet synced back with its server-stamped
///    performer).
/// 2. "You" when [Activity.performedBy] matches [currentUserId] — shown in
///    preference to the caller's own name.
/// 3. The performer's real display name, when [memberNames] carries a
///    non-empty entry for [Activity.performedBy]. [memberNames] is the
///    caller's org roster (`user_id -> name`) from `memberNamesProvider`
///    (members_repository.dart), backed by the non-admin-safe
///    `GET /organizations/{orgId}/members/names` endpoint (#44 follow-up) —
///    the capability that let this function stop fabricating placeholders.
/// 4. A short, stable, non-spoofable id fragment (`Member <last-8>`) as the
///    fallback when no name is available: a member with an incomplete profile,
///    one who has since been removed, or simply the offline / pre-first-fetch
///    case where the online-only roster hasn't loaded yet. Distinguishable per
///    performer (satisfying "attribution remains visible per activity",
///    FR-TEN-2) without inventing a name the app doesn't have.
///
/// [memberNames] defaults to empty, so a caller that hasn't wired the roster
/// (or is offline) keeps exactly the pre-#44 short-id behavior.
String activityAttributionText(
  AppLocalizations l10n,
  Activity activity,
  String? currentUserId, {
  Map<String, String> memberNames = const {},
}) {
  final performedBy = activity.performedBy;
  if (performedBy == null || performedBy.isEmpty) {
    return l10n.activityPerformedByUnknown;
  }
  if (performedBy == currentUserId) return l10n.activityPerformedByYou;
  final name = memberNames[performedBy];
  if (name != null && name.isNotEmpty) return name;
  return l10n.activityPerformedByMember(_shortId(performedBy));
}

/// The last 8 characters of a UUID — enough to visually distinguish
/// different performers within one org's activity list without printing the
/// full 36-character id on every row.
String _shortId(String id) => id.length <= 8 ? id : id.substring(id.length - 8);
