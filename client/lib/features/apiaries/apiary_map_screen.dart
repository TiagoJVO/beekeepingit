import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../core/geo/haversine.dart';
import '../../l10n/gen/app_localizations.dart';
import 'apiaries_repository.dart';

/// Default map center/zoom when there's no better signal yet (no apiaries,
/// no user location) — mainland Portugal, since the Melargil prototype and
/// the project's dev-seed data are Portugal-based. Arbitrary but stable so
/// the map never renders at the whole-world default zoom.
const _fallbackCenter = ll.LatLng(39.5, -8.0);
const _fallbackZoom = 6.0;
const _focusedZoom = 12.0;

/// The apiary map view (#34, FR-AP-3) plus the tap-to-measure distance
/// overlay (#37, FR-AP-5, D-15). Renders a marker per apiary that has a
/// stored location (apiaries without one are silently skipped — #34 AC), a
/// distinct marker for the user's current location when available (#34 AC:
/// graceful empty/permission-denied handling), and a tap-two-pins
/// measurement flow that computes the haversine distance fully offline
/// (#37 AC) without depending on the server `/distance` endpoint (that
/// endpoint exists for contract-completeness/online-only callers —
/// services/apiaries/api/apiaries.go's getApiaryDistance — mirroring how
/// apiary CRUD writes never call the REST write API directly).
///
/// Tile source: the public OSM/MapLibre demo endpoint (D-16 — tile
/// provider/offline-tile-caching is a separate, deferred concern; this
/// screen only needs to render online without error for a reasonable
/// marker count).
///
/// Embedded as a sibling view of [ApiariesListScreen] (#35, FR-AP-4) behind
/// the list/map segmented toggle, rather than its own pushed route — both
/// stay mounted in an [IndexedStack] so the tap-to-measure selection here
/// survives switching to the list and back (#35 AC: "switching views
/// preserves relevant context").
class ApiaryMapScreen extends ConsumerStatefulWidget {
  const ApiaryMapScreen({super.key});

  @override
  ConsumerState<ApiaryMapScreen> createState() => _ApiaryMapScreenState();
}

class _ApiaryMapScreenState extends ConsumerState<ApiaryMapScreen> {
  final _mapController = MapController();

  /// The tap-to-measure selection (D-15's "tap two pins"): at most two
  /// apiary ids, in tap order. A third tap on a different apiary is treated
  /// as starting a fresh selection with that apiary (rather than being
  /// ignored) — simple, predictable, matches the Melargil prototype's
  /// single-slot-then-second-slot flow.
  final List<Apiary> _selected = [];

