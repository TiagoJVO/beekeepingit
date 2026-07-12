import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

/// The device's current location, or a reason it isn't available — the
/// proximity-ordering AC (FR-AP-2, #33) explicitly requires a "clear
/// indication" when location is unavailable/denied rather than silently
/// falling back, so callers need to distinguish these cases, not just get a
/// nullable lon/lat.
sealed class DeviceLocation {
  const DeviceLocation();
}

class DeviceLocationAvailable extends DeviceLocation {
  const DeviceLocationAvailable({required this.lon, required this.lat});
  final double lon;
  final double lat;
}

/// Location services are off at the OS/browser level (distinct from a
/// per-app permission denial).
class DeviceLocationServicesDisabled extends DeviceLocation {
  const DeviceLocationServicesDisabled();
}

/// Permission was denied (either just now or permanently) — covers
/// [LocationPermission.denied] and [LocationPermission.deniedForever].
class DeviceLocationPermissionDenied extends DeviceLocation {
  const DeviceLocationPermissionDenied();
}

/// Fetching the position failed for some other reason (timeout, platform
/// error, ...).
class DeviceLocationUnavailable extends DeviceLocation {
  const DeviceLocationUnavailable();
}

/// Thin wrapper around `package:geolocator` behind an interface the list
/// screen/repository can fake in tests (geolocator's own plugin channel
/// isn't available under `flutter test`). Requests permission if needed and
/// resolves to one of [DeviceLocation]'s variants rather than throwing, so
/// callers can render the "location unavailable/denied" fallback state
/// (#33 AC) instead of an unhandled exception.
class DeviceLocationService {
  const DeviceLocationService();

  Future<DeviceLocation> current() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return const DeviceLocationServicesDisabled();
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return const DeviceLocationPermissionDenied();
    }

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
        ),
      );
      return DeviceLocationAvailable(
        lon: position.longitude,
        lat: position.latitude,
      );
    } catch (_) {
      return const DeviceLocationUnavailable();
    }
  }
}

/// Overridable in tests (see apiaries_list_screen_test.dart) to stand in a
/// fake without touching the real geolocator platform channel.
final deviceLocationServiceProvider = Provider<DeviceLocationService>(
  (ref) => const DeviceLocationService(),
);
