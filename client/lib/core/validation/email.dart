/// Shared, dependency-free "looks like an email" check used by client-side
/// form validators. Intentionally permissive (no full RFC 5322 grammar) —
/// its job is to catch obviously-malformed input before a round trip to the
/// server, not to be the source of truth for email validity (the server
/// still validates on submit).
///
/// Extracted from `features/profile/profile_screen.dart`'s previously
/// private `_looksLikeEmail`, which was byte-for-byte duplicated in
/// `features/account/account_screen.dart`. Only `profile_screen.dart` imports
/// this today; `account_screen.dart` keeps its own copy for now to avoid
/// touching a file with changes in flight on a separate PR — consolidating
/// it onto this shared helper is a follow-up once that PR lands.
bool looksLikeEmail(String value) {
  return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value);
}