  ll.LatLng? _userLocation;
  bool _locationPermissionDenied = false;
  bool _locationLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUserLocation();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _loadUserLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        setState(() {
          _locationPermissionDenied = true;
          _locationLoading = false;
        });
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        setState(() {
          _locationPermissionDenied = true;
          _locationLoading = false;
        });
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      setState(() {
        _userLocation = ll.LatLng(position.latitude, position.longitude);
        _locationLoading = false;
      });
    } on Exception {
      // Any platform/plugin failure (unsupported platform, timeout, ...)
      // degrades to the same "no user marker" state rather than crashing
      // the map screen (#34 AC: graceful empty/permission-denied handling).
      if (!mounted) return;
      setState(() {
        _locationPermissionDenied = true;
        _locationLoading = false;
      });
    }
  }

  void _onApiaryTap(Apiary apiary) {
    if (_selected.length == 1 && _selected.first.id == apiary.id) {
      // Tapping the sole selected apiary again clears the selection.
      setState(_selected.clear);
      return;
    }
    setState(() {
      if (_selected.length >= 2) {
        _selected
          ..clear()
          ..add(apiary);
      } else if (_selected.length == 1) {
        _selected.add(apiary);
      } else {
        _selected.add(apiary);
      }
    });
  }

  void _clearSelection() => setState(_selected.clear);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final apiariesAsync = ref.watch(apiariesStreamProvider);

    return apiariesAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.apiariesError('$err')),
        ),
      ),
      data: (apiaries) {
        final located = apiaries.where((a) => a.hasLocation).toList();
        return Stack(
          children: [
            _Map(
              key: const Key('apiary-map'),
              controller: _mapController,
              apiaries: located,
              selected: _selected,
              userLocation: _userLocation,
              userLocationLabel: l10n.apiaryMapUserLocationLabel,
              onApiaryTap: _onApiaryTap,
              onApiaryDetail: (apiary) => context.go('/apiaries/${apiary.id}'),
            ),
            if (located.isEmpty)
              Center(
                child: Card(
                  margin: const EdgeInsets.all(24),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      l10n.apiaryMapEmpty,
                      key: const Key('apiary-map-empty'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            if (!_locationLoading && _locationPermissionDenied)
              Positioned(
                left: 12,
                right: 12,
                top: 12,
                child: _InfoBanner(
                  key: const Key('apiary-map-location-denied'),
                  message: l10n.apiaryMapLocationPermissionDenied,
                  icon: Icons.location_disabled,
                ),
              ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: _MeasureOverlay(
                key: const Key('apiary-map-measure-overlay'),
                selected: _selected,
                onClear: _clearSelection,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Map extends StatelessWidget {
  const _Map({
    super.key,
    required this.controller,
    required this.apiaries,
    required this.selected,
    required this.userLocation,
    required this.userLocationLabel,
    required this.onApiaryTap,
    required this.onApiaryDetail,
  });

  final MapController controller;
  final List<Apiary> apiaries;
  final List<Apiary> selected;
  final ll.LatLng? userLocation;
  final String userLocationLabel;
  final void Function(Apiary) onApiaryTap;
  final void Function(Apiary) onApiaryDetail;

  /// Every point the initial camera should frame: all located apiaries plus
  /// the user location when known. Fitting bounds (rather than centering on
  /// a single apiary at a fixed zoom) is what keeps every marker actually
  /// visible/tappable on open, regardless of how spread out the org's
  /// apiaries are (#34 AC: "renders without error ... across a reasonable
  /// number of markers").
  List<ll.LatLng> get _framedPoints => [
    for (final a in apiaries) ll.LatLng(a.locationLat!, a.locationLon!),
    if (userLocation != null) userLocation!,
  ];

  bool _isSelected(Apiary a) => selected.any((s) => s.id == a.id);

  @override
  Widget build(BuildContext context) {
    final points = _framedPoints;
    // Extra top/bottom padding keeps the initial fit clear of this screen's
    // own overlays — the permission-denied banner (top, when shown) and the
    // tap-to-measure card (bottom, always) — so a marker isn't first shown
    // obscured (and untappable) underneath either one.
    final initialCameraFit = points.isEmpty
        ? null
        : CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.fromLTRB(48, 96, 48, 96),
            maxZoom: _focusedZoom,
          );
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: points.isEmpty ? _fallbackCenter : points.first,
        initialZoom: _fallbackZoom,
        initialCameraFit: initialCameraFit,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.beekeepingit.client',
        ),
        MarkerLayer(
          markers: [
            for (final apiary in apiaries)
              Marker(
                key: Key('apiary-marker-${apiary.id}'),
                point: ll.LatLng(apiary.locationLat!, apiary.locationLon!),
                width: 56,
                height: 56,
                child: _ApiaryPin(
                  apiary: apiary,
                  selected: _isSelected(apiary),
                  onTap: () => onApiaryTap(apiary),
                  onLongPress: () => onApiaryDetail(apiary),
                ),
              ),
            if (userLocation != null)
              Marker(
                key: const Key('apiary-map-user-marker'),
                point: userLocation!,
                width: 44,
                height: 44,
                child: _UserPin(label: userLocationLabel),
              ),
          ],
        ),
      ],
    );
  }
}

/// A single apiary marker: shows the hive count (per D-16's "pin markers per
/// apiary (showing hive count)"), highlighted when part of the current
/// tap-to-measure selection (#37 AC: the selection must be clear/usable).
/// Tap selects/deselects for measuring; long-press opens the apiary detail
/// (a plain tap navigating away would make the two-tap measure flow
/// impossible to complete without leaving the map).
class _ApiaryPin extends StatelessWidget {
  const _ApiaryPin({
    required this.apiary,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final Apiary apiary;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = selected
        ? theme.colorScheme.secondary
        : theme.colorScheme.primary;
    return Semantics(
      button: true,
      label: '${apiary.name}, ${apiary.hiveCount}',
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(12),
                border: selected
                    ? Border.all(color: theme.colorScheme.onSurface, width: 2)
                    : null,
              ),
              child: Text(
                '${apiary.hiveCount}',
                style: TextStyle(
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            Icon(Icons.location_on, color: color, size: 26),
          ],
        ),
      ),
    );
  }
}

/// The distinct user-location marker (#34 AC — "distinct marker for the
/// user's current location"), labeled per the Melargil prototype's "Você".
class _UserPin extends StatelessWidget {
  const _UserPin({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiary,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: theme.colorScheme.onTertiary,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
          Icon(Icons.my_location, color: theme.colorScheme.tertiary, size: 24),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({super.key, required this.message, required this.icon});

  final String message;
  final IconData icon;

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
            Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}

/// The tap-to-measure result/hint card (#37, D-15). Shows the running
/// selection state hint until two apiaries are picked, then the computed
/// haversine distance in km plus a clear action to reset (#37 AC: "the
/// selection mechanism ... is clear and usable").
class _MeasureOverlay extends StatelessWidget {
  const _MeasureOverlay({super.key, required this.selected, required this.onClear});

  final List<Apiary> selected;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    String text;
    if (selected.length < 2) {
      text = selected.isEmpty
          ? l10n.apiaryMapMeasureHintSelectFirst
          : l10n.apiaryMapMeasureHintSelectSecond(selected.first.name);
    } else {
      final from = selected[0];
      final to = selected[1];
      final km = haversineDistanceKm(
        lat1: from.locationLat!,
        lon1: from.locationLon!,
        lat2: to.locationLat!,
        lon2: to.locationLon!,
      );
      text = l10n.apiaryMapMeasureResult(
        from.name,
        to.name,
        km.toStringAsFixed(2),
      );
    }

    return Material(
      key: const Key('apiary-map-measure-text'),
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(12),
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(Icons.straighten, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
            if (selected.isNotEmpty)
              TextButton(
                key: const Key('apiary-map-measure-clear'),
                onPressed: onClear,
                child: Text(l10n.apiaryMapMeasureClear),
              ),
          ],
        ),
      ),
    );
  }
}
