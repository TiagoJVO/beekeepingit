import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/sync/powersync_schema.dart';
import '../../l10n/gen/app_localizations.dart';
import '../activities/activity_filters.dart';
import '../activities/activity_list_widgets.dart';
import '../history/history_section.dart';
import '../todos/todo_quick_create_sheet.dart';
import 'apiaries_repository.dart';
import 'counter_types.dart';

/// Read-focused apiary detail (FR-AP-7, #32): name, location, hive count and
/// notes (FR-AP-8, #196), matching the Melargil prototype's "Apiário
/// detalhe" screen shape — a dedicated view screen, distinct from the edit
/// form (apiary_form_screen.dart). Reachable from the list (list screen's
/// onTap) and, once the map screen lands (parallel #33 work), from there
/// too. Renders gracefully when optional fields (location, notes) are empty
/// (#32 AC). `location` now genuinely reflects the form-set coordinates
/// (#252 wires the form's write path through — this screen's own render
/// logic was already correct, it just had nothing to show before). The
/// optional free-text place label (#252, e.g. "Montargil") renders alongside
/// the coordinates when set. Editing happens via the FAB, which pushes the
/// existing form at `/apiaries/:id/edit`.
class ApiaryDetailScreen extends ConsumerWidget {
  const ApiaryDetailScreen({required this.apiaryId, super.key});

  final String apiaryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // A narrow per-id watch (HIGH finding) rather than the whole-org
    // apiariesStreamProvider: this screen only ever renders ONE apiary, so
    // watching the entire list just to firstWhere() it meant any write to
    // any OTHER apiary/counter in the org re-triggered this screen's full
    // rebuild+rescan. apiaryByIdProvider (apiaries_repository.dart) is a
    // family-keyed StreamProvider mirroring apiaryCountersProvider's
    // existing per-id pattern -- overridable in widget tests the same way.
    final apiaryAsync = ref.watch(apiaryByIdProvider(apiaryId));
    // Read directly (not just inside the `data:` branch below) so the
    // add-todo FAB — the only one of the three that needs the apiary's own
    // NAME, not just its id (#52, FR-UX-2) — can gate its own presence on
    // the apiary actually being loaded, without touching the other two
    // FABs' existing unconditional-render behavior.
    final apiary = apiaryAsync.value;

