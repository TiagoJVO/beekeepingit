import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../core/geo/device_location.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import 'map_tile_sources.dart';

/// Default map center/zoom when the picker opens with no pin yet — same
/// mainland-Portugal default the embedded picker and apiary_map_screen.dart
/// use (the Melargil prototype and this project's dev-seed data are
/// Portugal-based).
const _fullScreenFallbackCenter = ll.LatLng(39.5, -8.0);
const _fullScreenFallbackZoom = 6.0;

/// Zoom the picker opens at when it already carries a pin — close enough to
/// nudge it precisely, the whole point of the full-screen view (#421).
const _fullScreenFocusedZoom = 15.0;

/// Street-level zoom the recenter control and "use current location" jump the
/// camera to — matches the embedded picker's own recenter zoom (#420).
const _fullScreenStreetZoom = 16.0;

/// Opens the full-screen apiary location picker (#421) and resolves to the
/// [ll.LatLng] the user confirmed, or `null` if they cancelled (or dismissed
/// via the system back gesture). Field-testing feedback: placing a pin
/// accurately on the form's small 220px embedded map is hard, especially with
/// gloves — this hands the same tap-to-place / recenter / "use current
/// location" affordances a full viewport so the pin can be sited precisely.
///
/// Pushed as a `fullscreenDialog` route on the nearest [Navigator] (the app
/// shell's) rather than a go_router destination: it's a transient
/// pick-and-return modal that hands a value straight back to the awaiting
/// form, not an addressable place in the app's navigation graph.
Future<ll.LatLng?> showApiaryLocationPickerScreen(
  BuildContext context, {
  ll.LatLng? initialLocation,
}) {
  return Navigator.of(context).push<ll.LatLng>(
    MaterialPageRoute<ll.LatLng>(
      fullscreenDialog: true,
      builder: (_) =>
          ApiaryLocationPickerScreen(initialLocation: initialLocation),
    ),
  );
}

/// The full-screen map picker (#421). Carries the form's current pin in, lets
/// the user pan/zoom and tap to place/adjust it (tap-to-place, the same
/// gesture the embedded picker and apiary_map_screen.dart already use —
/// flutter_map has no draggable-marker gesture), and pops the chosen location
/// back to the caller on confirm. Reuses the satellite tile layer +
/// attribution (#257), the recenter control (#420), and the shared
/// "use current location" device-location path so the two pickers behave
/// identically at either size.
class ApiaryLocationPickerScreen extends ConsumerStatefulWidget {
  const ApiaryLocationPickerScreen({this.initialLocation, super.key});

  final ll.LatLng? initialLocation;

  @override
  ConsumerState<ApiaryLocationPickerScreen> createState() =>
      _ApiaryLocationPickerScreenState();
}

