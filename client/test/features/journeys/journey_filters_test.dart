import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/journeys/journey_filters.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:flutter_test/flutter_test.dart';

Journey _journey(
  String id, {
  String mainActivityType = 'harvest',
  String status = journeyStatusOpen,
}) => Journey(
  id: id,
  name: 'Journey $id',
  mainActivityType: mainActivityType,
  status: status,
);

Activity _activity(
  String id, {
  required String date,
  String apiaryId = 'a1',
  String? journeyId,
  String type = 'generic',
}) => Activity(
  id: id,
  apiaryId: apiaryId,
  type: type,
  occurredAt: date,
  attributes: const {},
  journeyId: journeyId,
);

void main() {
  group('filterJourneysByType() (#47 AC: filterable by activity type)', () {
    test('a null type is a passthrough', () {
      final journeys = [
        _journey('j1', mainActivityType: 'harvest'),
        _journey('j2', mainActivityType: 'feeding'),
      ];
      expect(filterJourneysByType(journeys, null), journeys);
    });

    test('keeps only journeys whose mainActivityType matches', () {
      final harvest = _journey('j1', mainActivityType: 'harvest');
      final feeding = _journey('j2', mainActivityType: 'feeding');

      final result = filterJourneysByType([harvest, feeding], 'harvest');

      expect(result, [harvest]);
    });

    test('an unmatched type yields an empty result', () {
      final journeys = [_journey('j1', mainActivityType: 'harvest')];
      expect(filterJourneysByType(journeys, 'treatment'), isEmpty);
    });
  });

  group('filterJourneysByDateRange() (#47 AC: filterable by date range — '
      'matched against the journey\'s own recorded activities, see '
      'journeys_list_screen.dart\'s doc for the interpretation)', () {
    test('a null range is a passthrough', () {
      final journeys = [_journey('j1')];
      expect(filterJourneysByDateRange(journeys, const {}, null), journeys);
    });

    test('keeps a journey with an activity inside the range', () {
      final j1 = _journey('j1');
      final activitiesByJourney = {
        'j1': [_activity('a1', date: '2026-06-05', journeyId: 'j1')],
      };

      final result = filterJourneysByDateRange(
        [j1],
        activitiesByJourney,
        JourneyDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        ),
      );

      expect(result, [j1]);
    });

    test('excludes a journey whose activities all fall outside the range', () {
      final j1 = _journey('j1');
      final activitiesByJourney = {
        'j1': [_activity('a1', date: '2020-01-01', journeyId: 'j1')],
      };

      final result = filterJourneysByDateRange(
        [j1],
        activitiesByJourney,
        JourneyDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        ),
      );

      expect(result, isEmpty);
    });

    test('excludes a journey with no recorded activities at all', () {
      final j1 = _journey('j1');

      final result = filterJourneysByDateRange(
        [j1],
        const {},
        JourneyDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        ),
      );

      expect(result, isEmpty);
    });

    test('range bounds are inclusive', () {
      final j1 = _journey('j1');
      final activitiesByJourney = {
        'j1': [_activity('a1', date: '2026-06-10', journeyId: 'j1')],
      };

      final result = filterJourneysByDateRange(
        [j1],
        activitiesByJourney,
        JourneyDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        ),
      );

      expect(result, [j1]);
    });
  });

  group('filterJourneys() (#47 AC: date-range and activity-type filters can be '
      'combined)', () {
    test('applies both filters together', () {
      final match = _journey('match', mainActivityType: 'harvest');
      final wrongDate = _journey('wrong-date', mainActivityType: 'harvest');
      final wrongType = _journey('wrong-type', mainActivityType: 'feeding');
      final activitiesByJourney = {
        'match': [_activity('a1', date: '2026-06-05', journeyId: 'match')],
        'wrong-date': [
          _activity('a2', date: '2020-01-01', journeyId: 'wrong-date'),
        ],
        'wrong-type': [
          _activity('a3', date: '2026-06-05', journeyId: 'wrong-type'),
        ],
      };

      final result = filterJourneys(
        [match, wrongDate, wrongType],
        activitiesByJourney,
        type: 'harvest',
        dateRange: JourneyDateRange(
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 6, 10),
        ),
      );

      expect(result, [match]);
    });

    test('an empty result set is returned (not an error) when nothing matches '
        'both filters (#47 AC: clear empty state)', () {
      final journeys = [
        _journey('j1', mainActivityType: 'feeding'),
        _journey('j2', mainActivityType: 'treatment'),
      ];

      final result = filterJourneys(
        journeys,
        const {},
        type: 'harvest',
        dateRange: null,
      );

      expect(result, isEmpty);
    });
  });

  group('groupActivitiesByJourney()', () {
    test('groups activities by their journeyId, dropping journeyless ones', () {
      final a1 = _activity('a1', date: '2026-06-01', journeyId: 'j1');
      final a2 = _activity('a2', date: '2026-06-02', journeyId: 'j1');
      final a3 = _activity('a3', date: '2026-06-03', journeyId: 'j2');
      final noJourney = _activity('a4', date: '2026-06-04');

      final result = groupActivitiesByJourney([a1, a2, a3, noJourney]);

      expect(result['j1'], [a1, a2]);
      expect(result['j2'], [a3]);
      expect(result.containsKey(null), isFalse);
      expect(result.values.expand((v) => v), isNot(contains(noJourney)));
    });
  });

  group('computeJourneyProgress() (#47, FR-JO-2 — deliberately minimal, '
      'NOT #49\'s full statistics)', () {
    test('planned=0 yields JourneyProgress.zero', () {
      final result = computeJourneyProgress(
        plannedApiaryIds: const [],
        journeyActivities: const [],
      );
      expect(result.planned, 0);
      expect(result.done, 0);
    });

    test('an apiary counts done once it has a matching recorded activity', () {
      final result = computeJourneyProgress(
        plannedApiaryIds: const ['a1', 'a2'],
        journeyActivities: [
          _activity(
            'act1',
            date: '2026-06-01',
            apiaryId: 'a1',
            journeyId: 'j1',
          ),
        ],
      );

      expect(result.planned, 2);
      expect(result.done, 1);
    });

    test(
      'multiple activities against the same planned apiary don\'t double-count',
      () {
        final result = computeJourneyProgress(
          plannedApiaryIds: const ['a1'],
          journeyActivities: [
            _activity(
              'act1',
              date: '2026-06-01',
              apiaryId: 'a1',
              journeyId: 'j1',
            ),
            _activity(
              'act2',
              date: '2026-06-05',
              apiaryId: 'a1',
              journeyId: 'j1',
            ),
          ],
        );

        expect(result.planned, 1);
        expect(result.done, 1);
      },
    );

    test('an activity against an apiary NOT in the plan is ignored (extra '
        'activities never inflate the done count beyond planned)', () {
      final result = computeJourneyProgress(
        plannedApiaryIds: const ['a1'],
        journeyActivities: [
          _activity(
            'act1',
            date: '2026-06-01',
            apiaryId: 'a9',
            journeyId: 'j1',
          ),
        ],
      );

      expect(result.planned, 1);
      expect(result.done, 0);
    });

    test('all planned apiaries visited yields done == planned', () {
      final result = computeJourneyProgress(
        plannedApiaryIds: const ['a1', 'a2'],
        journeyActivities: [
          _activity(
            'act1',
            date: '2026-06-01',
            apiaryId: 'a1',
            journeyId: 'j1',
          ),
          _activity(
            'act2',
            date: '2026-06-02',
            apiaryId: 'a2',
            journeyId: 'j1',
          ),
        ],
      );

      expect(result.planned, 2);
      expect(result.done, 2);
    });
  });

  group('progressByJourney()', () {
    test('computes each journey\'s progress independently, keyed by id', () {
      final j1 = _journey('j1');
      final j2 = _journey('j2');
      final plannedApiaryIdsByJourney = {
        'j1': ['a1', 'a2'],
        'j2': ['a3'],
      };
      final activitiesByJourney = {
        'j1': [
          _activity(
            'act1',
            date: '2026-06-01',
            apiaryId: 'a1',
            journeyId: 'j1',
          ),
        ],
      };

      final result = progressByJourney(
        [j1, j2],
        plannedApiaryIdsByJourney,
        activitiesByJourney,
      );

      expect(result['j1']!.planned, 2);
      expect(result['j1']!.done, 1);
      expect(result['j2']!.planned, 1);
      expect(result['j2']!.done, 0);
    });

    test('a journey with no plan items at all gets JourneyProgress.zero', () {
      final j1 = _journey('j1');

      final result = progressByJourney([j1], const {}, const {});

      expect(result['j1']!.planned, 0);
      expect(result['j1']!.done, 0);
    });
  });
}
