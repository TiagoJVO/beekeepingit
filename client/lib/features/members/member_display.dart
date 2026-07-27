/// Display helpers for rendering a member *identity* — shared by every
/// feature that attributes a record to a user.
///
/// Only the genuinely-identical piece lives here. The surrounding
/// resolution functions (activity_display.dart's `activityAttributionText`,
/// todo_display.dart's assignee label, history_display.dart's
/// `historyActorText`) stay per-feature because each picks its own ARB keys
/// for the "You" / "Member {id}" / "Unknown" fallbacks — but they all agree
/// on what a short id looks like, and that agreement is what this file
/// makes explicit rather than re-deriving in each caller.
library;

/// The last 8 characters of a UUID — enough to visually distinguish
/// different users within one org without printing the full 36-character id
/// on every row.
///
/// The fallback when no display name is available: a member with an
/// incomplete profile, one since removed from the org, or simply the
/// offline / pre-first-fetch case where the online-only roster
/// (`memberNamesProvider`) hasn't loaded. Stable and non-spoofable — it is
/// derived from the internal id, never from user-supplied text.
String shortMemberId(String id) =>
    id.length <= 8 ? id : id.substring(id.length - 8);
