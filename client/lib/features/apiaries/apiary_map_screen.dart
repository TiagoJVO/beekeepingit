import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../core/geo/device_location.dart';
import '../../core/geo/haversine.dart';
import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import 'apiaries_repository.dart';

/// Default map center/zoom when there's no better signal yet (no apiaries,
/// no user location) — mainland Portugal, since the Melargil prototype and
/// the project's dev-seed data are Portugal-based. Arbitrary but stable so
/// the map never renders at the whole-world default zoom.
const _fallbackCenter = ll.LatLng(39.5, -8.0);
const _fallbackZoom = 6.0;
const _focusedZoom = 12.0;

/// The two tile layers the map can render (#257, refines D-16). Satellite is
/// the default — field users recognize terrain/tree cover, not street
/// outlines — with a toggle down to streets (the original OSM layer) for
/// when road/place names are more useful.
enum MapLayer { satellite, streets }

/// Which [MapLayer] is currently active. A plain [StateProvider] — same
/// pattern as [apiariesViewProvider] in `apiaries_list_screen.dart` — rather
/// than a persisted preference: #257's AC only asks that the choice "survives
/// list<->map view switches within the session", not an app restart. Scoped
/// above the list/map [IndexedStack] (both views are built from the same
/// [ProviderScope]), so switching to the list and back to the map keeps
/// whatever layer was last selected, exactly like the tap-to-measure
/// selection already does.
final mapLayerProvider = StateProvider<MapLayer>((ref) => MapLayer.satellite);

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
/// Tile source: satellite imagery (Esri World Imagery) by default, streets
/// (the public OSM/MapLibre demo endpoint) as the toggled-to alternative
/// (#257, refining D-16 — the tile *provider* for production traffic and
/// offline-tile caching remain a separate, deferred concern per the
/// narrowed Q-MAP; this screen only needs to render online without error
/// for a reasonable marker count, with correct attribution for whichever
/// source is active).
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

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
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
    final mapLayer = ref.watch(mapLayerProvider);
    // CRITICAL fix: share the SAME cached device-location fetch
    // apiaries_list_screen.dart's proximity-ordering banner already uses
    // (core/geo/device_location.dart's deviceLocationProvider) instead of
    // this screen independently re-implementing raw Geolocator.* calls —
    // that duplication meant opening the Apiaries tab fired TWO redundant
    // location/permission requests, since both this screen and the list
    // screen are alive at once inside the list/map IndexedStack (#35).
    final locationAsync = ref.watch(deviceLocationProvider);
    final userLocation = switch (locationAsync) {
      AsyncData(value: DeviceLocationAvailable(:final lon, :final lat)) =>
        ll.LatLng(lat, lon),
      _ => null,
    };
    // Denied/disabled/unavailable/error all degrade to the same "no user
    // marker, show the banner" state (#34 AC: graceful permission-denied
    // handling) — collapsing the old ad hoc boolean flags onto a single
    // switch over the DeviceLocation sealed type. Still loading is neither
    // (no marker yet, but no banner either — matches the pre-fix behavior
    // of showing nothing until resolved).
    final locationDenied = switch (locationAsync) {
      AsyncData(value: DeviceLocationAvailable()) => false,
      AsyncLoading() => false,
      _ => true,
    };

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
              userLocation: userLocation,
              userLocationLabel: l10n.apiaryMapUserLocationLabel,
              layer: mapLayer,
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
            if (locationDenied)
              Positioned(
                // Right inset leaves room for the layer toggle in the
                // opposite top-right corner (below) so a long permission
                // message never renders underneath it.
                left: 12,
                right: 76,
                top: 12,
                child: _InfoBanner(
                  key: const Key('apiary-map-location-denied'),
                  message: l10n.apiaryMapLocationPermissionDenied,
                  icon: Icons.location_disabled,
                ),
              ),
            Positioned(
              top: 12,
              right: 12,
              child: _MapLayerToggle(
                layer: mapLayer,
                onChanged: (layer) =>
                    ref.read(mapLayerProvider.notifier).state = layer,
              ),
            ),
            // Attribution rides directly above the measure overlay in the
            // same bottom-anchored Positioned (a Column) rather than being
            // pinned to the screen's literal bottom-left corner the way
            // flutter_map's own attribution widgets are: the measure card
            // already occupies that corner's row (always — its hint shows
            // even with nothing selected), and its height varies with text
            // wrapping at narrow widths, so a separately-positioned
            // attribution with a fixed bottom offset either collides with it
            // or floats at the wrong height. Sharing the Positioned also
            // bounds the attribution's width (left+right insets), so the
            // long Esri credit line wraps on phones instead of overflowing
            // off-screen.
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _MapAttribution(
                    key: const Key('apiary-map-attribution'),
                    layer: mapLayer,
                  ),
                  const SizedBox(height: 6),
                  _MeasureOverlay(
                    key: const Key('apiary-map-measure-overlay'),
                    selected: _selected,
                    onClear: _clearSelection,
                  ),
                ],
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
    required this.layer,
    required this.onApiaryTap,
    required this.onApiaryDetail,
  });

  final MapController controller;
  final List<Apiary> apiaries;
  final List<Apiary> selected;
  final ll.LatLng? userLocation;
  final String userLocationLabel;
  final MapLayer layer;
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
        switch (layer) {
          MapLayer.satellite => TileLayer(
            key: const Key('apiary-map-tile-layer-satellite'),
            // Esri World Imagery — no API key required for this REST tile
            // endpoint. Note the {z}/{y}/{x} segment order: Esri's ArcGIS
            // REST tile scheme puts the row (y) before the column (x),
            // unlike the {z}/{x}/{y} order the OSM layer below uses.
            urlTemplate:
                'https://server.arcgisonline.com/ArcGIS/rest/services/'
                'World_Imagery/MapServer/tile/{z}/{y}/{x}',
            userAgentPackageName: 'com.beekeepingit.client',
          ),
          MapLayer.streets => TileLayer(
            key: const Key('apiary-map-tile-layer-streets'),
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.beekeepingit.client',
          ),
        },
        MarkerLayer(
          markers: [
            for (final apiary in apiaries)
              Marker(
                key: Key('apiary-marker-${apiary.id}'),
                point: ll.LatLng(apiary.locationLat!, apiary.locationLon!),
                // Wider/taller than the bare 56x56 pin box so the persistent
                // name label (#344) has room to render on its own chipped row
                // beneath the icon without overflowing the marker's bounds.
                width: 132,
                height: 82,
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
                // 56x56 (matching _ApiaryPin's own marker box below), not the
                // previous 44x44: that box was too tight for the badge+icon
                // column at ANY font size (a pre-existing overflow —
                // Column overflowed by 20+ pixels — that no prior test
                // caught, since none previously rendered this marker with an
                // actually-available location; surfaced by this PR's new
                // theme-token coverage).
                width: 56,
                height: 56,
                child: _UserPin(label: userLocationLabel),
              ),
          ],
        ),
      ],
    );
  }
}

