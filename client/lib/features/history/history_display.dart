import '../../l10n/gen/app_localizations.dart';
import '../members/member_display.dart';
import 'history_repository.dart';

/// Pure, l10n-facing display helpers for the history timeline (#60,
/// FR-HIS-1). Each takes [AppLocalizations] rather than a `BuildContext`,
/// the same convention activity_display.dart/todo_display.dart follow — so
/// every rule below is unit-testable without pumping a widget.

/// The timeline label for one entry's kind.
///
/// [HistoryEventKind.unknown] renders a generic "Changed" rather than
/// hiding the row: an entry whose kind this client version doesn't
/// recognize still tells the user that something changed and when, which is
/// the point of an audit trail (D-20's extensible-vocabulary convention).
String historyEventLabel(AppLocalizations l10n, HistoryEventKind kind) =>
    switch (kind) {
      HistoryEventKind.created => l10n.historyEventCreated,
      HistoryEventKind.updated => l10n.historyEventUpdated,
      HistoryEventKind.deleted => l10n.historyEventDeleted,
      HistoryEventKind.superseded => l10n.historyEventSuperseded,
      HistoryEventKind.unknown => l10n.historyEventUnknown,
    };

/// The actor display text for one history entry, resolved with the same
/// four-step precedence activity attribution already uses
/// (activity_display.dart's `activityAttributionText`), against the same
/// roster source (`memberNamesProvider`):
///
/// 1. "Unknown" when the row carries no actor at all — history.md §3 allows
///    a null `actor_user_id` on rows applied without a resolvable caller.
/// 2. "You" when the actor is the signed-in user.
/// 3. The member's real display name from the org roster.
/// 4. A short, non-spoofable id fragment ([shortMemberId]) otherwise — an
///    incomplete profile, a since-removed member, or simply the offline /
///    pre-first-fetch case where the online-only roster hasn't loaded.
///
/// Deliberately takes a bare `String?` id rather than an entity, so the one
/// implementation serves every entity type's timeline (apiary, activity,
/// and whatever #315/EPIC-05 attach next) — unlike
/// `activityAttributionText`, which is hard-typed to an `Activity`.
String historyActorText(
  AppLocalizations l10n,
  String? actorUserId,
  String? currentUserId, {
  Map<String, String> memberNames = const {},
}) {
  if (actorUserId == null || actorUserId.isEmpty) {
    return l10n.historyActorUnknown;
  }
  if (actorUserId == currentUserId) return l10n.historyActorYou;
  final name = memberNames[actorUserId];
  if (name != null && name.isNotEmpty) return name;
  return l10n.historyActorMember(shortMemberId(actorUserId));
}

/// The localized, user-facing name of one audited column.
///
/// Columns whose concept already has a form label reuse that ARB key rather
/// than duplicating the translation; only the gaps carry a `historyField*`
/// key of their own. An unmapped column falls through to its raw server
/// name — a new audited column then reads slightly technical instead of
/// disappearing from the changed-fields line, which is the safer failure
/// for an audit trail.
///
/// The vocabulary is the union of what the owning services actually write
/// into `changed_fields` (their `fields()` maps): apiaries writes
/// name/hive_count/location/notes/place_label; activities writes
/// apiary_id/type/occurred_at/attributes.
String historyFieldLabel(AppLocalizations l10n, String column) =>
    switch (column) {
      'name' => l10n.apiaryNameLabel,
      'notes' => l10n.apiaryNotesLabel,
      'place_label' => l10n.apiaryPlaceLabelLabel,
      'hive_count' => l10n.hiveCountLabel,
      'location' => l10n.historyFieldLocation,
      'occurred_at' => l10n.activityOccurredAtLabel,
      'type' => l10n.historyFieldActivityType,
      'attributes' => l10n.historyFieldAttributes,
      'apiary_id' => l10n.historyFieldApiary,
      _ => column,
    };

/// The "Changed: name, notes" sub-line for an update entry, or null when
/// there is nothing to show — an entry whose kind carries no changed-field
/// list (create/delete/superseded all write NULL server-side), or an update
/// row whose list is empty.
///
/// Returning null rather than an empty string lets the caller omit the
/// widget entirely instead of rendering a stray label.
String? historyChangedFieldsText(AppLocalizations l10n, HistoryEntry entry) {
  if (entry.changedFields.isEmpty) return null;
  final labels = entry.changedFields
      .map((column) => historyFieldLabel(l10n, column))
      .toList();
  return l10n.historyChangedFieldsValue(labels.join(', '));
}

/// The secondary explanatory line under an entry, or null when the entry
/// needs none. Today only a [HistoryEventKind.superseded] row has one —
/// it explains that the losing edit was preserved rather than dropped
/// (history.md §6), which is not self-evident from the "Superseded" label
/// alone.
String? historyDetailText(AppLocalizations l10n, HistoryEntry entry) =>
    entry.kind == HistoryEventKind.superseded
    ? l10n.historySupersededDetail
    : null;
