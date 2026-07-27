import 'package:beekeepingit_client/core/geo/haversine.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test('a known 1-degree-of-latitude span is close to 111km', () {
      // 1 degree of latitude is ~111.19km anywhere on a sphere — a coarse
      // but useful sanity check independent of the other fixture.
      final d = haversineDistanceMeters(lat1: 0, lon1: 0, lat2: 1, lon2: 0);
      expect(d, closeTo(111195, 500));
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
