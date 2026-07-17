import 'package:beekeepingit_client/features/activities/activity_attributes.dart';
import 'package:beekeepingit_client/features/activities/activity_types.dart';
import 'package:flutter_test/flutter_test.dart';

// Table-driven tests for the #38 client-side validation mirror
// (activity_attributes.dart) — the Dart counterpart of
// services/activities/api/types_test.go. Pure logic, no widget pump needed.

bool hasFieldCode(List<ActivityAttributeError> errors, String field, String code) {
  return errors.any((e) => e.field == field && e.code == code);
}

void main() {
  group('validateActivityAttributes: unknown type', () {
    test('rejects an unregistered type', () {
      final errors = validateActivityAttributes('nucs', {});
      expect(hasFieldCode(errors, 'type', 'invalid'), isTrue);
    });
  });

  group('validateActivityAttributes: harvest', () {
    test('valid with all fields', () {
      final errors = validateActivityAttributes(activityTypeHarvest, {
        'honey_supers': 4,
        'honey_kg': 12.5,
        'hives_involved': 6,
        'notes': 'boa colheita',
      });
      expect(errors, isEmpty);
    });

    test('valid with only the required field', () {
      final errors = validateActivityAttributes(activityTypeHarvest, {'honey_supers': 0});
      expect(errors, isEmpty);
    });

    test('missing honey_supers is rejected (required, primary yield metric)', () {
      final errors = validateActivityAttributes(activityTypeHarvest, {'honey_kg': 10});
      expect(hasFieldCode(errors, 'attributes.honey_supers', 'required'), isTrue);
    });

    test('non-integer honey_supers is malformed', () {
      final errors = validateActivityAttributes(activityTypeHarvest, {'honey_supers': 2.5});
      expect(hasFieldCode(errors, 'attributes.honey_supers', 'invalid'), isTrue);
    });

    test('negative honey_supers is out of range', () {
      final errors = validateActivityAttributes(activityTypeHarvest, {'honey_supers': -1});
      expect(hasFieldCode(errors, 'attributes.honey_supers', 'out_of_range'), isTrue);
    });

    test('unknown attribute is rejected', () {
      final errors = validateActivityAttributes(activityTypeHarvest, {'honey_supers': 1, 'colour': 'amber'});
      expect(hasFieldCode(errors, 'attributes.colour', 'invalid'), isTrue);
    });

    test('valid with an optional lot_batch identifier (#292, D-19)', () {
      final errors = validateActivityAttributes(activityTypeHarvest, {
        'honey_supers': 4,
        'lot_batch': '2026-07-A1',
      });
      expect(errors, isEmpty);
    });

    test('lot_batch over the length limit is rejected (#292)', () {
      final errors = validateActivityAttributes(activityTypeHarvest, {
        'honey_supers': 1,
        'lot_batch': 'x' * 101,
      });
      expect(hasFieldCode(errors, 'attributes.lot_batch', 'too_long'), isTrue);
    });
  });

  group('validateActivityAttributes: feeding', () {
    test('valid with required fields only', () {
      final errors = validateActivityAttributes(activityTypeFeeding, {
        'feed_type': 'Xarope 1:1',
        'feed_amount': 2,
      });
      expect(errors, isEmpty);
    });

    test('feed_type outside the candidate vocabulary is rejected', () {
      final errors = validateActivityAttributes(activityTypeFeeding, {
        'feed_type': 'Sugar Water',
        'feed_amount': 1,
      });
      expect(hasFieldCode(errors, 'attributes.feed_type', 'invalid'), isTrue);
    });

    test('missing feed_amount is rejected', () {
      final errors = validateActivityAttributes(activityTypeFeeding, {'feed_type': 'Pólen'});
      expect(hasFieldCode(errors, 'attributes.feed_amount', 'required'), isTrue);
    });
  });

  group('validateActivityAttributes: treatment', () {
    test('valid: general/preventive needs no disease', () {
      final errors = validateActivityAttributes(activityTypeTreatment, {
        'treatment_context': treatmentContextGeneral,
        'treatment_type': 'Timol',
      });
      expect(errors, isEmpty);
    });

    test('valid: disease_specific with disease provided', () {
      final errors = validateActivityAttributes(activityTypeTreatment, {
        'treatment_context': treatmentContextDiseaseSpecific,
        'treatment_type': 'Apivar/amitraz',
        'disease': 'Varroose',
      });
      expect(errors, isEmpty);
    });

    test('disease_specific without disease is rejected (conditional requirement)', () {
      final errors = validateActivityAttributes(activityTypeTreatment, {
        'treatment_context': treatmentContextDiseaseSpecific,
        'treatment_type': 'Timol',
      });
      expect(hasFieldCode(errors, 'attributes.disease', 'required'), isTrue);
    });

    test('detection_only without disease is rejected (conditional requirement)', () {
      final errors = validateActivityAttributes(activityTypeTreatment, {
        'treatment_context': treatmentContextDetectionOnly,
        'treatment_type': 'Timol',
      });
      expect(hasFieldCode(errors, 'attributes.disease', 'required'), isTrue);
    });

    test('treatment_context outside the candidate vocabulary is rejected', () {
      final errors = validateActivityAttributes(activityTypeTreatment, {
        'treatment_context': 'unknown_context',
        'treatment_type': 'Timol',
      });
      expect(hasFieldCode(errors, 'attributes.treatment_context', 'invalid'), isTrue);
    });

    test(
      'valid: detection_only with disease and NO treatment_type at all '
      '(#291 AC: a detection can be logged with no treatment applied yet)',
      () {
        final errors = validateActivityAttributes(activityTypeTreatment, {
          'treatment_context': treatmentContextDetectionOnly,
          'disease': 'Varroose',
        });
        expect(errors, isEmpty);
      },
    );

    test(
      'missing treatment_type when disease_specific is still rejected '
      '(only detection_only makes treatment_type optional)',
      () {
        final errors = validateActivityAttributes(activityTypeTreatment, {
          'treatment_context': treatmentContextDiseaseSpecific,
          'disease': 'Varroose',
        });
        expect(hasFieldCode(errors, 'attributes.treatment_type', 'required'), isTrue);
      },
    );

    test('disease outside the DGAV-DDO-informed candidate vocabulary is rejected (#291)', () {
      final errors = validateActivityAttributes(activityTypeTreatment, {
        'treatment_context': treatmentContextDiseaseSpecific,
        'treatment_type': 'Timol',
        'disease': 'Made-up disease',
      });
      expect(hasFieldCode(errors, 'attributes.disease', 'invalid'), isTrue);
    });
  });

  group('validateActivityAttributes: generic', () {
    test('valid with no attributes', () {
      expect(validateActivityAttributes(activityTypeGeneric, {}), isEmpty);
    });

    test('valid with notes', () {
      expect(
        validateActivityAttributes(activityTypeGeneric, {'notes': 'checked the entrance'}),
        isEmpty,
      );
    });

    test('rejects an attribute not part of the generic schema', () {
      final errors = validateActivityAttributes(activityTypeGeneric, {'honey_supers': 1});
      expect(hasFieldCode(errors, 'attributes.honey_supers', 'invalid'), isTrue);
    });
  });
}
