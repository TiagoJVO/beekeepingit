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
    } on Exception {
      // Narrowed from a bare `catch` (MEDIUM finding): a bare catch also
      // swallows `Error` subtypes (e.g. a programming mistake surfacing as
      // a `StateError`/`TypeError`), silently reporting a real bug as the
      // user-facing "location unavailable" state instead of surfacing it.
      // Only genuine platform/plugin failures (timeouts, unsupported
      // platform, ...) are `Exception`s and degrade gracefully here.
      return const DeviceLocationUnavailable();
    }
  }
}

/// Overridable in tests (see apiaries_list_screen_test.dart) to stand in a
/// fake without touching the real geolocator platform channel.
final deviceLocationServiceProvider = Provider<DeviceLocationService>(
  (ref) => const DeviceLocationService(),
);

/// Caches the device's current location behind a Riverpod provider so every
/// simultaneously-mounted consumer shares exactly ONE underlying
/// permission/location request rather than each independently calling
/// [DeviceLocationService.current] and re-triggering the OS location
/// prompt (CRITICAL finding: apiaries_list_screen.dart's proximity-ordering
/// banner and apiary_map_screen.dart's user-location marker are both alive
/// at once inside the list/map `IndexedStack`, #35 — before this, the map
/// screen re-implemented its own raw `Geolocator` calls instead of sharing
/// this cache, firing a second redundant request every time the Apiaries
/// tab opened). [AsyncNotifier] rather than a plain future provider because
/// callers need a "try again" affordance after a denial/failure — [retry]
/// re-invokes [build] via [Ref.invalidateSelf], showing loading state in
/// between rather than jumping straight from the old error to new data.
class DeviceLocationController extends AsyncNotifier<DeviceLocation> {
  @override
  Future<DeviceLocation> build() {
    return ref.read(deviceLocationServiceProvider).current();
  }

  Future<void> retry() async {
    state = const AsyncLoading();
    ref.invalidateSelf();
    await future;
  }

  /// Silently re-acquires the device location — used by the apiary list's
  /// periodic (#422, ~every 10s) and pull-to-refresh updates so the per-row
  /// distances/ordering track the user as they move. Unlike [retry] it does
  /// NOT flip the provider back to [AsyncLoading]: the currently-shown list
  /// and distances stay on screen (rather than flashing to a full-screen
  /// spinner every tick) while the new fix is fetched, then swap in place
  /// once it resolves. [retry] keeps the loading transition for the failure
  /// banner's button, where showing progress between an error and the retried
  /// result is the wanted affordance. Guards on [Ref.mounted] so a tick
  /// racing disposal doesn't write to a torn-down notifier.
  Future<void> refresh() async {
    final next = await AsyncValue.guard(
      () => ref.read(deviceLocationServiceProvider).current(),
    );
    if (!ref.mounted) return;
    state = next;
  }
}

final deviceLocationProvider =
    AsyncNotifierProvider<DeviceLocationController, DeviceLocation>(
      DeviceLocationController.new,
    );
