import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/gen/app_localizations.dart';
import '../activities/activity_types.dart';
import 'journey_filters.dart';
import 'journey_list_widgets.dart';
import 'journey_status.dart';

/// The main Journeys tab (#45/#47, FR-JO-4/FR-JO-2): every journey in the
/// caller's organization, offline-first over the local synced set
/// ([journeysViewModelProvider]), filterable by date range and activity
/// type (combinable, #47 AC) with a plan-vs-done progress badge per row
/// ([JourneyProgress] — see journey_filters.dart's own doc for what it
/// deliberately does and doesn't count). Tapping a row opens the #48 journey
/// detail screen (journey_detail_screen.dart) — apiaries visited, per-apiary
/// activities, and the #49 stats section — from which edit/close/delete
/// remain reachable via that screen's own edit FAB.
///
/// **Date-range filter interpretation (#47 AC: "filterable by date range"):**
/// a [Journey] itself carries no date field (just name/main_activity_type/
/// status, per its own doc comment) — the filter instead matches against the
/// `occurred_at` of the journey's own recorded activities (any [Activity]
/// whose [Activity.journeyId] points at this journey), via
/// journey_filters.dart's `filterJourneysByDateRange`. A journey with no
/// activities logged yet has nothing to match and is excluded whenever a
/// date filter is active. This is a scope-interpretation call (the AC is
/// silent on exactly what a journey's "date" means), documented here and in
/// the PR description rather than blocking on it.
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
    final type = ref.watch(journeyTypeFilterProvider);
    final dateRange = ref.watch(journeyDateRangeFilterProvider);
    final viewModelAsync = ref.watch(journeysViewModelProvider);

    return Column(
      children: [
        JourneyFilterBar(
          type: type,
          dateRange: dateRange,
          onTypeChanged: (v) =>
              ref.read(journeyTypeFilterProvider.notifier).state = v,
          onDateRangeChanged: (v) =>
              ref.read(journeyDateRangeFilterProvider.notifier).state = v,
        ),
        Expanded(
          child: viewModelAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(l10n.journeysError('$err')),
              ),
            ),
            data: (vm) {
              if (!vm.hasAnyJourneys) {
                return Center(child: Text(l10n.journeysEmpty));
              }
              // The current filters matched nothing (#47 AC: "an empty
              // result set shows a clear empty state") — distinct from the
              // "no journeys at all yet" state above, mirroring
              // activities_list_screen.dart's own two-empty-states split.
              if (vm.filtered.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(l10n.journeysFilterNoResults),
                  ),
                );
              }
              return ListView.separated(
                key: const Key('journeys-list'),
                itemCount: vm.filtered.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final journey = vm.filtered[i];
                  final typeLabel =
                      activityTypeLabel(l10n, journey.mainActivityType) ??
                      journey.mainActivityType;
                  final statusLabel =
                      journeyStatusLabel(l10n, journey.status) ??
                      journey.status;
                  final progress = vm.progressByJourney[journey.id];
                  return ListTile(
                    key: Key('journey-${journey.id}'),
                    title: Text(journey.name),
                    subtitle: Row(
                      children: [
                        Flexible(
                          child: Text(
                            typeLabel,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Only shown once the journey has at least one
                        // planned apiary — a "0/0" badge on a journey
                        // that hasn't been planned yet would read as a
                        // meaningless status rather than useful progress.
                        if (progress != null && progress.planned > 0) ...[
                          const SizedBox(width: 8),
                          _ProgressBadge(progress: progress),
                        ],
                      ],
                    ),
                    trailing: _StatusBadge(
                      label: statusLabel,
                      closed: !journey.isOpen,
                    ),
                    onTap: () => context.go('/journeys/${journey.id}'),
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

/// The plan-vs-done progress badge (#47, FR-JO-2: "feitos/planeados") shown
/// next to a journey's type label once it has at least one planned apiary
/// (this file's own build() only renders it in that case) — a deliberately
/// minimal count (journey_filters.dart's own module doc: the full harvested/
/// honey/média aggregation is #49's separate scope), styled as a muted pill
/// like [_StatusBadge] but visually distinct (no color-coding: progress
/// isn't a state to alarm/reassure about, just a count) so the two badges
/// read as different kinds of information at a glance.
class _ProgressBadge extends StatelessWidget {
  const _ProgressBadge({required this.progress});

  final JourneyProgress progress;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Container(
      key: const Key('journey-progress-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        l10n.journeyProgressBadge(progress.done, progress.planned),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
