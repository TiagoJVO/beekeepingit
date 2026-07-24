import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../core/geo/device_location.dart';
import '../../core/geo/distance.dart';
import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import 'apiaries_repository.dart';
import 'apiary_map_screen.dart';

/// The free-text search query (FR-AP-6, D-17: client-side, apiaries-only).
/// Ephemeral UI state — not persisted, reset on screen rebuild — so a plain
/// [StateProvider] is enough; no need for a full [Notifier].
final apiariesSearchQueryProvider = StateProvider<String>((ref) => '');

/// Which of the two available apiary views (FR-AP-4) is active: the
/// proximity-ordered/searchable list, or the map. A plain enum + StateProvider
/// (ephemeral, resets to [list] on cold start) rather than persisted
/// preference — #35's AC only asks that both views are reachable, the active
/// one is visibly indicated, and switching preserves context; it doesn't ask
/// for the choice to survive an app restart.
enum ApiariesView { list, map }

/// Shared between [ApiariesListScreen] (renders the toggle + swaps the body)
/// and the app shell (app_shell.dart uses it to suppress the "Add apiary" FAB
/// while the map is showing, the same way it already does for pushed routes
/// like the create/edit form).
final apiariesViewProvider = StateProvider<ApiariesView>(
  (ref) => ApiariesView.list,
);

/// The device location fetched for offline/live proximity ordering (#33) —
/// [deviceLocationProvider] (core/geo/device_location.dart). Moved out of
/// this file (CRITICAL finding) so apiary_map_screen.dart's own
/// user-location marker can share the exact same cached fetch instead of
/// independently re-triggering a second permission/location request when
/// both screens are alive at once in the list/map `IndexedStack`.

/// The list screen's derived, ready-to-render apiary state (HIGH finding):
/// [filterApiariesByQuery]/[sortApiariesByDistance]/[sortApiariesByName] are
/// O(n) (the sort does a haversine calculation per apiary) and used to run
/// directly inside [ApiariesListScreen.build] — i.e. on every keystroke,
/// every location tick, and every unrelated counter/apiary write anywhere
/// in the org (since [apiariesStreamProvider] re-emits the whole list on
/// any change). Hoisting the computation into its own [Provider] lets
/// Riverpod memoize it: it only recomputes when one of its three actual
/// inputs — the raw stream, the search query, or the device location —
/// changes, not on every rebuild of the screen for an unrelated reason
/// (e.g. toggling [apiariesViewProvider]).
class ApiariesViewModel {
  const ApiariesViewModel({
    required this.hasAnyApiaries,
    required this.ordered,
  });

  /// Whether the org has any apiary at all (unfiltered) — distinguishes the
  /// "no apiaries yet" onboarding empty state from "the search matched
  /// nothing", which both look like an empty [ordered] list on their own.
  final bool hasAnyApiaries;

  /// The query-filtered set, ordered by distance (device location
  /// available) or by name (fallback) — exactly what the list renders.
  final List<Apiary> ordered;
}

final apiariesViewModelProvider = Provider<AsyncValue<ApiariesViewModel>>((
  ref,
) {
  final apiariesAsync = ref.watch(apiariesStreamProvider);
  final query = ref.watch(apiariesSearchQueryProvider);
  final locationAsync = ref.watch(deviceLocationProvider);
  return apiariesAsync.whenData((apiaries) {
    final filtered = filterApiariesByQuery(apiaries, query);
    final deviceLocation = locationAsync.value;
    final ordered = switch (deviceLocation) {
      DeviceLocationAvailable(:final lon, :final lat) => sortApiariesByDistance(
        filtered,
        originLon: lon,
        originLat: lat,
      ),
      _ => sortApiariesByName(filtered),
    };
    return ApiariesViewModel(
      hasAnyApiaries: apiaries.isNotEmpty,
      ordered: ordered,
    );
  });
});

/// How often the apiary list silently re-acquires the device location while
/// it's the visible, foregrounded view (#422) so the per-row distances and
/// nearest-first ordering track the user as they walk the yard. Kept
/// deliberately coarse — ordering a short list doesn't need second-by-second
/// precision, and a longer interval limits GPS/battery use; the timer is also
/// fully suspended while the app is backgrounded (see
/// [_ApiariesListScreenState.didChangeAppLifecycleState]).
const Duration _locationRefreshInterval = Duration(seconds: 10);

