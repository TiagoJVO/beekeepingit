import 'dart:math' as math;

/// Mean Earth radius in metres (WGS84 mean radius) — the standard haversine
/// constant.
const double _earthRadiusMeters = 6371000;

/// Straight-line (haversine) distance in metres between two WGS84
/// lon/lat points. Works fully offline (no network/service call) — the
/// shared distance primitive behind:
///  - offline proximity ordering (FR-AP-2, #33): sorting the locally-synced
///    apiary set by distance to the device's current location when the
///    server's PostGIS-ordered `near` list isn't reachable.
///  - the two-apiary "measure distance" feature (FR-AP-5, D-15: "straight-line
///    (haversine) distance... works fully offline... shown in km", #37).
///
/// This is the same great-circle approximation PostGIS's `geography` type
/// uses server-side (D-6), so on-device and server-computed distances agree
/// closely for the short apiary-scale distances this app deals with.
double haversineDistanceMeters({
  required double lon1,
  required double lat1,
  required double lon2,
  required double lat2,
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

double _degToRad(double deg) => deg * (math.pi / 180);