/// A single apiary marker: shows the apiary **name** on a chipped label plus
/// the hive count (per D-16's "pin markers per apiary (showing hive count)"),
/// highlighted when part of the current tap-to-measure selection (#37 AC: the
/// selection must be clear/usable). The name (#344, FR-AP-3) is drawn
/// persistently — not merely tap-to-reveal — on an opaque surface chip so it
/// stays legible over both the satellite (default) and streets tile layers
/// (D-16); it was previously present only in the [Semantics] label, so
/// on-map apiaries could not be told apart. Tap selects/deselects for
/// measuring; long-press opens the apiary detail (a plain tap navigating away
/// would make the two-tap measure flow impossible to complete without leaving
/// the map).
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
      // The name and count are already spoken via this explicit label; drop
      // the (now visible) child Text nodes from the semantics tree so a
      // screen reader announces the marker once, not the label plus each
      // rendered string.
      excludeSemantics: true,
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
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onPrimary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Icon(Icons.location_on, color: color, size: 26),
            // Persistent name chip. Opaque surface fill (not a translucent
            // wash) so the text keeps its contrast over satellite imagery;
            // a matching outline in the selection color ties it to the pin
            // when this apiary is part of the measure selection.
            Container(
              key: Key('apiary-marker-name-${apiary.id}'),
              constraints: const BoxConstraints(maxWidth: 124),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: color, width: selected ? 2 : 1),
              ),
              child: Text(
                apiary.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
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
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onTertiary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Icon(Icons.my_location, color: theme.colorScheme.tertiary, size: 24),
        ],
      ),
    );
  }
}

