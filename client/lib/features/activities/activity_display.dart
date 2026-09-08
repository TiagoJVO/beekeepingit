import '../../core/l10n/locale_formatting.dart';
import '../../l10n/gen/app_localizations.dart';
import '../members/member_display.dart';
import 'activities_repository.dart';
import 'activity_types.dart';

/// Renders one attribute value for display (#624, NFR-I18N-1, C-2).
///
/// A number goes through `intl` for [l10n]'s own locale — the decimal
/// separator and thousands grouping the reader expects (`62,5` /
/// `999.999.999` in pt) — instead of Dart's `toString()`, which is English
/// in every language and never groups. Everything else (`lot_batch`,
/// `feed_type`, `notes`, ...) is already a human-readable stored string and
/// is shown untouched.
///
/// Keyed off `l10n.localeName` rather than a `BuildContext` so both callers
/// keep their current pure-function signatures: they are used from list
/// rows, the detail screen and plain unit tests alike, and the locale they
/// should format for is exactly the one their `AppLocalizations` was
/// resolved for.
String _attributeText(AppLocalizations l10n, dynamic value) => value is num
    ? LocaleFormatting.forLocale(l10n.localeName).number(value)
    : '$value';

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

/// The COMPACT, phone-sized headline for one activity (#632, FR-AC-5/6,
/// FR-UX-1) — the date's companion in a narrow row's subtitle, where
/// [activitySummaryLine]'s every-attribute join is what made a single honey
/// harvest render as nine wrapped lines at 375px.
///
/// Returns at most TWO parts, deliberately: the row answers "what happened
/// here, and how much of it" at a glance, and everything it drops is one tap
/// away on the activity detail screen ([activityDetailRows]).
///
/// The headline per type, and why:
///
/// * **harvest** — the **honey supers** count. FR-AC-1 names it "the primary
///   yield metric (more reliably measured in the field than the kg amount)",
///   so it is the harvest's headline by requirement, not by taste. It is also
///   a required attribute, so a conforming harvest always has one; a harvest
///   that somehow carries only kilograms falls back to those rather than
///   showing a bare date.
/// * **feeding** — the **feed type** and the **feed amount**: this type's two
///   required attributes, and jointly the whole substance of a feeding ("what
///   went in, and how much").
/// * **treatment** — the **product applied** and the **disease/condition**,
///   whichever of the two are present. A detection-only report (#291) has no
///   product, and there the condition detected IS the headline; a
///   general/preventive treatment has no condition, and there the product is.
///   When neither is recorded, the **treatment context** label carries the
///   row instead, so the reason for the visit still shows.
/// * **generic** — nothing. FR-AC-1 gives the generic type no attributes
///   beyond free-text notes, and notes are excluded from a row (see this
///   file's own doc). The caller then shows the date alone, which is honest —
///   rather than [activitySummaryLine]'s "No additional details" filler, which
///   would cost a phone row's whole second line to say nothing.
///
/// Where a label is needed at all, it is a deliberately SHORT one (`Supers: 4`,
/// not `Honey supers harvested: 4`). That is a second, compact vocabulary
/// alongside the form's own field labels, which this file otherwise avoids —
/// but at 375px the long label alone consumes the line, and the same trade-off
/// is already made by the journey stats screen's `journeyStatsDetail*` labels.
/// Controlled-vocabulary values (`feed_type`, `treatment_type`, `disease`) are
/// self-describing and carry no label.
String activityHeadlineLine(AppLocalizations l10n, Activity activity) =>
    _headlineParts(l10n, activity.type, activity.attributes).join(' · ');

