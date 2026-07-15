import 'package:beekeepingit_client/core/geo/distance.dart';
import 'package:flutter_test/flutter_test.dart';

/// `core/geo/distance.dart`'s `haversineDistanceMeters` drives the apiaries
/// offline proximity-sort hot path (`apiaries_list_screen.dart`,
/// `apiaries_repository.dart`) but — unlike its sibling implementation in
/// `core/geo/haversine.dart` (see `haversine_test.dart`) — had no test
/// coverage of its own. Note this file's parameter order is
/// `lon1/lat1/lon2/lat2`, not `haversine.dart`'s `lat1/lon1/lat2/lon2` — the
/// two implementations are intentionally left as separate, uncoupled copies
/// here (consolidating them touches the apiaries call sites, which are owned
/// by a separate, concurrent PR); this file only closes the coverage gap on
/// the copy that had none.
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
        // Same fixture pair as haversine_test.dart / the server-side
        // ST_Distance test (services/apiaries/main_test.go's
        // TestApiariesRest_Distance_KnownCoordinatePair).
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
  });
}
