import 'package:beekeepingit_client/features/organization/registration_number.dart';
import 'package:flutter_test/flutter_test.dart';

/// FR-AP-9 (#296): the registration number is the BEEKEEPER's, held as an
/// organization-level default with an optional per-apiary override. These are
/// the pure resolution rules every screen reads through, so the "which number
/// does this apiary actually display" question is answered in exactly one
/// place.
void main() {
  group('effectiveRegistrationNumber', () {
    test('uses the apiary override when it is set', () {
      expect(
        effectiveRegistrationNumber(
          apiaryOverride: 'PT-654321',
          organizationDefault: 'PT-123456',
        ),
        'PT-654321',
      );
    });

    test(
      "falls back to the organization's default when there is no override",
      () {
        expect(
          effectiveRegistrationNumber(
            apiaryOverride: null,
            organizationDefault: 'PT-123456',
          ),
          'PT-123456',
        );
      },
    );

    test('is null when neither is set — nothing to display, and nothing is '
        'required (the field is advisory)', () {
      expect(
        effectiveRegistrationNumber(
          apiaryOverride: null,
          organizationDefault: null,
        ),
        isNull,
      );
    });

    test('treats a blank override as absent rather than as an empty number — '
        'the server stores the org default as "" for unset, and a form entry '
        'trimmed to nothing means "no number"', () {
      expect(
        effectiveRegistrationNumber(
          apiaryOverride: '   ',
          organizationDefault: 'PT-123456',
        ),
        'PT-123456',
      );
      expect(
        effectiveRegistrationNumber(
          apiaryOverride: null,
          organizationDefault: '',
        ),
        isNull,
      );
    });

    test('trims surrounding whitespace off the resolved value', () {
      expect(
        effectiveRegistrationNumber(
          apiaryOverride: '  PT-654321 ',
          organizationDefault: null,
        ),
        'PT-654321',
      );
    });
  });

  group('isRegistrationNumberInherited', () {
    test('is true when the number comes from the organization', () {
      expect(
        isRegistrationNumberInherited(
          apiaryOverride: null,
          organizationDefault: 'PT-123456',
        ),
        isTrue,
      );
    });

    test('is false when the apiary carries its own number', () {
      expect(
        isRegistrationNumberInherited(
          apiaryOverride: 'PT-654321',
          organizationDefault: 'PT-123456',
        ),
        isFalse,
      );
    });

    test('is false when there is no number at all — nothing is displayed, so '
        'there is nothing to mark as inherited', () {
      expect(
        isRegistrationNumberInherited(
          apiaryOverride: null,
          organizationDefault: null,
        ),
        isFalse,
      );
    });
  });
}
