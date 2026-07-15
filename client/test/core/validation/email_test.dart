import 'package:beekeepingit_client/core/validation/email.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression coverage for the shared client-side email format check (HIGH
/// finding: members_screen.dart's invite field had no format validation at
/// all, diverging from account_screen.dart's own copy of this same regex —
/// extracted here so both screens, and any future one, share one definition
/// that mirrors the server's `emailPattern`
/// (services/organizations/api/invitations.go,
/// services/identity/api/profile.go)).
void main() {
  group('looksLikeEmail', () {
    test('accepts a well-formed address', () {
      expect(looksLikeEmail('user@example.com'), isTrue);
    });

    test('rejects a value with no @', () {
      expect(looksLikeEmail('nope'), isFalse);
    });

    test('rejects a value with no domain dot', () {
      expect(looksLikeEmail('user@example'), isFalse);
    });

    test('rejects a value containing whitespace', () {
      expect(looksLikeEmail('user @example.com'), isFalse);
    });

    test('rejects an empty string', () {
      expect(looksLikeEmail(''), isFalse);
    });
  });
}
