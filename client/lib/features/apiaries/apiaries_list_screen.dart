import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:go_router/go_router.dart';

import '../../core/geo/device_location.dart';
import '../../l10n/gen/app_localizations.dart';
import 'apiaries_repository.dart';

/// The free-text search query (FR-AP-6, D-17: client-side, apiaries-only).
/// Ephemeral UI state — not persisted, reset on screen rebuild — so a plain
/// [StateProvider] is enough; no need for a full [Notifier].
final apiariesSearchQueryProvider = StateProvider<String>((ref) => '');

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
/// The "View map" entry point (search row's trailing icon button) opens the
/// map screen (#34, FR-AP-3). This is a minimal list-level affordance, not a
/// real list/map toggle — the full toggle UX (persisted view preference, map
/// as an alternate root view) is #35's scope, a later wave; this only needs
/// the map screen to exist and be reachable per #34's AC.
class ApiariesListScreen extends ConsumerWidget {
  const ApiariesListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final apiaries = ref.watch(apiariesStreamProvider);
    final query = ref.watch(apiariesSearchQueryProvider);
    final location = ref.watch(apiariesLocationProvider);

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
                      ref.read(apiariesSearchQueryProvider.notifier).state =
                          v,
                ),
              ),
              IconButton(
                key: const Key('apiaries-view-map-button'),
                icon: const Icon(Icons.map_outlined),
                tooltip: l10n.apiaryMapTitle,
                onPressed: () => context.go('/apiaries/map'),
              ),
            ],
          ),
        ),
        _LocationFallbackBanner(location: location),
        Expanded(
          child: apiaries.when(
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
        ),
      ],
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
            onPressed: () =>
                ref.read(apiariesLocationProvider.notifier).retry(),
            child: Text(l10n.apiariesLocationRetry),
          ),
        ],
      ),
    );
  }
}