/// The home screen: the org's apiaries, read live from local SQLite (works
/// offline). Tapping a row opens the edit form. No own AppBar/FAB: this
/// screen is the Apiaries tab's root within the app shell (FR-UX-2, #197),
/// which supplies the header (title, sync pill, account) and the contextual
/// "New apiary" FAB. Account/org actions that used to live in this screen's
/// app bar (manage members #172, logout) moved to the account screen, which
/// now owns them — see account_screen.dart.
///
/// Also owns two #33/#36 ACs on top of the plain list:
///  - a search field filtering the local set by name **or place label**
///    (FR-AP-6, D-17, extended by #252/#254 once `place_label` existed to
///    search against), case- and diacritic-insensitive;
///  - proximity ordering using the device's current location, offline via a
///    local haversine computation, falling back to a deterministic
///    (by-name) order with a visible indication when location is
///    unavailable/denied (FR-AP-2). Each located row also shows its
///    computed distance from the device, locale-formatted (#253).
///
/// Also owns the list/map toggle (#35, FR-AP-4): a segmented control next to
/// the search field switches [apiariesViewProvider] between [ApiariesView.list]
/// and [ApiariesView.map], and the body is an [IndexedStack] over both views
/// rather than a push/pop navigation — both stay mounted, so search text and
/// the map's tap-to-measure selection survive switching back and forth
/// (#35 AC: "switching views preserves relevant context"). The active view is
/// shown via the segmented control's selected segment (#35 AC: "the active
/// view is visually indicated"); the map screen no longer has its own pushed
/// route (superseding #34's original one-way "View map" navigation).
///
/// Keeps the device location fresh while the list is on screen (#422): a
/// [Timer.periodic] ([_locationRefreshInterval]) silently re-acquires it so
/// the distances/ordering track the user as they move, and a
/// [RefreshIndicator] lets them pull-to-refresh on demand. The timer is a
/// stateful resource (started in [State.initState], cancelled in
/// [State.dispose], suspended while backgrounded), so this is a
/// [ConsumerStatefulWidget] rather than the previous stateless
/// [ConsumerWidget].
class ApiariesListScreen extends ConsumerStatefulWidget {
  const ApiariesListScreen({super.key});

  @override
  ConsumerState<ApiariesListScreen> createState() => _ApiariesListScreenState();
}