/// The satellite/streets layer toggle (#257, FR-AP-3, refining D-16). Same
/// gloves-friendly segmented-control shape as
/// `apiaries_list_screen.dart`'s `_ApiariesViewToggle`/`_ToggleSegment`
/// (≥[kMinTapTarget] per segment, `Semantics` labels, `Tooltip`s, visible
/// Material focus/hover) — reused here rather than re-derived so the map's
/// own in-screen control matches the app's one established toggle pattern.
/// Positioned top-right by the caller, clear of the measure overlay (bottom)
/// and the location-denied banner (top-left, inset to leave room for this).
class _MapLayerToggle extends StatelessWidget {
  const _MapLayerToggle({required this.layer, required this.onChanged});

  final MapLayer layer;
  final ValueChanged<MapLayer> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: l10n.apiaryMapLayerToggleLabel,
      child: Material(
        key: const Key('apiary-map-layer-toggle'),
        color: theme.colorScheme.surfaceContainerHighest,
        elevation: 2,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _MapLayerToggleSegment(
              itemKey: const Key('apiary-map-layer-satellite-button'),
              icon: Icons.satellite_alt_outlined,
              selectedIcon: Icons.satellite_alt,
              tooltip: l10n.apiaryMapLayerSatelliteAction,
              selected: layer == MapLayer.satellite,
              onTap: () => onChanged(MapLayer.satellite),
            ),
            _MapLayerToggleSegment(
              itemKey: const Key('apiary-map-layer-streets-button'),
              icon: Icons.map_outlined,
              selectedIcon: Icons.map,
              tooltip: l10n.apiaryMapLayerStreetsAction,
              selected: layer == MapLayer.streets,
              onTap: () => onChanged(MapLayer.streets),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapLayerToggleSegment extends StatelessWidget {
  const _MapLayerToggleSegment({
    required this.itemKey,
    required this.icon,
    required this.selectedIcon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
  });

  final Key itemKey;
  final IconData icon;
  final IconData selectedIcon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          key: itemKey,
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(
              minWidth: kMinTapTarget,
              minHeight: kMinTapTarget,
            ),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? theme.colorScheme.primary : null,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              selected ? selectedIcon : icon,
              size: 22,
              color: selected
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// Attribution for the active tile source (#257 AC: "Proper attribution
/// overlay for the active tile source"). Esri's terms require "Powered by
/// Esri" plus source credits for World Imagery; OSM's require
/// "© OpenStreetMap contributors" — both are on permanently, not gated
/// behind a tap, since a hidden-until-tapped credit does not satisfy either
/// provider's "must be displayed" requirement. This is a small bespoke
/// overlay (matching this screen's existing hand-rolled `_InfoBanner`/
/// `_MeasureOverlay` pattern) rather than flutter_map's own
/// `RichAttributionWidget`: that widget's text attributions render inside a
/// collapsed, tap-to-open popup by default (`AnimatedOpacity(opacity: 0)`
/// under a `FadeRAWA`), which would leave attribution invisible until the
/// user finds and taps an info icon — the wrong default for a compliance
/// requirement that must be visible, not merely reachable.
class _MapAttribution extends StatelessWidget {
  const _MapAttribution({super.key, required this.layer});

  final MapLayer layer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final text = switch (layer) {
      MapLayer.satellite => l10n.apiaryMapAttributionEsri,
      MapLayer.streets => l10n.apiaryMapAttributionOsm,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        key: const Key('apiary-map-attribution-text'),
        style: theme.textTheme.labelSmall,
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
            Expanded(child: Text(message, style: theme.textTheme.bodySmall)),
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
  const _MeasureOverlay({
    super.key,
    required this.selected,
    required this.onClear,
  });

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
        // Locale-aware formatting (MEDIUM finding — was locale-unaware
        // km.toStringAsFixed(2)), matching apiaries_list_screen.dart's own
        // per-row distance display (LocaleFormatting.decimal, NFR-I18N-1):
        // PT renders `47,60` (comma decimal separator) vs EN's `47.60`.
        LocaleFormatting.of(context).decimal(km, decimalDigits: 2),
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
                style: TextButton.styleFrom(
                  minimumSize: const Size(kMinTapTarget, kMinTapTarget),
                ),
                onPressed: onClear,
                child: Text(l10n.apiaryMapMeasureClear),
              ),
          ],
        ),
      ),
    );
  }
}
