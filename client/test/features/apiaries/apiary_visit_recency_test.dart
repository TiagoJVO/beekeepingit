import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_visit_recency.dart';
import 'package:flutter_test/flutter_test.dart';

// A fixed "now" for every test — 2026-06-10 — so the date-relative
// assertions never depend on the wall clock the suite happens to run under
// (the same convention as todo_filters_test.dart's own `_today`).
final _now = DateTime(2026, 6, 10);

Apiary _apiary(String id, {String name = 'Apiary'}) =>
    Apiary(id: id, name: name, hiveCount: 0);

/// [occurredAt] is the plain `YYYY-MM-DD` string the local row actually
/// stores (Activity.occurredAt's own doc comment / the server's `DATE`
/// column) — never an ISO timestamp.
Activity _activity(
  String id, {
  required String apiaryId,
  required String occurredAt,
  String type = 'inspection',
}) => Activity(
  id: id,
  apiaryId: apiaryId,
  type: type,
  occurredAt: occurredAt,
  attributes: const {},
);

/// The `YYYY-MM-DD` string for the day [days] before [_now].
String _daysAgo(int days) {
  final d = _now.subtract(Duration(days: days));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

void main() {
  group('apiaryVisitRecencyDays (D-35)', () {
    test("is 30 days — D-35's deliberate default", () {
      expect(apiaryVisitRecencyDays, 30);
    });
  });

  group('lastVisitByApiary', () {
    test('is empty for no activities', () {
      expect(lastVisitByApiary(const []), isEmpty);
    });

    test('the most recent activity wins when an apiary has several', () {
      final result = lastVisitByApiary([
        _activity('a1', apiaryId: 'A', occurredAt: '2026-05-01'),
        _activity('a2', apiaryId: 'A', occurredAt: '2026-06-01'),
        _activity('a3', apiaryId: 'A', occurredAt: '2026-04-15'),
      ]);

      expect(result, {'A': DateTime(2026, 6, 1)});
    });

    test('keeps one entry per apiary', () {
      final result = lastVisitByApiary([
        _activity('a1', apiaryId: 'A', occurredAt: '2026-05-01'),
        _activity('a2', apiaryId: 'B', occurredAt: '2026-06-02'),
        _activity('a3', apiaryId: 'A', occurredAt: '2026-05-09'),
      ]);

      expect(result, {'A': DateTime(2026, 5, 9), 'B': DateTime(2026, 6, 2)});
    });
  });

  group('apiariesNotVisitedSince — boundary (inclusive at the threshold)', () {
    test('visited 29 days ago is EXCLUDED (inside the 30-day window)', () {
      final result = apiariesNotVisitedSince(
        apiaries: [_apiary('A')],
        activities: [_activity('a1', apiaryId: 'A', occurredAt: _daysAgo(29))],
        now: _now,
      );

      expect(result, isEmpty);
    });

    test('visited exactly 30 days ago is INCLUDED (>= threshold counts as not '
        'visited recently)', () {
      final result = apiariesNotVisitedSince(
        apiaries: [_apiary('A')],
        activities: [_activity('a1', apiaryId: 'A', occurredAt: _daysAgo(30))],
        now: _now,
      );

      expect(result.map((r) => r.apiary.id), ['A']);
      expect(result.single.daysSinceLastVisit, 30);
    });

    test('visited 31 days ago is included', () {
      final result = apiariesNotVisitedSince(
        apiaries: [_apiary('A')],
        activities: [_activity('a1', apiaryId: 'A', occurredAt: _daysAgo(31))],
        now: _now,
      );

      expect(result.map((r) => r.apiary.id), ['A']);
    });

    test('an explicit non-default window is honoured', () {
      final result = apiariesNotVisitedSince(
        apiaries: [_apiary('A')],
        activities: [_activity('a1', apiaryId: 'A', occurredAt: _daysAgo(10))],
        now: _now,
        days: 7,
      );

      expect(result.map((r) => r.apiary.id), ['A']);
    });

    test('a time-of-day component on `now` does not shift the boundary', () {
      final result = apiariesNotVisitedSince(
        apiaries: [_apiary('A')],
        activities: [_activity('a1', apiaryId: 'A', occurredAt: _daysAgo(29))],
        now: DateTime(2026, 6, 10, 23, 59, 59),
      );

      expect(result, isEmpty);
    });
  });

  group('apiariesNotVisitedSince — membership', () {
    test('a recently visited apiary is excluded', () {
      final result = apiariesNotVisitedSince(
        apiaries: [
          _apiary('A'),
          _apiary('B', name: 'B'),
        ],
        activities: [
          _activity('a1', apiaryId: 'A', occurredAt: _daysAgo(2)),
          _activity('a2', apiaryId: 'B', occurredAt: _daysAgo(60)),
        ],
        now: _now,
      );

      expect(result.map((r) => r.apiary.id), ['B']);
    });

    test('an empty apiaries list yields no results', () {
      final result = apiariesNotVisitedSince(
        apiaries: const [],
        activities: [_activity('a1', apiaryId: 'A', occurredAt: _daysAgo(60))],
        now: _now,
      );

      expect(result, isEmpty);
    });

    test('with no activities at all every apiary is never-visited', () {
      final result = apiariesNotVisitedSince(
        apiaries: [
          _apiary('A', name: 'Alfa'),
          _apiary('B', name: 'Beta'),
        ],
        activities: const [],
        now: _now,
      );

      expect(result.map((r) => r.apiary.id), ['A', 'B']);
      expect(result.every((r) => r.lastVisitedAt == null), isTrue);
      expect(result.every((r) => r.neverVisited), isTrue);
      expect(result.every((r) => r.daysSinceLastVisit == null), isTrue);
    });

    test(
      'activities for an apiary id not in the list are ignored, not a crash',
      () {
        final result = apiariesNotVisitedSince(
          apiaries: [_apiary('A', name: 'Alfa')],
          activities: [
            _activity('a1', apiaryId: 'GHOST', occurredAt: _daysAgo(1)),
            _activity('a2', apiaryId: 'A', occurredAt: _daysAgo(45)),
          ],
          now: _now,
        );

        expect(result.map((r) => r.apiary.id), ['A']);
        expect(result.single.daysSinceLastVisit, 45);
      },
    );

    test('only the most recent activity decides membership', () {
      final result = apiariesNotVisitedSince(
        apiaries: [_apiary('A')],
        activities: [
          _activity('a1', apiaryId: 'A', occurredAt: _daysAgo(400)),
          _activity('a2', apiaryId: 'A', occurredAt: _daysAgo(3)),
        ],
        now: _now,
      );

      expect(result, isEmpty);
    });
  });

  group('apiariesNotVisitedSince — ordering', () {
    test('never-visited apiaries sort above stale-but-visited ones', () {
      final result = apiariesNotVisitedSince(
        apiaries: [
          _apiary('stale', name: 'Alfa'),
          _apiary('never', name: 'Zulu'),
        ],
        activities: [
          _activity('a1', apiaryId: 'stale', occurredAt: _daysAgo(365)),
        ],
        now: _now,
      );

      expect(result.map((r) => r.apiary.id), ['never', 'stale']);
    });

    test('among stale apiaries the longest-since-visit comes first', () {
      final result = apiariesNotVisitedSince(
        apiaries: [
          _apiary('recent-ish', name: 'Alfa'),
          _apiary('oldest', name: 'Beta'),
          _apiary('middle', name: 'Charlie'),
        ],
        activities: [
          _activity('a1', apiaryId: 'recent-ish', occurredAt: _daysAgo(31)),
          _activity('a2', apiaryId: 'oldest', occurredAt: _daysAgo(200)),
          _activity('a3', apiaryId: 'middle', occurredAt: _daysAgo(90)),
        ],
        now: _now,
      );

      expect(result.map((r) => r.apiary.id), [
        'oldest',
        'middle',
        'recent-ish',
      ]);
    });

    test('two apiaries with the same last-visit date tie-break by name', () {
      final result = apiariesNotVisitedSince(
        apiaries: [
          _apiary('z', name: 'Zulu'),
          _apiary('a', name: 'Alfa'),
        ],
        activities: [
          _activity('a1', apiaryId: 'z', occurredAt: _daysAgo(40)),
          _activity('a2', apiaryId: 'a', occurredAt: _daysAgo(40)),
        ],
        now: _now,
      );

      expect(result.map((r) => r.apiary.name), ['Alfa', 'Zulu']);
    });

    test('never-visited apiaries tie-break by name too', () {
      final result = apiariesNotVisitedSince(
        apiaries: [
          _apiary('z', name: 'Zulu'),
          _apiary('m', name: 'Mike'),
          _apiary('a', name: 'Alfa'),
        ],
        activities: const [],
        now: _now,
      );

      expect(result.map((r) => r.apiary.name), ['Alfa', 'Mike', 'Zulu']);
    });
  });
}
