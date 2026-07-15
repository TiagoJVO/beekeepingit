import 'package:beekeepingit_client/core/validation/email.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers the shared "looks like an email" check extracted from
/// `profile_screen.dart` (previously duplicated, untested, inline in that
/// screen and in `account_screen.dart`).
void main() {
  group('looksLikeEmail', () {
    test('accepts a plausible email address', () {
      expect(looksLikeEmail('ana@example.com'), isTrue);
      expect(looksLikeEmail('a.b+c@sub.example.co'), isTrue);
    });

    test('rejects missing @ or domain', () {
      expect(looksLikeEmail('ana'), isFalse);
      expect(looksLikeEmail('ana@'), isFalse);
      expect(looksLikeEmail('ana@example'), isFalse);
      expect(looksLikeEmail('@example.com'), isFalse);
    });

    test('rejects embedded whitespace', () {
      expect(looksLikeEmail('an a@example.com'), isFalse);
      expect(looksLikeEmail('ana@exa mple.com'), isFalse);
    });
  });
}
