import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/activities/activity_display.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';

final _l10n = AppLocalizationsEn();

Activity _activity({
  String type = 'generic',
  Map<String, dynamic> attributes = const {},
  String? performedBy,
}) => Activity(
  id: 'a1',
  apiaryId: 'ap1',
  type: type,
  occurredAt: '2026-06-01',
  attributes: attributes,
  performedBy: performedBy,
);

void main() {
  group('activitySummaryLine (#42/#43)', () {
    test('harvest: includes every present attribute, labeled', () {
      final line = activitySummaryLine(
        _l10n,
        _activity(
          type: 'harvest',
          attributes: {'honey_supers': 4, 'honey_kg': 12.5},
        ),
      );
      expect(line, contains('Honey supers harvested: 4'));
      expect(line, contains('Honey harvested (kg): 12.5'));
    });

    test('harvest: an absent optional attribute is simply not included', () {
      final line = activitySummaryLine(
        _l10n,
        _activity(type: 'harvest', attributes: {'honey_supers': 4}),
      );
      expect(line, isNot(contains('Honey harvested (kg)')));
    });

    test('harvest: includes the optional lot_batch identifier when present (#292)', () {
      final line = activitySummaryLine(
        _l10n,
        _activity(
          type: 'harvest',
          attributes: {'honey_supers': 4, 'lot_batch': '2026-07-A1'},
        ),
      );
      expect(line, contains('Lot / batch identifier: 2026-07-A1'));
    });

    test('harvest: an absent lot_batch is simply not included', () {
      final line = activitySummaryLine(
        _l10n,
        _activity(type: 'harvest', attributes: {'honey_supers': 4}),
      );
      expect(line, isNot(contains('Lot / batch identifier')));
    });

    test('feeding: includes feed type and amount', () {
      final line = activitySummaryLine(
        _l10n,
        _activity(
          type: 'feeding',
          attributes: {'feed_type': 'Xarope 1:1', 'feed_amount': 2.0},
        ),
      );
      expect(line, contains('Xarope 1:1'));
      expect(line, contains('Feed amount: 2.0'));
    });

    test('treatment: includes treatment type and localized context label', () {
      final line = activitySummaryLine(
        _l10n,
        _activity(
          type: 'treatment',
          attributes: {
            'treatment_type': 'Apivar/amitraz',
            'treatment_context': 'general_preventive',
          },
        ),
      );
      expect(line, contains('Apivar/amitraz'));
      expect(line, contains('General / preventive'));
    });

    test(
      'treatment: a detection-only report with no treatment_type still summarizes '
      'cleanly (#291 AC: detection can be logged with no treatment applied yet)',
      () {
        final line = activitySummaryLine(
          _l10n,
          _activity(
            type: 'treatment',
            attributes: {
              'treatment_context': 'detection_only',
              'disease': 'Varroose',
            },
          ),
        );
        expect(line, contains('Detection only (no treatment yet)'));
        expect(line, contains('Disease / condition: Varroose'));
        expect(line, isNot(contains('null')));
      },
    );

    test('generic with no attributes falls back to the "no details" text', () {
      final line = activitySummaryLine(_l10n, _activity(type: 'generic'));
      expect(line, _l10n.activityNoAttributesSummary);
    });

    test('notes is never included in the summary line, even when present', () {
      final line = activitySummaryLine(
        _l10n,
        _activity(
          type: 'generic',
          attributes: {
            'notes': 'a very long field note that should not show here',
          },
        ),
      );
      expect(line, isNot(contains('a very long field note')));
    });
  });

  group('activityDetailRows (#310, FR-AC-3/5/6)', () {
    ({String label, String value})? rowFor(
      List<({String label, String value})> rows,
      String label,
    ) {
      for (final r in rows) {
        if (r.label == label) return r;
      }
      return null;
    }

    test('harvest: one labeled row per present attribute, in form order', () {
      final rows = activityDetailRows(
        _l10n,
        _activity(
          type: 'harvest',
          attributes: {
            'honey_supers': 4,
            'honey_kg': 12.5,
            'lot_batch': '2026-07-A1',
          },
        ),
      );
      expect(
        rowFor(rows, 'Honey supers harvested')?.value,
        '4',
      );
      expect(rowFor(rows, 'Honey harvested (kg)')?.value, '12.5');
      expect(rowFor(rows, 'Lot / batch identifier')?.value, '2026-07-A1');
      // Absent optional (hives_involved) yields no row at all.
      expect(rowFor(rows, 'Hives involved'), isNull);
    });

    test('notes IS included on the detail (unlike the compact summary line)', () {
      final rows = activityDetailRows(
        _l10n,
        _activity(
          type: 'generic',
          attributes: {'notes': 'Full field note visible on detail.'},
        ),
      );
      expect(rows, hasLength(1));
      expect(rows.single.value, 'Full field note visible on detail.');
    });

    test('a blank (whitespace-only) attribute is omitted, not an empty row', () {
      final rows = activityDetailRows(
        _l10n,
        _activity(type: 'generic', attributes: {'notes': '   '}),
      );
      expect(rows, isEmpty);
    });

    test('generic with no attributes yields no rows', () {
      final rows = activityDetailRows(_l10n, _activity(type: 'generic'));
      expect(rows, isEmpty);
    });

    test(
      'treatment: context renders its localized label, not the raw token; a '
      'detection-only report omits the absent treatment_type (no "null" row)',
      () {
        final rows = activityDetailRows(
          _l10n,
          _activity(
            type: 'treatment',
            attributes: {
              'treatment_context': 'detection_only',
              'disease': 'Varroose',
            },
          ),
        );
        expect(
          rowFor(rows, 'Treatment context')?.value,
          'Detection only (no treatment yet)',
        );
        expect(rowFor(rows, 'Disease / condition')?.value, 'Varroose');
        expect(rowFor(rows, 'Treatment product'), isNull);
        expect(rows.any((r) => r.value.contains('null')), isFalse);
      },
    );
  });

  group('activityAttributionText (#44, FR-TEN-2)', () {
    test('shows "You" when performedBy matches the current user', () {
      final text = activityAttributionText(
        _l10n,
        _activity(performedBy: 'user-1'),
        'user-1',
      );
      expect(text, 'You');
    });

    test('shows a short, distinguishable id for another performer', () {
      final text = activityAttributionText(
        _l10n,
        _activity(performedBy: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'),
        'user-1',
      );
      expect(text, isNot('You'));
      expect(text, contains('eeeeeeee'));
    });

    test('two different other performers render distinguishably', () {
      final a = activityAttributionText(
        _l10n,
        _activity(performedBy: 'user-aaaaaaaa'),
        'me',
      );
      final b = activityAttributionText(
        _l10n,
        _activity(performedBy: 'user-bbbbbbbb'),
        'me',
      );
      expect(a, isNot(b));
    });

    test('a null performedBy (not yet synced back) shows "Unknown"', () {
      final text = activityAttributionText(_l10n, _activity(), 'user-1');
      expect(text, 'Unknown');
    });
  });
}
