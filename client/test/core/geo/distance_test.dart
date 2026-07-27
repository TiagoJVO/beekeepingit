import 'package:beekeepingit_client/core/geo/distance.dart';
import 'package:flutter_test/flutter_test.dart';

/// Direct unit coverage for core/geo/distance.dart's `haversineDistanceMeters`
/// (MEDIUM finding) — this is the implementation apiaries_repository.dart's
/// `sortApiariesByDistance` and apiaries_list_screen.dart's per-row distance
/// display actually call (both import `core/geo/distance.dart`, not the
/// separate `core/geo/haversine.dart`, which has its own direct coverage in
/// haversine_test.dart). Note: `core/geo/distance.dart` and
/// `core/geo/haversine.dart` are two independent implementations of the same
/// great-circle calculation with different named-parameter orders
/// (lon-then-lat here vs. lat-then-lon there) — a separate, already in-flight
/// PR consolidates that duplication, so this file deliberately only ADDS
/// coverage for the existing `distance.dart` shape rather than renaming,
/// deleting, or repointing any import.
void main() {
  group('haversineDistanceMeters (core/geo/distance.dart)', () {
    test('is zero for identical coordinates', () {
      final d = haversineDistanceMeters(
        lon1: -8.6109,
        lat1: 41.1496,
        lon2: -8.6109,
        lat2: 41.1496,
      );
      expect(d, closeTo(0, 0.001));
    });

    test(
      'matches the known Porto Cathedral -> Braga Se distance (~47.6km)',
      () {
        // Same fixture pair as the server-side ST_Distance test
        // (services/apiaries/main_test.go's TestApiariesRest_Distance_
        // KnownCoordinatePair) and core/geo/haversine.dart's own unit test —
        // the client/server straight-line values must agree within a
        // reasonable tolerance regardless of which client-side
        // implementation computes it.
        final d = haversineDistanceMeters(
          lon1: -8.6109,
          lat1: 41.1496,
          lon2: -8.4265,
          lat2: 41.5503,
        );
        expect(d, closeTo(47600, 2000));
      },
    );

    test('is symmetric', () {
      final ab = haversineDistanceMeters(
        lon1: -8.6109,
        lat1: 41.1496,
        lon2: -8.4265,
        lat2: 41.5503,
      );
      final ba = haversineDistanceMeters(
        lon1: -8.4265,
        lat1: 41.5503,
        lon2: -8.6109,
        lat2: 41.1496,
      );
      expect(ab, closeTo(ba, 0.001));
    });

    test('a known 1-degree-of-latitude span is close to 111km', () {
      // 1 degree of latitude is ~111.19km anywhere on a sphere — a coarse
      // but useful sanity check independent of the other fixture.
      final d = haversineDistanceMeters(lon1: 0, lat1: 0, lon2: 0, lat2: 1);
      expect(d, closeTo(111195, 500));
    });

    test('a small east-west offset at the equator matches the ~1.11km/0.01deg '
        'figure sortApiariesByDistance/list-screen distance tests rely on', () {
      final d = haversineDistanceMeters(
        lon1: 0.0,
        lat1: 0.0,
        lon2: 0.01,
        lat2: 0.0,
      );
      expect(d, closeTo(1113, 5));
    });
  });
}
