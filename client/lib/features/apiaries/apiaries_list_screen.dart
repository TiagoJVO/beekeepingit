import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../core/geo/device_location.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
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

/// The device location fetched for offline/live proximity ordering (#33).
/// [AsyncNotifier] rather than a plain future provider because the screen
/// needs a "try again" affordance after a denial/failure — [retry]
/// re-invokes [build] via [Ref.invalidateSelf], showing loading state in
/// between rather than jumping straight from the old error to new data.
class ApiariesLocationController extends AsyncNotifier<DeviceLocation> {
  @override
  Future<DeviceLocation> build() {
    return ref.read(deviceLocationServiceProvider).current();
  }

  Future<void> retry() async {
    state = const AsyncLoading();
    ref.invalidateSelf();
    await future;
  }
}

final apiariesLocationProvider =
    AsyncNotifierProvider<ApiariesLocationController, DeviceLocation>(
      ApiariesLocationController.new,
    );

/// The home screen: the org's apiaries, read live from local SQLite (works
/// offline). Tapping a row opens the edit form. No own AppBar/FAB: this
/// screen is the Apiaries tab's root within the app shell (FR-UX-2, #197),
/// which supplies the header (title, sync pill, account) and the contextual
/// "New apiary" FAB. Account/org actions that used to live in this screen's
/// app bar (manage members #172, logout) moved to the account screen, which
/// now owns them — see account_screen.dart.
///
/// Also owns two #33/#36 ACs on top of the plain list:
///  - a search field filtering the local set by name (FR-AP-6, D-17);
///  - proximity ordering using the device's current location, offline via a
///    local haversine computation, falling back to a deterministic
///    (by-name) order with a visible indication when location is
///    unavailable/denied (FR-AP-2).
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
class ApiariesListScreen extends ConsumerWidget {
  const ApiariesListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final apiaries = ref.watch(apiariesStreamProvider);
    final query = ref.watch(apiariesSearchQueryProvider);
    final location = ref.watch(apiariesLocationProvider);
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
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
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
              apiaries.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (err, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(l10n.apiariesError('$err')),
                  ),
                ),
                data: (list) {
                  final filtered = filterApiariesByQuery(list, query);

                  if (list.isEmpty) {
                    return Center(child: Text(l10n.apiariesEmpty));
                  }
                  if (filtered.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(l10n.apiariesSearchNoResults),
                      ),
                    );
                  }

                  final ordered = switch (location.value) {
                    DeviceLocationAvailable(:final lon, :final lat) =>
                      sortApiariesByDistance(
                        filtered,
                        originLon: lon,
                        originLat: lat,
                      ),
                    _ => sortApiariesByName(filtered),
                  };

                  return ListView.separated(
                    itemCount: ordered.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final apiary = ordered[i];
                      return ListTile(
                        key: Key('apiary-${apiary.id}'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        title: Text(apiary.name),
                        subtitle: Text(l10n.hiveCountValue(apiary.hiveCount)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.go('/apiaries/${apiary.id}'),
                      );
                    },
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
            onPressed: () =>
                ref.read(apiariesLocationProvider.notifier).retry(),
            child: Text(l10n.apiariesLocationRetry),
          ),
        ],
      ),
    );
  }
}
