/// The pieces every apiary map surface is assembled from — the tile layer's
/// shared wiring, plus the chrome painted over it: the provider attribution
/// chip, the circular control button, and the info banner (#444, D-16, D-18).
///
/// **Why this exists.** Three screens render a map — `apiary_map_screen.dart`,
/// `_LocationPicker` inside `apiary_form_screen.dart`, and
/// `apiary_location_picker_screen.dart` — and each had grown its own copy of
/// the same markup. The copies had already started to matter: the attribution
/// chip is a compliance surface (Esri/OSM both require the credit be *visible*,
/// not tap-gated), and the circular control is an accessibility surface
/// (≥[kMinTapTarget], a `Tooltip`, a `Semantics(button: true)` label — D-18).
/// A fourth copy would be a fourth place for either to silently drift.
///
/// **Why `features/apiaries/` and not `core/widgets/`.** Every consumer is an
/// apiary map surface, and this is map chrome by definition: the chip exists to
/// satisfy the tile providers' attribution terms and sits beside
/// `map_tile_sources.dart`, the other half of the same tile-provider concern.
/// `core/widgets/` holds app-wide primitives with no feature coupling
/// (`tap_target.dart`, `field_action_button.dart`), which these are not. If a
/// non-apiary map ever appears, moving this file up is a rename.
library;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../core/widgets/tap_target.dart';
import 'map_tile_sources.dart';

/// The [TileLayer] every map surface mounts, with the tile-request wiring
/// ([mapTileUserAgentPackageName]) applied once instead of per screen.
///
/// [urlTemplate] is a **required parameter rather than a satellite default** on
/// purpose: `client/test/map_tile_csp_test.dart` asserts that each screen
/// rendering a map still writes `urlTemplate:` and still imports
/// `map_tile_sources.dart`, so the set of hosts the app fetches tiles from
/// stays readable from the screens themselves and stays checkable against
/// `nginx.conf`'s CSP `connect-src` (#671). Defaulting the template here would
/// hide a tile source from that guard — the exact shape of the defect it was
/// written for.
TileLayer mapTileLayer({required Key key, required String urlTemplate}) {
  return TileLayer(
    key: key,
    urlTemplate: urlTemplate,
    userAgentPackageName: mapTileUserAgentPackageName,
  );
}

/// The translucent credit chip shown over a map for the active tile source
/// (#257, D-16, D-36).
///
/// Permanently visible, never behind a tap: Esri's terms require "Powered by
/// Esri" plus source credits for World Imagery and OSM's require
/// "© OpenStreetMap contributors", and `flutter_map`'s own
/// `RichAttributionWidget` renders its text attributions inside a collapsed,
/// tap-to-open popup (`AnimatedOpacity(opacity: 0)` under a `FadeRAWA`) — which
/// would leave a compliance requirement merely *reachable* rather than shown.
///
/// The caller owns positioning and width: the map screen shares a
/// left+right-inset [Positioned] with its measure overlay so the long Esri
/// credit wraps on-screen at phone width instead of overflowing, while the two
/// pickers corner-anchor it. That constraint therefore stays at the call site
/// rather than being baked in here.
class MapAttributionChip extends StatelessWidget {
  const MapAttributionChip({
    super.key,
    required this.text,
    required this.textKey,
  });

  /// The localized credit line for the active tile source.
  final String text;

  /// Key on the [Text] itself rather than on the chip's padded box, so a test
  /// can read the rendered credit and the rect it actually laid out into —
  /// which is what `apiary_map_screen_test.dart` asserts wraps on-screen at
  /// phone width instead of overflowing. Required, not optional: every map
  /// surface names its attribution node, and one that didn't would be
  /// unassertable.
  final Key textKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, key: textKey, style: theme.textTheme.labelSmall),
    );
  }
}

/// A small icon+message banner floating over a map — used for the
/// location-permission-denied notice on the apiary map (#252) and on the
/// full-screen picker (#421).
///
/// The caller owns positioning, and both callers inset it away from their own
/// top-right control stack so a long localized message never renders
/// underneath one; [Expanded] around the text is what lets it wrap inside
/// those insets rather than overflow.
///
/// Folded together here with the rest of the map chrome (#444): the two
/// screens had byte-identical copies, the picker's own doc comment naming the
/// map screen's as its source and "kept local since that one is file-private"
/// as the reason — which this file removes.
class MapInfoBanner extends StatelessWidget {
  const MapInfoBanner({super.key, required this.message, required this.icon});

  /// The localized notice; comes from the ARB files (NFR-I18N-1).
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

/// A circular icon control floating over a map — the shape the two location
/// pickers use for "recenter on the pin" (#420) and "maximize" (#421).
///
/// Gloves-friendly and screen-reader-legible by construction (D-18, FR-UX-1,
/// FR-AX-1): a [kMinTapTarget]-square hit area, a [Tooltip], and a
/// `Semantics(button: true)` label — all three driven off the one [tooltip]
/// string, so a caller cannot ship a labelled control with an unlabelled
/// semantics node.
///
/// `apiary_map_screen.dart` deliberately does **not** use this: its top-right
/// stack is a rounded-rect segmented control (`_MapLayerToggleSegment`) whose
/// segments share one [Material] and carry a selected state, and flattening the
/// two shapes into one widget would mean a parameter for every difference.
/// Same accessibility contract, different control.
class MapCircleControl extends StatelessWidget {
  const MapCircleControl({
    super.key,
    required this.itemKey,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  /// Key on the tappable [InkWell] — the widget a test taps and measures.
  final Key itemKey;
  final IconData icon;

  /// Doubles as the [Tooltip] message and the [Semantics] label; comes from the
  /// ARB files, never a literal (NFR-I18N-1).
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: theme.colorScheme.surfaceContainerHighest,
          elevation: 2,
          shape: const CircleBorder(),
          child: InkWell(
            key: itemKey,
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Container(
              width: kMinTapTarget,
              height: kMinTapTarget,
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: 22,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
