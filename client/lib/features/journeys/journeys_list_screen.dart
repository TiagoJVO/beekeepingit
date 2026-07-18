import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/gen/app_localizations.dart';
import '../activities/activity_types.dart';
import 'journey_status.dart';
import 'journeys_repository.dart';

/// The main Journeys tab (#45, FR-JO-4): every journey in the caller's
/// organization, offline-first over the local synced set
/// ([journeysStreamProvider]), **unfiltered** — a minimal list (name + main
/// activity type + status) just enough to reach create/edit, mirroring how
/// this codebase incrementally builds a feature (Activities shipped
/// activities_list_screen.dart's own basic view first; date-range/type
/// filtering and a dedicated detail screen are later stories, #47/#48 here).
/// Tapping a row opens the edit form directly (add_activity_screen.dart's
/// own pre-#310 precedent), same as the earliest activities/apiaries edit
/// affordances.
///
/// No own AppBar/Scaffold — like ActivitiesListScreen/ApiariesListScreen,
/// this is the Journeys tab's root content within the app shell
/// (app_router.dart wires it in place of the placeholder
/// ComingSoonScreen), which supplies the header and the "New journey" FAB
/// (app_shell.dart's `_fabConfigByTab`).
class JourneysListScreen extends ConsumerWidget {
  const JourneysListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final journeysAsync = ref.watch(journeysStreamProvider);

    return journeysAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.journeysError('$err')),
        ),
      ),
      data: (journeys) {
        if (journeys.isEmpty) {
          return Center(child: Text(l10n.journeysEmpty));
        }
        return ListView.separated(
          key: const Key('journeys-list'),
          itemCount: journeys.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final journey = journeys[i];
            final typeLabel =
                activityTypeLabel(l10n, journey.mainActivityType) ??
                journey.mainActivityType;
            final statusLabel =
                journeyStatusLabel(l10n, journey.status) ?? journey.status;
            return ListTile(
              key: Key('journey-${journey.id}'),
              title: Text(journey.name),
              subtitle: Text(typeLabel),
              trailing: _StatusBadge(
                label: statusLabel,
                closed: !journey.isOpen,
              ),
              onTap: () => context.go('/journeys/${journey.id}/edit'),
            );
          },
        );
      },
    );
  }
}

/// A small open/closed pill (D-21) next to each row — closed reads as
/// visually muted (the theme's surfaceContainerHighest/onSurfaceVariant,
/// like the activity-detail screen's own no-attributes muted panel) rather
/// than an alarming color, since "closed" is an ordinary, expected state,
/// not an error.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.closed});

  final String label;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = closed
        ? theme.colorScheme.surfaceContainerHighest
        : theme.colorScheme.primaryContainer;
    final foreground = closed
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.onPrimaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}
