/// Shared client-side "looks like an email" format check — a pragmatic
/// sniff test, not full RFC 5322 validation. Mirrors the server's own
/// `emailPattern` (services/organizations/api/invitations.go,
/// services/identity/api/profile.go), so the client rejects an obviously
/// malformed address before round-tripping to the server.
///
/// Extracted here (rather than living as a private method on one screen) so
/// every email field shares exactly one definition: account_screen.dart's
/// profile-email field and members_screen.dart's invite-email field both use
/// this, instead of members_screen.dart having no format check at all while
/// account_screen.dart carried its own private copy of the same regex.
final RegExp _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// Whether [value] looks like a valid email address.
bool looksLikeEmail(String value) => _emailPattern.hasMatch(value);
