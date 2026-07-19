import '../../l10n/gen/app_localizations.dart';
import '../apiaries/apiaries_repository.dart';

/// The assignee display text for one todo (#293, FR-TD-1) — mirrors
/// activity_display.dart's `activityAttributionText` precedence, minus its
/// "You" special-case (a todo's assignee isn't necessarily, and isn't
/// specially called out as, the current user):
///
/// 1. [l10n]'s "Unassigned" when [assigneeId] is null/empty — a todo left
///    unassigned (FR-TD-1's own default).
/// 2. The member's real display name, when [memberNames] carries a
///    non-empty entry for [assigneeId] (`memberNamesProvider`,
///    members_repository.dart — the caller's org roster, `user_id ->
///    name`).
/// 3. A short, stable, non-spoofable id fragment (`Member <last-8>`) as the
///    fallback when no name is available: an assignee whose profile is
///    incomplete, one who has since been removed, or the offline /
///    pre-first-fetch case where the roster hasn't loaded yet.
///
/// [memberNames] defaults to empty, matching [activityAttributionText]'s own
/// "no roster wired yet" default.
String todoAssigneeLabel(
  AppLocalizations l10n,
  String? assigneeId,
  Map<String, String> memberNames,
) {
  if (assigneeId == null || assigneeId.isEmpty) {
    return l10n.todoAssigneeUnassigned;
  }
  final name = memberNames[assigneeId];
  if (name != null && name.isNotEmpty) return name;
  return l10n.todoAssigneeUnknown(_shortId(assigneeId));
}

/// The apiary display text for one todo (#293, FR-TD-1), resolved:
///
/// 1. [l10n]'s "No apiary" when [apiaryId] is null/empty — a general,
///    org-level todo (#51's own default, not tied to any one apiary).
/// 2. The apiary's name, when found in [apiaries] (`apiariesStreamProvider`,
///    apiaries_repository.dart — the caller's locally-synced apiary set).
/// 3. [l10n]'s "Unknown apiary" fallback when [apiaryId] is set but isn't
///    (or is no longer) in [apiaries] — a stale reference (its apiary was
///    since deleted server-side, todos_repository.dart's own doc comment on
///    this exact case) rather than a crash or a blank value.
String todoApiaryLabel(
  AppLocalizations l10n,
  String? apiaryId,
  List<Apiary> apiaries,
) {
  if (apiaryId == null || apiaryId.isEmpty) return l10n.todoApiaryNone;
  for (final apiary in apiaries) {
    if (apiary.id == apiaryId) return apiary.name;
  }
  return l10n.todoApiaryUnknown;
}

/// The last 8 characters of a UUID — mirrors activity_display.dart's own
/// `_shortId`, enough to visually distinguish different assignees within one
/// org without printing the full 36-character id.
String _shortId(String id) => id.length <= 8 ? id : id.substring(id.length - 8);
