import 'dart:math' as math;

/// Mean Earth radius in metres (WGS84 mean radius) — matches PostGIS's
/// `geography` type's own sphere approximation (D-6) closely enough that the
/// client-side (offline) and server-side (`ST_Distance` over `geography`,
/// services/apiaries/api/apiaries.go's getApiaryDistance) straight-line
/// distances agree within the tolerance the acceptance criteria expect
/// (#37/FR-AP-5).
const _earthRadiusMeters = 6371000.0;

/// Straight-line (haversine, great-circle) distance in metres between two
/// WGS84 coordinates. Pure/offline — no network or platform dependency — so
/// it satisfies D-15/#37's "works fully offline" requirement and is directly
/// unit-testable without a widget harness.
///
/// The single distance primitive in the client (#445 consolidated the former
/// `core/geo/distance.dart` twin, which took the same arguments lon-first,
/// into this one), behind:
///  - offline proximity ordering (FR-AP-2, #33): sorting the locally-synced
///    apiary set by distance to the device's current location when the
///    server's PostGIS-ordered `near` list isn't reachable.
///  - the two-apiary "measure distance" feature (FR-AP-5, D-15: "straight-line
///    (haversine) distance... works fully offline... shown in km", #37).
///
/// Arguments are **latitude first** for each point (`lat1, lon1, lat2, lon2`).
/// Keep it that way: they are all `double`, so a call site that swaps a
/// point's latitude and longitude still compiles and just returns a wrong
/// distance — which is precisely why the lon-first twin was removed rather
/// than kept alongside this one.
double haversineDistanceMeters({
  required double lat1,
  required double lon1,
  required double lat2,
  required double lon2,
}) {
  final phi1 = _degToRad(lat1);
  final phi2 = _degToRad(lat2);
  final deltaPhi = _degToRad(lat2 - lat1);
  final deltaLambda = _degToRad(lon2 - lon1);

  final a =
      math.sin(deltaPhi / 2) * math.sin(deltaPhi / 2) +
      math.cos(phi1) *
          math.cos(phi2) *
          math.sin(deltaLambda / 2) *
          math.sin(deltaLambda / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));

  return _earthRadiusMeters * c;
}

/// Convenience: the same calculation, returned in kilometres (D-15 — the
/// distance feature displays km, not metres).
double haversineDistanceKm({
  required double lat1,
  required double lon1,
  required double lat2,
  required double lon2,
}) =>
    haversineDistanceMeters(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2) /
    1000;

double _degToRad(double deg) => deg * math.pi / 180;
