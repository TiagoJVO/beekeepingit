import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/gen/app_localizations.dart';
import 'apiaries_repository.dart';

/// Read-focused apiary detail (FR-AP-7, #32): name, location, hive count and
/// notes (FR-AP-8, #196), matching the Melargil prototype's "Apiário
/// detalhe" screen shape — a dedicated view screen, distinct from the edit
/// form (apiary_form_screen.dart). Reachable from the list (list screen's
/// onTap) and, once the map screen lands (parallel #33 work), from there
/// too. Renders gracefully when optional fields (location, notes) are empty
/// (#32 AC). Editing happens via the FAB, which pushes the existing form at
/// `/apiaries/:id/edit`.
class ApiaryDetailScreen extends ConsumerWidget {
  const ApiaryDetailScreen({required this.apiaryId, super.key});

  final String apiaryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // Reuses the same apiariesStreamProvider the list screen watches (rather
    // than a new by-id query) so widget tests can drive this screen the same
    // way widget_test.dart already overrides the list (a fixed in-memory
    // Stream<List<Apiary>>, no real PowerSync/DB needed) — and so the detail
    // screen updates live if the list does.
    final apiariesAsync = ref.watch(apiariesStreamProvider);

    return Scaffold(
      body: apiariesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.apiariesError('$err')),
          ),
        ),
        data: (apiaries) {
          final apiary = apiaries.cast<Apiary?>().firstWhere(
            (a) => a!.id == apiaryId,
            orElse: () => null,
          );
          if (apiary == null) {
            // Deleted/not found (e.g. a stale deep link) — nothing sensible
            // to render; bounce back to the list rather than show a blank
            // detail page.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/apiaries');
            });
            return const SizedBox.shrink();
          }
          return _ApiaryDetailBody(apiary: apiary);
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('apiary-detail-edit-button'),
        onPressed: () => context.go('/apiaries/$apiaryId/edit'),
        icon: const Icon(Icons.edit_outlined),
        label: Text(l10n.editApiaryAction),
      ),
    );
  }
}

class _ApiaryDetailBody extends StatelessWidget {
  const _ApiaryDetailBody({required this.apiary});

  final Apiary apiary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                key: const Key('apiary-detail-header'),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      apiary.name,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _LocationRow(apiary: apiary),
                    const SizedBox(height: 16),
                    _HiveCountBadge(apiary: apiary),
                  ],
                ),
              ),
              if (apiary.notes != null && apiary.notes!.trim().isNotEmpty) ...[
                const SizedBox(height: 14),
                Container(
                  key: const Key('apiary-detail-notes'),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.sticky_note_2_outlined,
                        size: 20,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Semantics(
                          label: l10n.apiaryNotesLabel,
                          child: Text(
                            apiary.notes!,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.apiary});

  final Apiary apiary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final color = theme.colorScheme.onPrimaryContainer;
    // The repository's Apiary model doesn't carry location yet — this slice
    // (#32) renders "no location set" until a future slice threads location
    // through the local schema/repository the way notes was threaded here
    // (#196). Kept as an explicit, honest empty state rather than a mini-map
    // (out of scope for this issue, per the map screen's own build).
    return Row(
      key: const Key('apiary-detail-location'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.location_on_outlined, size: 17, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            l10n.apiaryLocationNotSet,
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

class _HiveCountBadge extends StatelessWidget {
  const _HiveCountBadge({required this.apiary});

  final Apiary apiary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      key: const Key('apiary-detail-hive-count'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        l10n.hiveCountValue(apiary.hiveCount),
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
