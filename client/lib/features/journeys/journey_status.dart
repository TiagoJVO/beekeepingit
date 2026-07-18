import '../../l10n/gen/app_localizations.dart';

/// A journey's lifecycle status (#45, FR-JO-4, D-21): **open** journeys are
/// selectable and auto-matched by default in the activity-form picker (#46);
/// **closed** journeys are hidden by default there (still selectable, with a
/// confirm-to-proceed warning). Mirrors the server's own extensible-string
/// convention (services/journeys/api/types.go's StatusOpen/StatusClosed) —
/// not a plain bool, so a future status is a code-only append here and in
/// the Go registry, same convention as activity_types.dart's own vocabulary
/// mirroring.
const journeyStatusOpen = 'open';
const journeyStatusClosed = 'closed';

const knownJourneyStatuses = [journeyStatusOpen, journeyStatusClosed];

/// The localized display label for a journey status, or null for a status
/// this client version doesn't know (degrade gracefully, same convention as
/// activity_types.dart's activityTypeLabel).
String? journeyStatusLabel(AppLocalizations l10n, String status) {
  return switch (status) {
    journeyStatusOpen => l10n.journeyStatusOpenLabel,
    journeyStatusClosed => l10n.journeyStatusClosedLabel,
    _ => null,
  };
}