    return Scaffold(
      body: apiaryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.apiariesError('$err')),
          ),
        ),
        data: (apiary) {
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
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Contextual quick-create-todo entry point (#52, FR-UX-2): needs
          // the apiary's own NAME (for the sheet's read-only "For {name}"
          // chip), so — unlike its two siblings below, which only need
          // [apiaryId] and render regardless of load state — this one only
          // appears once the apiary has actually loaded.
          if (apiary != null) ...[
            FloatingActionButton.extended(
              key: const Key('apiary-detail-add-todo-button'),
              heroTag: 'apiary-detail-add-todo-button',
              onPressed: () => showTodoQuickCreateSheet(
                context,
                initialApiaryId: apiary.id,
                initialApiaryName: apiary.name,
              ),
              icon: const Icon(Icons.task_alt_outlined),
              label: Text(l10n.addTodo),
            ),
            const SizedBox(height: 12),
          ],
          // Add-activity entry point (#39, FR-AC-2): the natural place to
          // log an activity is right where the apiary itself already is.
          // Only the add flow — the activities LIST is #42/#43's scope.
          FloatingActionButton.extended(
            key: const Key('apiary-detail-add-activity-button'),
            heroTag: 'apiary-detail-add-activity-button',
            onPressed: () => context.go('/apiaries/$apiaryId/activities/new'),
            icon: const Icon(Icons.event_note_outlined),
            label: Text(l10n.addActivityAction),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            key: const Key('apiary-detail-edit-button'),
            heroTag: 'apiary-detail-edit-button',
            onPressed: () => context.go('/apiaries/$apiaryId/edit'),
            icon: const Icon(Icons.edit_outlined),
            label: Text(l10n.editApiaryAction),
          ),
        ],
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
                    _CountersSection(apiary: apiary),
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
              const SizedBox(height: 14),
              _ApiaryActivitiesSection(apiaryId: apiary.id),
              const SizedBox(height: 14),
              // This apiary's change history (#60, FR-HIS-1, history.md §8):
              // the per-entity timeline lives ON the entity's detail screen,
              // capped like the activities section above and linking out to
              // the full list for the same virtualization reason.
              HistorySection(
                entityType: apiaryEntityType,
                entityId: apiary.id,
                onViewAll: () => context.go('/apiaries/${apiary.id}/history'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// This apiary's activities (#42, FR-AC-5): filterable by type and date
/// range (combinable), offline over the local synced set — embedded
/// directly on the detail page rather than a separate pushed screen, per
/// #42's own AC ("the apiary detail page lists all activities for that
/// apiary"). Shares [ActivityFilterBar]/[ActivityListView] with #43's main
/// Activities tab (DRY); `showApiary: false` there since this screen IS the
/// apiary context already. [ActivityListView.shrinkWrap]s its list — the
/// outer `SingleChildScrollView` above already owns the page's scrolling, so
/// this section can't also be an unbounded scrollable.
///
/// Because a `shrinkWrap`ped list can't lazily virtualize (it builds every
/// row up front), the embedded preview is capped at [_previewLimit]: over
/// many seasons an apiary accumulates hundreds of activities, and rebuilding
/// all of them on every filter change or sync write is wasteful. Beyond the
/// cap the section links to the full, properly-virtualized per-apiary list
/// (`/apiaries/:id/activities`, apiary_activities_screen.dart) — which still
/// satisfies #42's "lists all activities for that apiary" AC.
class _ApiaryActivitiesSection extends ConsumerWidget {
  const _ApiaryActivitiesSection({required this.apiaryId});

  /// How many activities the embedded preview renders before deferring the
  /// rest to the full per-apiary list.
  static const _previewLimit = 5;

  final String apiaryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final type = ref.watch(activityTypeFilterProvider(apiaryId));
    final dateRange = ref.watch(activityDateRangeFilterProvider(apiaryId));
    final viewModel = ref.watch(
      activitiesViewModelProvider((scope: apiaryId, apiaryId: apiaryId)),
    );

    return Container(
      key: const Key('apiary-detail-activities-section'),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Text(
              l10n.activitiesTitle,
              style: theme.textTheme.titleMedium,
            ),
          ),
          ActivityFilterBar(
            type: type,
            dateRange: dateRange,
            onTypeChanged: (v) =>
                ref.read(activityTypeFilterProvider(apiaryId).notifier).state =
                    v,
            onDateRangeChanged: (v) =>
                ref
                        .read(
                          activityDateRangeFilterProvider(apiaryId).notifier,
                        )
                        .state =
                    v,
          ),
          ActivityListView(
            viewModel: viewModel,
            emptyText: l10n.apiaryActivitiesEmpty,
            shrinkWrap: true,
            maxItems: _previewLimit,
            onViewAll: () => context.go('/apiaries/$apiaryId/activities'),
          ),
          const SizedBox(height: 8),
        ],
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
    // Location (#252): the repository's Apiary model now carries
    // locationLon/locationLat (threaded through the local schema/repository
    // the same way notes was threaded here by #196) — render the formatted
    // coordinates when set, the honest "not set" empty state otherwise. No
    // mini-map here (out of scope for this row — the full map view,
    // apiary_map_screen.dart, is reachable from the list's map toggle).
    final locationText = apiary.hasLocation
        ? l10n.apiaryLocationValue(
            apiary.locationLat!.toStringAsFixed(5),
            apiary.locationLon!.toStringAsFixed(5),
          )
        : l10n.apiaryLocationNotSet;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          key: const Key('apiary-detail-location'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_on_outlined, size: 17, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                locationText,
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
        if (apiary.placeLabel != null &&
            apiary.placeLabel!.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            key: const Key('apiary-detail-place-label'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.place_outlined, size: 17, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  apiary.placeLabel!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The apiary's typed counters (#256, FR-AP-7), rendered generically over
/// the known set (counter_types.dart):
///
///   - the HIVES counter always displays — 0 when no counter row exists —
///     sourced from [Apiary.hiveCount] (already the counters-backed value,
///     apiaries_repository.dart), so it renders synchronously with the rest
///     of the header and its text/key stay byte-identical to the pre-#256
///     badge (the e2e's "12 hives"/"No hives" assertions);
///   - every OTHER known type renders only when a counter row exists for
///     this apiary ([apiaryCountersProvider]); types this client version has
///     no label for are skipped ([counterValueLabel] returns null). Adding a
///     future countable is a constants-and-strings append — no changes here.
///
/// While the counter rows are still loading (or errored), only the hives
/// badge shows — no spinner: the extra badges are progressive enhancement,
/// and the always-on hives badge already covers the screen's primary
/// content (also keeps widget tests' pumpAndSettle safe — an indefinite
/// spinner would never settle in the PowerSync-less test environment).
class _CountersSection extends ConsumerWidget {
  const _CountersSection({required this.apiary});

  final Apiary apiary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final counters = ref.watch(apiaryCountersProvider(apiary.id));

    final others = <ApiaryCounter>[
      for (final counter in counters.value ?? const <ApiaryCounter>[])
        if (counter.counterType != counterTypeHive &&
            counterValueLabel(l10n, counter.counterType, counter.value) != null)
          counter,
    ];

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _CounterBadge(
          key: const Key('apiary-detail-hive-count'),
          label: l10n.hiveCountValue(apiary.hiveCount),
        ),
        for (final counter in others)
          _CounterBadge(
            key: Key('apiary-detail-counter-${counter.counterType}'),
            label: counterValueLabel(l10n, counter.counterType, counter.value)!,
          ),
      ],
    );
  }
}

/// One counter value pill — the visual shape of the original hive-count
/// badge, now shared by every counter type the section renders.
class _CounterBadge extends StatelessWidget {
  const _CounterBadge({required this.label, super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        label,
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