class _ApiaryLocationPickerScreenState
    extends ConsumerState<ApiaryLocationPickerScreen> {
  final _mapController = MapController();

  /// The pin the picker will return on confirm — seeded from the form's
  /// current pin, then updated by tap-to-place / "use current location".
  ll.LatLng? _location;
  bool _locationPermissionDenied = false;

  @override
  void initState() {
    super.initState();
    _location = widget.initialLocation;
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  void _onMapTap(ll.LatLng point) {
    setState(() {
      _location = point;
      _locationPermissionDenied = false;
    });
  }

  /// "Use current location": a fresh one-shot fetch via the shared
  /// [deviceLocationServiceProvider] (never throws — see the service's own
  /// doc), collapsing every non-available variant onto the same
  /// "denied/unavailable" UI state, exactly like the embedded picker's own
  /// button (#252/#420).
  Future<void> _useCurrentLocation() async {
    final result = await ref.read(deviceLocationServiceProvider).current();
    if (!mounted) return;
    switch (result) {
      case DeviceLocationAvailable(:final lon, :final lat):
        final point = ll.LatLng(lat, lon);
        setState(() {
          _location = point;
          _locationPermissionDenied = false;
        });
        _mapController.move(point, _fullScreenStreetZoom);
      default:
        setState(() => _locationPermissionDenied = true);
    }
  }

  void _recenter() {
    final location = _location;
    if (location == null) return;
    _mapController.move(location, _fullScreenStreetZoom);
  }

  void _cancel() => Navigator.of(context).pop();

  void _confirm() {
    final location = _location;
    if (location == null) return;
    Navigator.of(context).pop(location);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final location = _location;
    return Scaffold(
      key: const Key('apiary-fullscreen-picker'),
      appBar: AppBar(
        title: Text(l10n.apiaryLocationPickerFullScreenTitle),
        leading: IconButton(
          key: const Key('apiary-fullscreen-picker-cancel'),
          icon: const Icon(Icons.close),
          tooltip: l10n.apiaryLocationPickerCancelAction,
          onPressed: _cancel,
        ),
        actions: [
          IconButton(
            key: const Key('apiary-fullscreen-picker-confirm'),
            icon: const Icon(Icons.check),
            tooltip: l10n.apiaryLocationPickerConfirmAction,
            // Disabled until a pin exists — there is nothing to return
            // otherwise. A null onPressed also drops it from the tap-target
            // path, so it can't be confirmed empty.
            onPressed: location == null ? null : _confirm,
          ),
        ],
      ),
      // The "use current location" action is anchored as a labelled FAB so it
      // stays a large, gloves-friendly target clear of the map's own gesture
      // region (D-18, FR-UX-1), well above the 44x44 floor.
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('apiary-fullscreen-picker-use-current-location'),
        icon: const Icon(Icons.my_location),
        label: Text(l10n.apiaryUseCurrentLocationAction),
        onPressed: _useCurrentLocation,
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: Semantics(
        label: l10n.apiaryLocationPickerFullScreenLabel,
        child: Stack(
          children: [
            FlutterMap(
              key: const Key('apiary-fullscreen-picker-map'),
              mapController: _mapController,
              options: MapOptions(
                initialCenter: location ?? _fullScreenFallbackCenter,
                initialZoom: location != null
                    ? _fullScreenFocusedZoom
                    : _fullScreenFallbackZoom,
                onTap: (tapPosition, point) => _onMapTap(point),
              ),
              children: [
                TileLayer(
                  key: const Key('apiary-fullscreen-picker-tile-layer'),
                  // map_tile_sources.dart, not a literal: nginx.conf's CSP
                  // `connect-src` has to name this host (#671).
                  urlTemplate: satelliteTileUrlTemplate,
                  userAgentPackageName: mapTileUserAgentPackageName,
                ),
                if (location != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        key: const Key('apiary-fullscreen-picker-pin'),
                        point: location,
                        width: 48,
                        height: 48,
                        child: Icon(
                          Icons.location_on,
                          color: theme.colorScheme.primary,
                          size: 40,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            if (_locationPermissionDenied)
              Positioned(
                left: 12,
                right: 12,
                top: 12,
                child: _PickerBanner(
                  key: const Key('apiary-fullscreen-picker-permission-denied'),
                  message: l10n.apiaryFormLocationPermissionDenied,
                ),
              ),
            // Attribution bottom-left, clear of the centered FAB and the
            // top-right recenter control (Esri's terms require the credit be
            // visible, not tap-gated — #257).
            Positioned(
              left: 12,
              bottom: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  l10n.apiaryMapAttributionEsri,
                  key: const Key('apiary-fullscreen-picker-attribution'),
                  style: theme.textTheme.labelSmall,
                ),
              ),
            ),
            // Recenter control (#420): only once a pin exists is there
            // anything to recenter on. Gloves-friendly (≥[kMinTapTarget]),
            // with a Tooltip + Semantics label (WCAG 2.2 AA).
            if (location != null)
              Positioned(
                top: 12,
                right: 12,
                child: Semantics(
                  button: true,
                  label: l10n.apiaryMapPickerRecenterAction,
                  child: Tooltip(
                    message: l10n.apiaryMapPickerRecenterAction,
                    child: Material(
                      color: theme.colorScheme.surfaceContainerHighest,
                      elevation: 2,
                      shape: const CircleBorder(),
                      child: InkWell(
                        key: const Key(
                          'apiary-fullscreen-picker-recenter-button',
                        ),
                        customBorder: const CircleBorder(),
                        onTap: _recenter,
                        child: Container(
                          width: kMinTapTarget,
                          height: kMinTapTarget,
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.my_location,
                            size: 22,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small info banner (permission-denied) over the full-screen picker map —
/// the same shape apiary_map_screen.dart's own `_InfoBanner` uses, kept local
/// since that one is file-private.
class _PickerBanner extends StatelessWidget {
  const _PickerBanner({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Icon(
              Icons.location_disabled,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
          ],
        ),
      ),
    );
  }
}
