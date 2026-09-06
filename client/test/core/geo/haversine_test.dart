import 'package:beekeepingit_client/core/geo/haversine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Direct unit coverage for core/geo/haversine.dart — the client's single
/// straight-line distance primitive (D-15, FR-AP-5), and the one
/// apiaries_repository.dart's `sortApiariesByDistance` (FR-AP-2),
/// apiaries_list_screen.dart's per-row distance display and
/// apiary_map_screen.dart's measure overlay all call.
///
/// #445 consolidated the former `core/geo/distance.dart` twin — the same
/// great-circle calculation behind a lon-first parameter order — into this
/// one; the cases below are the union of both files' coverage, restated in
/// the surviving lat-first order.
void main() {
  group('haversineDistanceMeters', () {
    test('is zero for identical coordinates', () {
      final d = haversineDistanceMeters(
        lat1: 41.1496,
        lon1: -8.6109,
        lat2: 41.1496,
        lon2: -8.6109,
      );
      expect(d, closeTo(0, 0.001));
    });

    test(
      'matches the known Porto Cathedral -> Braga Sé distance (~47.6km)',
      () {
        // Same fixture pair as the server-side ST_Distance test
        // (services/apiaries/main_test.go's TestApiariesRest_Distance_
        // KnownCoordinatePair) — the client/server straight-line values must
        // agree within a reasonable tolerance.
        final d = haversineDistanceMeters(
          lat1: 41.1496,
          lon1: -8.6109,
          lat2: 41.5503,
          lon2: -8.4265,
        );
        expect(d, closeTo(47600, 2000));
      },
    );

    test('is symmetric', () {
      final ab = haversineDistanceMeters(
        lat1: 41.1496,
        lon1: -8.6109,
        lat2: 41.5503,
        lon2: -8.4265,
      );
      final ba = haversineDistanceMeters(
        lat1: 41.5503,
        lon1: -8.4265,
        lat2: 41.1496,
        lon2: -8.6109,
      );
      expect(ab, closeTo(ba, 0.001));
    });

    test('distinguishes latitude from longitude on an asymmetric pair (guard '
        'against a swapped parameter order, #445)', () {
      // Deliberately asymmetric and away from the equator: the latitude
      // span (1 degree) and the longitude span (2 degrees) differ, so
      // passing the four numbers in the wrong order yields a materially
      // different distance instead of coincidentally matching (as it would
      // for the pure 1-degree span at 0,0 below).
      final correct = haversineDistanceMeters(
        lat1: 41,
        lon1: -8,
        lat2: 42,
        lon2: -6,
      );
      expect(correct, closeTo(200262, 1000));

      // The same four numbers with latitude and longitude interchanged must
      // NOT produce the same distance — that is what makes the assertion
      // above a real guard rather than a tautology.
      final swapped = haversineDistanceMeters(
        lat1: -8,
        lon1: 41,
        lat2: -6,
        lon2: 42,
      );
      expect((swapped - correct).abs(), greaterThan(40000));
    });

    test('a known 1-degree-of-latitude span is close to 111km', () {
      // 1 degree of latitude is ~111.19km anywhere on a sphere — a coarse
      // but useful sanity check independent of the other fixture.
      final d = haversineDistanceMeters(lat1: 0, lon1: 0, lat2: 1, lon2: 0);
      expect(d, closeTo(111195, 500));
    });

    test('a small east-west offset at the equator matches the ~1.11km/0.01deg '
        'figure sortApiariesByDistance/list-screen distance tests rely on', () {
      final d = haversineDistanceMeters(
        lat1: 0.0,
        lon1: 0.0,
        lat2: 0.0,
        lon2: 0.01,
      );
      expect(d, closeTo(1113, 5));
    });
  });

  group('haversineDistanceKm', () {
    test('is the metres result divided by 1000', () {
      final km = haversineDistanceKm(
        lat1: 41.1496,
        lon1: -8.6109,
        lat2: 41.5503,
        lon2: -8.4265,
      );
      final m = haversineDistanceMeters(
        lat1: 41.1496,
        lon1: -8.6109,
        lat2: 41.5503,
        lon2: -8.4265,
      );
      expect(km, closeTo(m / 1000, 0.0001));
    });
  });
}