class _ApiariesListScreenState extends ConsumerState<ApiariesListScreen>
    with WidgetsBindingObserver {
  Timer? _locationRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startLocationRefreshTimer();
  }

  @override
  void dispose() {
    _stopLocationRefreshTimer();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Suspend the periodic refresh while the app is backgrounded and resume it
  /// (with an immediate catch-up fetch) on return — a foreground gate so a
  /// pocketed, walked-away phone isn't polling GPS every ~10s (#422: "gate to
  /// foreground/visible to limit battery use"; AC: "the timer is cancelled
  /// when the screen is disposed/backgrounded").
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _refreshLocation();
        _startLocationRefreshTimer();
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        _stopLocationRefreshTimer();
    }
  }

  void _startLocationRefreshTimer() {
    _locationRefreshTimer?.cancel();
    _locationRefreshTimer = Timer.periodic(
      _locationRefreshInterval,
      (_) => _refreshLocation(),
    );
  }

  void _stopLocationRefreshTimer() {
    _locationRefreshTimer?.cancel();
    _locationRefreshTimer = null;
  }

  /// Re-acquire the device location without tearing down the list — see
  /// [DeviceLocationController.refresh]. Returned so [RefreshIndicator] can
  /// await it (keeping its spinner up until the new fix resolves); guards on
  /// [State.mounted] so a timer tick racing disposal is a no-op.
  Future<void> _refreshLocation() {
    if (!mounted) return Future<void>.value();
    return ref.read(deviceLocationProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The heavy filter+sort work is memoized in apiariesViewModelProvider
    // (HIGH finding) rather than recomputed here on every rebuild; this
    // screen still watches the raw location separately since the banner
    // and each row's distance subtitle need the resolved DeviceLocation
    // value directly, not just the ordered list.
    final viewModel = ref.watch(apiariesViewModelProvider);
    final query = ref.watch(apiariesSearchQueryProvider);
    final location = ref.watch(deviceLocationProvider);
    final view = ref.watch(apiariesViewProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('apiaries-search-field'),
                  decoration: InputDecoration(
                    hintText: l10n.apiariesSearchHint,
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            key: const Key('apiaries-search-clear-button'),
                            icon: const Icon(Icons.clear),
                            onPressed: () =>
                                ref
                                        .read(
                                          apiariesSearchQueryProvider.notifier,
                                        )
                                        .state =
                                    '',
                          ),
                  ),
                  onChanged: (v) =>
                      ref.read(apiariesSearchQueryProvider.notifier).state = v,
                ),
              ),
              const SizedBox(width: 8),
              _ApiariesViewToggle(
                view: view,
                onChanged: (v) =>
                    ref.read(apiariesViewProvider.notifier).state = v,
              ),
            ],
          ),
        ),
        if (view == ApiariesView.list)
          _LocationFallbackBanner(location: location),
        Expanded(
          child: IndexedStack(
            index: view == ApiariesView.list ? 0 : 1,
            children: [
              viewModel.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(l10n.apiariesError('$err')),
                  ),
                ),
                data: (vm) {
                  if (!vm.hasAnyApiaries) {
                    return EmptyState(
                      message: l10n.apiariesEmpty,
                      icon: Icons.hive_outlined,
                    );
                  }
                  if (vm.ordered.isEmpty) {
                    return EmptyState(message: l10n.apiariesSearchNoResults);
                  }

                  final deviceLocation = location.value;
                  final brand = context.brand;

                  // Pull-to-refresh re-acquires the location on demand (#422).
                  // AlwaysScrollableScrollPhysics keeps the gesture available
                  // even when the list is too short to overscroll on its own;
                  // the localized accessibility label comes from
                  // MaterialLocalizations (no bespoke string needed).
                  return RefreshIndicator(
                    key: const Key('apiaries-list-refresh-indicator'),
                    onRefresh: _refreshLocation,
                    child: ListView.separated(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(
                        BrandDimens.gutter,
                        4,
                        BrandDimens.gutter,
                        BrandDimens.scrollBottomInset,
                      ),
                      itemCount: vm.ordered.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(height: BrandDimens.gapCard),
                      itemBuilder: (context, i) {
                        final apiary = vm.ordered[i];
                        final distanceText = _distanceSubtitle(
                          context,
                          l10n,
                          apiary,
                          deviceLocation,
                        );
                        return BrandRowCard(
                          key: Key('apiary-${apiary.id}'),
                          title: apiary.name,
                          subtitle: distanceText == null
                              ? l10n.hiveCountValue(apiary.hiveCount)
                              : '${l10n.hiveCountValue(apiary.hiveCount)} · $distanceText',
                          leading: LeadingIconTile(
                            icon: Icons.hive,
                            color: brand.cresta.color,
                            tint: brand.cresta.tint,
                          ),
                          onTap: () => context.go('/apiaries/${apiary.id}'),
                        );
                      },
                    ),
                  );
                },
              ),
              const ApiaryMapScreen(),
            ],
          ),
        ),
      ],
    );
  }
}

