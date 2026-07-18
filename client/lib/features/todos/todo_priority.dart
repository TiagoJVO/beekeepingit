import '../../l10n/gen/app_localizations.dart';

/// The known todo priority levels (#50/#53, FR-TD-1, D-20) — the client
/// mirror of the owning service's registry (services/todos/api/types.go's
/// `Priorities`). Extensible in code, never a DB enum/CHECK (D-20): adding a
/// future level is a code-only append here and in the Go registry, same
/// convention as activity_types.dart's own vocabulary mirroring.
const todoPriorityLow = 'low';
const todoPriorityMedium = 'medium';
const todoPriorityHigh = 'high';

/// Ordered low -> high, matching the server's own declaration order — a
/// picker/filter would list them in this order (mirrors activity_types.
/// dart's `knownActivityTypes`).
const knownTodoPriorities = [
  todoPriorityLow,
  todoPriorityMedium,
  todoPriorityHigh,
];

/// The localized display label for a priority, or null for a value this
/// client version doesn't know (an unknown/newer priority replicated down
/// from a newer server — degrade gracefully rather than rendering raw
/// internals, same convention as activity_types.dart's activityTypeLabel).
String? todoPriorityLabel(AppLocalizations l10n, String priority) {
  return switch (priority) {
    todoPriorityLow => l10n.todoPriorityLowLabel,
    todoPriorityMedium => l10n.todoPriorityMediumLabel,
    todoPriorityHigh => l10n.todoPriorityHighLabel,
    _ => null,
  };
}

/// A numeric sort weight for [priority] (#53 AC: "sortable by ... priority
/// level") — higher ranks as more urgent, so `todo_filters.dart`'s priority
/// sort can compare two todos without a per-comparison switch of its own.
/// An unknown priority (a newer value replicated down from a newer server)
/// ranks below every known level rather than throwing, so a sort never
/// crashes on unrecognized data.
int todoPriorityRank(String priority) {
  return switch (priority) {
    todoPriorityHigh => 2,
    todoPriorityMedium => 1,
    todoPriorityLow => 0,
    _ => -1,
  };
}
