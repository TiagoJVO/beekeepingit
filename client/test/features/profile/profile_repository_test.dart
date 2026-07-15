import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// Built via a runtime function so two "equal" instances are genuinely
// distinct objects, not compiler-canonicalized.
Profile _profile({String name = 'Test User'}) => Profile(
  id: 'user-1',
  name: name,
  email: 'test@example.com',
  locale: 'en',
  profileComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 2),
);

void main() {
  group('Profile value equality (MEDIUM-2)', () {
    test('two distinct instances with the same fields are ==', () {
      final a = _profile();
      final b = _profile();

      expect(identical(a, b), isFalse, reason: 'test setup sanity check');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('instances differing in a field are not ==', () {
      expect(_profile(), isNot(equals(_profile(name: 'Other User'))));
    });
  });
}
