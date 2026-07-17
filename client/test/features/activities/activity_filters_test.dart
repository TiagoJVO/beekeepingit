import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/activities/activity_filters.dart';
import 'package:flutter_test/flutter_test.dart';

Activity _activity(
  String id, {
  String type = 'generic',
  required String date,
}) => Activity(
  id: id,
  apiaryId: 'a1',
  type: type,
  occurredAt: date,
  attributes: const {},
);

void main() {
  group('filterActivitiesByType (#42/#43, FR-AC-5/FR-AC-6)', () {
    test('a null type is a passthrough (the "all types" default)', () {
      final activities = [
        _activity('1', type: 'harvest', date: '2026-06-01'),
        _activity('2', type: 'feeding', date: '2026-06-02'),
      ];
      expect(filterActivitiesByType(activities, null), activities);
    });

    test('keeps only activities of the given type', () {
      final activities = [
        _activity('1', type: 'harvest', date: '2026-06-01'),
        _activity('2', type: 'feeding', date: '2026-06-02'),
        _activity('3', type: 'harvest', date: '2026-06-03'),
      ];
      final result = filterActivitiesByType(activities, 'harvest');
      expect(result.map((a) => a.id).toList(), ['1', '3']);
    });

    test('a type matching nothing returns an empty list', () {
      final activities = [_activity('1', type: 'harvest', date: '2026-06-01')];
      expect(filterActivitiesByType(activities, 'treatment'), isEmpty);
    });
  });

  group('filterActivitiesByDateRange (#42/#43, FR-AC-5/FR-AC-6)', () {
    test('a null range is a passthrough', () {
      final activities = [_activity('1', date: '2026-06-01')];
      expect(filterActivitiesByDateRange(activities, null), activities);
    });

    test(
      'keeps activities within the inclusive range, both bounds included',
      () {
        final activities = [
          _activity('before', date: '2026-05-30'),
          _activity('start', date: '2026-06-01'),
          _activity('inside', date: '2026-06-05'),
          _activity('end', date: '2026-06-10'),
          _activity('after', date: '2026-06-11'),
        ];
        final range = ActivityDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        );

        final result = filterActivitiesByDateRange(activities, range);

        expect(result.map((a) => a.id).toList(), ['start', 'inside', 'end']);
      },
    );

    test('a range matching no activity returns an empty list', () {
      final activities = [_activity('1', date: '2026-01-01')];
      final range = ActivityDateRange(
        start: DateTime(2026, 6, 1),
        end: DateTime(2026, 6, 10),
      );
      expect(filterActivitiesByDateRange(activities, range), isEmpty);
    });

    test('a single-day range (start == end) matches only that day', () {
      final activities = [
        _activity('day', date: '2026-06-05'),
        _activity('other', date: '2026-06-06'),
      ];
      final range = ActivityDateRange(
        start: DateTime(2026, 6, 5),
        end: DateTime(2026, 6, 5),
      );
      expect(
        filterActivitiesByDateRange(
          activities,
          range,
        ).map((a) => a.id).toList(),
        ['day'],
      );
    });
  });

  group('filterActivities — combined (#42/#43 AC: filters can be combined)', () {
    test('applies both the type and date-range filters together', () {
      final activities = [
        _activity('match', type: 'harvest', date: '2026-06-05'),
        // Right type, wrong date.
        _activity('wrong-date', type: 'harvest', date: '2026-01-01'),
        // Right date, wrong type.
        _activity('wrong-type', type: 'feeding', date: '2026-06-05'),
      ];
      final range = ActivityDateRange(
        start: DateTime(2026, 6, 1),
        end: DateTime(2026, 6, 10),
      );

      final result = filterActivities(
        activities,
        type: 'harvest',
        dateRange: range,
      );

      expect(result.map((a) => a.id).toList(), ['match']);
    });

    test('with neither filter set, returns every activity unchanged', () {
      final activities = [
        _activity('1', date: '2026-06-01'),
        _activity('2', date: '2026-06-02'),
      ];
      expect(filterActivities(activities), activities);
    });

    test(
      'a combination matching nothing returns an empty list (no-results state)',
      () {
        final activities = [
          _activity('1', type: 'harvest', date: '2026-06-05'),
        ];
        final range = ActivityDateRange(
          start: DateTime(2026, 1, 1),
          end: DateTime(2026, 1, 31),
        );
        expect(
          filterActivities(activities, type: 'harvest', dateRange: range),
          isEmpty,
        );
      },
    );
  });
}
