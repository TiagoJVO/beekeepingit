import 'package:beekeepingit_client/features/journeys/journey_matching.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:flutter_test/flutter_test.dart';

Journey _journey(String id, {String status = journeyStatusOpen}) => Journey(
  id: id,
  name: 'Journey $id',
  mainActivityType: 'harvest',
  status: status,
);

void main() {
  group('splitJourneyCandidates (#46, D-21)', () {
    test('an empty candidate list splits to empty open/closed', () {
      final result = splitJourneyCandidates(const []);

      expect(result.open, isEmpty);
      expect(result.closed, isEmpty);
      expect(result.isEmpty, isTrue);
    });

    test('open and closed journeys are separated, order preserved', () {
      final open1 = _journey('open-1');
      final closed1 = _journey('closed-1', status: journeyStatusClosed);
      final open2 = _journey('open-2');

      final result = splitJourneyCandidates([open1, closed1, open2]);

      expect(result.open, [open1, open2]);
      expect(result.closed, [closed1]);
    });

    test(
      'a status this client does not know is treated as closed (not open)',
      () {
        final unknown = _journey('mystery', status: 'archived');

        final result = splitJourneyCandidates([unknown]);

        expect(result.open, isEmpty);
        expect(result.closed, [unknown]);
      },
    );
  });

  group('unplannedPickerCandidates (#440, D-31)', () {
    test('an empty candidate list yields empty', () {
      expect(unplannedPickerCandidates(const [], planned: const []), isEmpty);
    });

    test('keeps open journeys, dropping any closed one defensively', () {
      final open1 = _journey('open-1');
      final closed1 = _journey('closed-1', status: journeyStatusClosed);
      final open2 = _journey('open-2');

      final result = unplannedPickerCandidates([
        open1,
        closed1,
        open2,
      ], planned: const []);

      expect(result, [open1, open2]);
    });

    test('removes any journey already present in the planned set so the '
        'same journey never appears in both lists', () {
      final shared = _journey('shared');
      final onlyUnplanned = _journey('only-unplanned');

      final result = unplannedPickerCandidates(
        [shared, onlyUnplanned],
        planned: [shared],
      );

      expect(result, [onlyUnplanned]);
    });

    test('preserves the incoming (newest-first) order', () {
      final newest = _journey('newest');
      final older = _journey('older');

      final result = unplannedPickerCandidates([
        newest,
        older,
      ], planned: const []);

      expect(result, [newest, older]);
    });
  });

  group(
    'JourneyPickerCandidates.autoSelected (#46 AC: auto-match hit/miss)',
    () {
      test('auto-match HIT: picks the first (newest) open match', () {
        final newest = _journey('newest');
        final older = _journey('older');
        final candidates = JourneyPickerCandidates(
          open: [newest, older],
          closed: const [],
        );

        expect(candidates.autoSelected, same(newest));
      });

      test('auto-match MISS: no open matches at all -> null, even with closed matches present', () {
        final candidates = JourneyPickerCandidates(
          open: const [],
          closed: [_journey('closed-only', status: journeyStatusClosed)],
        );

        expect(candidates.autoSelected, isNull);
      });

      test('auto-match MISS: no candidates whatsoever -> null', () {
        expect(JourneyPickerCandidates.empty.autoSelected, isNull);
      });

      test('never auto-selects a closed journey even if it were (incorrectly) in `open`', () {
        // Defensive: splitJourneyCandidates is what's responsible for routing
        // by status, but autoSelected itself must only ever look at `open` —
        // this pins that contract directly against the type, independent of
        // the split function's own correctness.
        final onlyClosed = _journey('c', status: journeyStatusClosed);
        final candidates = JourneyPickerCandidates(
          open: const [],
          closed: [onlyClosed],
        );
        expect(candidates.autoSelected, isNot(onlyClosed));
        expect(candidates.autoSelected, isNull);
      });
    },
  );
}