/// Straight-line distance from the device's current location to [apiary], as
/// a row-ready localized string (FR-AP-2, #253), or null when it can't be
/// shown: [deviceLocation] isn't [DeviceLocationAvailable] (permission
/// denied/services off/unavailable — the same states the fallback banner
/// above already surfaces, so this degrades silently rather than repeating
/// that messaging per-row, #253 AC: "no placeholder noise"), or [apiary]
/// itself has no stored location ([Apiary.hasLocation]). Computed via the
/// same offline haversine primitive [sortApiariesByDistance] already uses
/// (core/geo/distance.dart, D-15's approach) — this is purely the per-row
/// DISPLAY value, ordering itself is unchanged. `LocaleFormatting.decimal`
/// (NFR-I18N-1, #253 AC) renders the km figure with the active locale's
/// grouping/decimal separators (e.g. PT's `12,3` vs EN's `12.3`).
String? _distanceSubtitle(
  BuildContext context,
  AppLocalizations l10n,
  Apiary apiary,
  DeviceLocation? deviceLocation,
) {
  if (deviceLocation is! DeviceLocationAvailable || !apiary.hasLocation) {
    return null;
  }
  final km =
      haversineDistanceMeters(
        lon1: deviceLocation.lon,
        lat1: deviceLocation.lat,
        lon2: apiary.locationLon!,
        lat2: apiary.locationLat!,
      ) /
      1000;
  final formatted = LocaleFormatting.of(context).decimal(km);
  return l10n.apiaryDistanceValue(formatted);
}

/// The list/map segmented toggle (#35, FR-AP-4). Two icon segments rather
/// than a text `SegmentedButton` — the shell's header row is tight next to
/// the search field, and icons (with semantic labels/tooltips for
/// screen-reader reachability, #35 AC) read fine at a glance for a two-way
/// list/map switch. Each segment is a full 44x44 tap target (#35 AC:
/// "large, gloves-friendly tap targets" — WCAG 2.2 AA's 24x24 minimum,
/// comfortably exceeded to match this app's other icon-button targets, e.g.
/// the shell's sync pill).
class _ApiariesViewToggle extends StatelessWidget {
  const _ApiariesViewToggle({required this.view, required this.onChanged});

  final ApiariesView view;
  final ValueChanged<ApiariesView> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: l10n.apiariesViewToggleLabel,
      child: Material(
        key: const Key('apiaries-view-toggle'),
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ToggleSegment(
              itemKey: const Key('apiaries-view-list-button'),
              icon: Icons.view_list_outlined,
              selectedIcon: Icons.view_list,
              tooltip: l10n.apiariesViewListAction,
              selected: view == ApiariesView.list,
              onTap: () => onChanged(ApiariesView.list),
            ),
            _ToggleSegment(
              itemKey: const Key('apiaries-view-map-button'),
              icon: Icons.map_outlined,
              selectedIcon: Icons.map,
              tooltip: l10n.apiariesViewMapAction,
              selected: view == ApiariesView.map,
              onTap: () => onChanged(ApiariesView.map),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToggleSegment extends StatelessWidget {
  const _ToggleSegment({
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
            padding: const EdgeInsets.symmetric(horizontal: 10),
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

/// The #33 AC "when location is unavailable or denied, the list falls back
/// to a deterministic order... with a clear indication": a dismissible-look
/// (but non-dismissible — it reflects real, possibly-changing state) banner
/// explaining why the list is name-ordered instead of distance-ordered, with
/// a retry action. Silent while location is loading or available — the
/// banner is only about the fallback case.
class _LocationFallbackBanner extends ConsumerWidget {
  const _LocationFallbackBanner({required this.location});

  final AsyncValue<DeviceLocation> location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final reason = switch (location) {
      AsyncData(value: DeviceLocationAvailable()) => null,
      AsyncData(value: DeviceLocationServicesDisabled()) =>
        l10n.apiariesLocationServicesDisabled,
      AsyncData(value: DeviceLocationPermissionDenied()) =>
        l10n.apiariesLocationPermissionDenied,
      AsyncData(value: DeviceLocationUnavailable()) =>
        l10n.apiariesLocationUnavailable,
      AsyncError() => l10n.apiariesLocationUnavailable,
      _ => null,
    };
    if (reason == null) return const SizedBox.shrink();

    return Container(
      key: const Key('apiaries-location-fallback-banner'),
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(reason, style: Theme.of(context).textTheme.bodySmall),
          ),
          TextButton(
            key: const Key('apiaries-location-retry-button'),
            style: TextButton.styleFrom(
              minimumSize: const Size(kMinTapTarget, kMinTapTarget),
            ),
            onPressed: () => ref.read(deviceLocationProvider.notifier).retry(),
            child: Text(l10n.apiariesLocationRetry),
          ),
        ],
      ),
    );
  }
}
