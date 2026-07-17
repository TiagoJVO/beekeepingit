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

/// The attribution display text for one activity (#44, FR-TEN-2): [l10n]'s
/// "You" when [currentUserId] matches [Activity.performedBy], otherwise a
/// short, per-performer-distinguishable placeholder.
///
/// There is deliberately no attempt to resolve [Activity.performedBy] to a
/// real display name: neither the client nor the server currently expose
/// one anywhere reachable by a non-admin org member —
/// contracts/openapi/organizations.openapi.yaml's `Member` schema carries
/// only `user_id`/`role`/`status` (no name/email), the one endpoint that
/// DOES return a name (`GET /v1/profile`) only ever returns the CALLER's
/// own profile, and the member/invitation list endpoints that could
/// otherwise cross-reference an id to at least confirm identity are
/// admin-only server-side (services/organizations/api/invitations.go's
/// `registerMemberAndInvitationRoutes` doc comment) — so a plain member
/// couldn't use them to build a lookup even client-side. This is a real
/// product gap (see FOLLOWUPS.md), not an oversight here: every OTHER
/// member's activity is shown against a short, stable, non-spoofable id
/// fragment instead of an invented name — distinguishable per performer
/// (satisfying "attribution remains visible per activity", FR-TEN-2)
/// without fabricating a display name the app has no way to know. A future
/// member-display-name capability (e.g. a non-admin-safe roster endpoint)
/// slots in here without changing any caller of this function.
String activityAttributionText(
  AppLocalizations l10n,
  Activity activity,
  String? currentUserId,
) {
  final performedBy = activity.performedBy;
  if (performedBy == null || performedBy.isEmpty) {
    return l10n.activityPerformedByUnknown;
  }
  if (performedBy == currentUserId) return l10n.activityPerformedByYou;
  return l10n.activityPerformedByMember(_shortId(performedBy));
}

/// The last 8 characters of a UUID — enough to visually distinguish
/// different performers within one org's activity list without printing the
/// full 36-character id on every row.
String _shortId(String id) => id.length <= 8 ? id : id.substring(id.length - 8);