List<String> _headlineParts(
  AppLocalizations l10n,
  String type,
  Map<String, dynamic> attrs,
) {
  switch (type) {
    case activityTypeHarvest:
      if (attrs['honey_supers'] != null) {
        return [
          '${l10n.activityHeadlineSupersLabel}: '
              '${_attributeText(l10n, attrs['honey_supers'])}',
        ];
      }
      if (attrs['honey_kg'] != null) {
        return [
          l10n.activityHeadlineHoneyKgValue(
            _attributeText(l10n, attrs['honey_kg']),
          ),
        ];
      }
      return const [];
    case activityTypeFeeding:
      return [
        if (attrs['feed_type'] != null)
          feedTypeLabel(l10n, '${attrs['feed_type']}'),
        if (attrs['feed_amount'] != null)
          '${l10n.activityHeadlineFeedAmountLabel}: '
              '${_attributeText(l10n, attrs['feed_amount'])}',
      ];
    case activityTypeTreatment:
      final applied = [
        if (attrs['treatment_type'] != null)
          treatmentTypeLabel(l10n, '${attrs['treatment_type']}'),
        if (attrs['disease'] != null)
          diseaseConditionLabel(l10n, '${attrs['disease']}'),
      ];
      if (applied.isNotEmpty) return applied;
      final context = attrs['treatment_context'] as String?;
      if (context == null) return const [];
      return [treatmentContextLabel(l10n, context) ?? context];
    default: // activityTypeGeneric, and any unknown future type
      return const [];
  }
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
          '${l10n.activityHoneySupersLabel}: ${_attributeText(l10n, attrs['honey_supers'])}',
        if (attrs['honey_kg'] != null)
          '${l10n.activityHoneyKgLabel}: ${_attributeText(l10n, attrs['honey_kg'])}',
        if (attrs['hives_involved'] != null)
          '${l10n.activityHivesInvolvedLabel}: ${_attributeText(l10n, attrs['hives_involved'])}',
        if (attrs['lot_batch'] != null)
          '${l10n.activityLotBatchLabel}: ${attrs['lot_batch']}',
      ];
    case activityTypeFeeding:
      return [
        if (attrs['feed_type'] != null)
          '${l10n.activityFeedTypeLabel}: '
              '${feedTypeLabel(l10n, '${attrs['feed_type']}')}',
        if (attrs['feed_amount'] != null)
          '${l10n.activityFeedAmountLabel}: ${_attributeText(l10n, attrs['feed_amount'])}',
        if (attrs['hives_involved'] != null)
          '${l10n.activityHivesInvolvedLabel}: ${_attributeText(l10n, attrs['hives_involved'])}',
      ];
    case activityTypeTreatment:
      final context = attrs['treatment_context'] as String?;
      return [
        if (attrs['treatment_type'] != null)
          '${l10n.activityTreatmentTypeLabel}: '
              '${treatmentTypeLabel(l10n, '${attrs['treatment_type']}')}',
        if (context != null) treatmentContextLabel(l10n, context) ?? context,
        if (attrs['disease'] != null)
          '${l10n.activityDiseaseLabel}: '
              '${diseaseConditionLabel(l10n, '${attrs['disease']}')}',
        if (attrs['hives_involved'] != null)
          '${l10n.activityHivesInvolvedLabel}: ${_attributeText(l10n, attrs['hives_involved'])}',
      ];
    default: // activityTypeGeneric, and any unknown future type — nothing
      // beyond notes to summarize, and notes are excluded (see file doc).
      return const [];
  }
}

/// The full, per-type attribute breakdown for the activity DETAIL screen
/// (#310, FR-AC-3/5/6) — one `(label, value)` pair per populated attribute of
/// the activity's type, in the same order the add/edit form lays its fields
/// out, reusing the SAME `.arb` field labels the form and
/// [activitySummaryLine] already use (no third, parallel vocabulary).
///
/// Unlike the compact [activitySummaryLine], this DOES include free-text
/// `notes` (the detail screen is exactly the "future detail view" that
/// function's doc defers notes to) and renders each attribute on its own row
/// rather than a single joined line. An absent/blank attribute is omitted
/// entirely (no empty rows); `treatment_context` renders its localized label,
/// not the raw stored token, mirroring the summary line's own treatment
/// handling. Vocabulary values (`feed_type`, `treatment_type`, `disease`) are
/// stored as stable Portuguese-looking wire values and localized at render
/// time through activity_types.dart's `*Label` helpers (#625, NFR-I18N-1) —
/// the stored value itself is never rewritten.
List<({String label, String value})> activityDetailRows(
  AppLocalizations l10n,
  Activity activity,
) {
  final attrs = activity.attributes;
  final rows = <({String label, String value})>[];

  /// [display] localizes a controlled-vocabulary value for rendering; without
  /// it the stored value is shown verbatim (numbers, free text).
  void add(String label, String key, [String Function(String)? display]) {
    final value = attrs[key];
    if (value == null) return;
    final text = value is String ? value : _attributeText(l10n, value);
    if (text.trim().isEmpty) return;
    rows.add((label: label, value: display == null ? text : display(text)));
  }

  switch (activity.type) {
    case activityTypeHarvest:
      add(l10n.activityHoneySupersLabel, 'honey_supers');
      add(l10n.activityHoneyKgLabel, 'honey_kg');
      add(l10n.activityHivesInvolvedLabel, 'hives_involved');
      add(l10n.activityLotBatchLabel, 'lot_batch');
    case activityTypeFeeding:
      add(
        l10n.activityFeedTypeLabel,
        'feed_type',
        (v) => feedTypeLabel(l10n, v),
      );
      add(l10n.activityFeedAmountLabel, 'feed_amount');
      add(l10n.activityHivesInvolvedLabel, 'hives_involved');
    case activityTypeTreatment:
      final context = attrs['treatment_context'] as String?;
      if (context != null && context.isNotEmpty) {
        rows.add((
          label: l10n.activityTreatmentContextFieldLabel,
          value: treatmentContextLabel(l10n, context) ?? context,
        ));
      }
      add(
        l10n.activityTreatmentTypeLabel,
        'treatment_type',
        (v) => treatmentTypeLabel(l10n, v),
      );
      add(
        l10n.activityDiseaseLabel,
        'disease',
        (v) => diseaseConditionLabel(l10n, v),
      );
      add(l10n.activityHivesInvolvedLabel, 'hives_involved');
    default: // activityTypeGeneric, and any unknown future type
      break;
  }
  // Every type carries free-text notes (FR-AC-1); shown last, as the form
  // orders it.
  add(l10n.activityNotesLabel, 'notes');
  return rows;
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
  // Sanitized, not taken verbatim (#582, NFR-SEC-1): the name is authored
  // outside this app and a bidi override or a newline in it would misattribute
  // this row. See member_display.dart's `sanitizedMemberName`.
  final name = sanitizedMemberName(memberNames[performedBy]);
  if (name != null) return name;
  return l10n.activityPerformedByMember(shortMemberId(performedBy));
}
