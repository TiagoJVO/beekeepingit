import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/gen/app_localizations.dart';
import 'apiaries_repository.dart';

/// The home screen: the org's apiaries, read live from local SQLite (works
/// offline). Tapping a row opens the edit form. No own AppBar/FAB: this
/// screen is the Apiaries tab's root within the app shell (FR-UX-2, #197),
/// which supplies the header (title, sync pill, account) and the contextual
/// "New apiary" FAB. Account/org actions that used to live in this screen's
/// app bar (manage members #172, logout) moved to the account screen, which
/// now owns them — see account_screen.dart.
///
/// The "View map" entry point below opens the map screen (#34, FR-AP-3).
/// This is a minimal list-level affordance, not a real list/map toggle — the
/// full toggle UX (persisted view preference, map as an alternate root view)
/// is #35's scope, a later wave; this only needs the map screen to exist and
/// be reachable per #34's AC.
class ApiariesListScreen extends ConsumerWidget {
  const ApiariesListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final apiaries = ref.watch(apiariesStreamProvider);

    return apiaries.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.apiariesError('$err')),
        ),
      ),
      data: (list) {
        return Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 8, right: 12),
                child: IconButton(
                  key: const Key('apiaries-view-map-button'),
                  icon: const Icon(Icons.map_outlined),
                  tooltip: l10n.apiaryMapTitle,
                  onPressed: () => context.go('/apiaries/map'),
                ),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? Center(child: Text(l10n.apiariesEmpty))
                  : ListView.separated(
                      itemCount: list.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final apiary = list[i];
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
                    ),
            ),
          ],
        );
      },
    );
  }
}
