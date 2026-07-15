import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:flutter_test/flutter_test.dart';

// Built via a runtime function (not a `const` literal, and Organization has
// no const constructor anyway since DateTime isn't a const-constructible
// type) so two "equal" instances are genuinely distinct objects.
Organization _org({String name = 'Serra Apiaries'}) => Organization(
  id: 'org-1',
  name: name,
  address: '123 Serra Rd',
  createdBy: 'user-1',
  role: 'admin',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 2),
);

void main() {
  group('Organization value equality (MEDIUM-2)', () {
    test('two distinct instances with the same fields are ==', () {
      final a = _org();
      final b = _org();

      expect(identical(a, b), isFalse, reason: 'test setup sanity check');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('instances differing in a field are not ==', () {
      expect(_org(), isNot(equals(_org(name: 'Other Apiaries'))));
    });
  });
}
