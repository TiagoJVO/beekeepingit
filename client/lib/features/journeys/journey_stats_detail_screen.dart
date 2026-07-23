import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../activities/activities_repository.dart';
import '../activities/activity_types.dart';
import '../apiaries/apiaries_repository.dart';
import 'journey_stats.dart';
import 'journeys_repository.dart';

/// The "More stats" per-apiary breakdown screen (#391): every apiary
/// involved in the journey (planned and/or visited), filterable by
/// visited/not-visited, sortable by name plus whichever numeric metric the
/// journey's [Journey.mainActivityType] actually carries, with a header
/// summary row for the feeding/treatment types. Reached from the #49 stats
/// section's "More stats" button (journey_stats_section.dart), nested under
/// the journey detail route (`/journeys/:id/stats`, app_router.dart) exactly
/// like the existing `edit` route.
///
/// Fully offline, same as #48's journey detail page: every provider this
/// screen reads is a live watch over the local PowerSync-synced SQLite store
/// (`journeyByIdProvider`, `activitiesByJourneyProvider`,
/// `journeyPlanApiariesByJourneyProvider`, `apiariesStreamProvider`) — no
/// network call is ever made to render it. The actual per-apiary arithmetic
/// is [computePerApiaryJourneyStats] (journey_stats.dart) — this screen only
/// composes the already-live providers into that pure function's plain
/// inputs, then filters/sorts/renders the result. Filter and sort are local
/// UI-only state (never shared with another screen, unlike
/// activity_filters.dart's provider-backed filters), so a plain
/// [ConsumerStatefulWidget] is enough.
class JourneyStatsDetailScreen extends ConsumerStatefulWidget {
  const JourneyStatsDetailScreen({required this.journeyId, super.key});

  final String journeyId;

  @override
  ConsumerState<JourneyStatsDetailScreen> createState() =>
      _JourneyStatsDetailScreenState();
}

class _JourneyStatsDetailScreenState
    extends ConsumerState<JourneyStatsDetailScreen> {
  _VisitFilter _filter = _VisitFilter.all;
  _SortOption _sort = _SortOption.name;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final journeyAsync = ref.watch(journeyByIdProvider(widget.journeyId));

    return journeyAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.journeysError('$err')),
        ),
      ),
      data: (journey) {
        if (journey == null) {
          // Deleted/not found (e.g. a stale deep link) — same bounce-back
          // handling as journey_detail_screen.dart's own null case.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) context.go('/journeys');
          });
          return const SizedBox.shrink();
        }
        return _JourneyStatsDetailBody(
          journey: journey,
          filter: _filter,
          sort: _sort,
          onFilterChanged: (f) => setState(() => _filter = f),
          onSortChanged: (s) => setState(() => _sort = s),
        );
      },
    );
  }
}

/// The visited/not-visited filter (#391 AC: "filtering ... between visited
/// and not-visited apiaries") — [all] is the default, showing every apiary
/// in the journey's scope (planned and/or visited).
enum _VisitFilter { all, visited, notVisited }

/// The available sort criteria. [name] is always offered; the rest only
/// appear when the journey's main activity type actually carries that metric
/// (see [_sortOptionsFor]) — mirrors the #49 stats section's own
/// harvest-only tile gating (journey_stats_section.dart).
enum _SortOption { name, kgPerHive, supersPerHive, feedAmount, hivesInvolved }

List<_SortOption> _sortOptionsFor(String mainActivityType) {
  return switch (mainActivityType) {
    activityTypeHarvest => const [
      _SortOption.name,
      _SortOption.kgPerHive,
      _SortOption.supersPerHive,
    ],
    activityTypeFeeding => const [_SortOption.name, _SortOption.feedAmount],
    activityTypeTreatment => const [
      _SortOption.name,
      _SortOption.hivesInvolved,
    ],
    _ => const [_SortOption.name],
  };
}

String _sortOptionLabel(AppLocalizations l10n, _SortOption option) =>
    switch (option) {
      _SortOption.name => l10n.journeyStatsDetailSortName,
      _SortOption.kgPerHive => l10n.journeyStatsDetailSortKgPerHive,
      _SortOption.supersPerHive => l10n.journeyStatsDetailSortSupersPerHive,
      _SortOption.feedAmount => l10n.journeyStatsDetailSortFeedAmount,
      _SortOption.hivesInvolved => l10n.journeyStatsDetailSortHivesInvolved,
    };

class _JourneyStatsDetailBody extends ConsumerWidget {
  const _JourneyStatsDetailBody({
    required this.journey,
    required this.filter,
    required this.sort,
    required this.onFilterChanged,
    required this.onSortChanged,
  });

  final Journey journey;
  final _VisitFilter filter;
  final _SortOption sort;
  final ValueChanged<_VisitFilter> onFilterChanged;
  final ValueChanged<_SortOption> onSortChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    final plannedApiaryIds =
        ref.watch(journeyPlanApiariesByJourneyProvider).value?[journey.id] ??
        const <String>[];
    final apiaries =
        ref.watch(apiariesStreamProvider).value ?? const <Apiary>[];
    final apiaryNames = <String, String>{
      for (final a in apiaries) a.id: a.name,
    };
    final hiveCounts = <String, int>{
      for (final a in apiaries) a.id: a.hiveCount,
    };
    final activitiesAsync = ref.watch(activitiesByJourneyProvider(journey.id));

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: activitiesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.journeysError('$err')),
            ),
          ),
          data: (activities) {
            final records = [
              for (final a in activities)
                JourneyActivityRecord(
                  apiaryId: a.apiaryId,
                  type: a.type,
                  attributes: a.attributes,
                ),
            ];
            final allStats = computePerApiaryJourneyStats(
              plannedApiaryIds: plannedApiaryIds,
              activities: records,
              hiveCounts: hiveCounts,
            );
            final visible = _sortedStats(
              _filteredStats(allStats, filter),
              sort,
              apiaryNames,
              l10n,
            );

            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 96),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _FilterBar(filter: filter, onChanged: onFilterChanged),
                  const SizedBox(height: 12),
                  _SortBar(
                    mainActivityType: journey.mainActivityType,
                    sort: sort,
                    onChanged: onSortChanged,
                  ),
                  const SizedBox(height: 12),
                  _SummaryRow(
                    mainActivityType: journey.mainActivityType,
                    stats: allStats,
                  ),
                  const SizedBox(height: 12),
                  if (visible.isEmpty)
                    EmptyState(
                      key: const Key('journey-stats-detail-empty'),
                      message: l10n.journeyStatsDetailEmpty,
                    )
                  else
                    for (final s in visible) ...[
                      _ApiaryStatsCard(
                        stats: s,
                        apiaryName:
                            apiaryNames[s.apiaryId] ??
                            l10n.journeyDetailApiaryNameUnknown,
                        mainActivityType: journey.mainActivityType,
                      ),
                      const SizedBox(height: 10),
                    ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

List<ApiaryJourneyStats> _filteredStats(
  List<ApiaryJourneyStats> stats,
  _VisitFilter filter,
) {
  return switch (filter) {
    _VisitFilter.all => stats,
    _VisitFilter.visited => stats.where((s) => s.isVisited).toList(),
    _VisitFilter.notVisited => stats.where((s) => !s.isVisited).toList(),
  };
}

List<ApiaryJourneyStats> _sortedStats(
  List<ApiaryJourneyStats> stats,
  _SortOption sort,
  Map<String, String> apiaryNames,
  AppLocalizations l10n,
) {
  final sorted = [...stats];
  String nameOf(ApiaryJourneyStats s) =>
      apiaryNames[s.apiaryId] ?? l10n.journeyDetailApiaryNameUnknown;
  switch (sort) {
    case _SortOption.name:
      sorted.sort((a, b) => nameOf(a).compareTo(nameOf(b)));
    case _SortOption.kgPerHive:
      sorted.sort((a, b) => _compareNullsLastDesc(a.kgPerHive, b.kgPerHive));
    case _SortOption.supersPerHive:
      sorted.sort(
        (a, b) => _compareNullsLastDesc(a.supersPerHive, b.supersPerHive),
      );
    case _SortOption.feedAmount:
      sorted.sort(
        (a, b) => b.feedingAmountTotal.compareTo(a.feedingAmountTotal),
      );
    case _SortOption.hivesInvolved:
      sorted.sort(
        (a, b) => b.treatmentHivesInvolved.compareTo(a.treatmentHivesInvolved),
      );
  }
  return sorted;
}

/// Descending numeric compare with nulls sorted last (#391's sort spec:
/// "desc, nulls last") — mirrors apiaries_repository.dart's
/// `sortApiariesByDistance` own NULLS-LAST convention for a missing value.
int _compareNullsLastDesc(double? a, double? b) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return b.compareTo(a);
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.filter, required this.onChanged});

  final _VisitFilter filter;
  final ValueChanged<_VisitFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // [ButtonSegment] itself has no `key` parameter (it's a plain value
    // descriptor, not a widget) — each segment's key is carried by a
    // [KeyedSubtree] wrapping its label instead, so `find.byKey(...)` still
    // locates (and `tester.tap` still hits) the right segment.
    return SegmentedButton<_VisitFilter>(
      key: const Key('journey-stats-filter-bar'),
      segments: [
        ButtonSegment(
          value: _VisitFilter.all,
          label: KeyedSubtree(
            key: const Key('journey-stats-filter-all'),
            child: Text(l10n.journeyStatsDetailFilterAll),
          ),
        ),
        ButtonSegment(
          value: _VisitFilter.visited,
          label: KeyedSubtree(
            key: const Key('journey-stats-filter-visited'),
            child: Text(l10n.journeyStatsDetailFilterVisited),
          ),
        ),
        ButtonSegment(
          value: _VisitFilter.notVisited,
          label: KeyedSubtree(
            key: const Key('journey-stats-filter-not-visited'),
            child: Text(l10n.journeyStatsDetailFilterNotVisited),
          ),
        ),
      ],
      selected: {filter},
      onSelectionChanged: (selection) => onChanged(selection.first),
    );
  }
}

class _SortBar extends StatelessWidget {
  const _SortBar({
    required this.mainActivityType,
    required this.sort,
    required this.onChanged,
  });

  final String mainActivityType;
  final _SortOption sort;
  final ValueChanged<_SortOption> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final options = _sortOptionsFor(mainActivityType);
    return DropdownButtonFormField<_SortOption>(
      key: const Key('journey-stats-sort-field'),
      initialValue: options.contains(sort) ? sort : _SortOption.name,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: l10n.journeyStatsDetailSortLabel,
        isDense: true,
      ),
      items: [
        for (final option in options)
          DropdownMenuItem(
            value: option,
            child: Text(_sortOptionLabel(l10n, option)),
          ),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }
}

/// Header totals for the journey's own activity type (#391: "a header
/// summary row for per-type totals"): feeding shows Σ feed_amount across
/// every apiary; treatment shows how many apiaries were treated. Harvest's
/// own totals already have their own home (the #49 stats section's
/// honey-collected/hives-harvested/average-supers tiles), so this row stays
/// empty for a harvest (and generic) journey rather than duplicating them.
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.mainActivityType, required this.stats});

  final String mainActivityType;
  final List<ApiaryJourneyStats> stats;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = LocaleFormatting.of(context);
    final theme = Theme.of(context);

    Widget? content;
    if (mainActivityType == activityTypeFeeding) {
      num total = 0;
      for (final s in stats) {
        total += s.feedingAmountTotal;
      }
      content = Text(
        l10n.journeyStatsDetailFeedingSummary(locale.decimal(total)),
        key: const Key('journey-stats-detail-feeding-summary'),
      );
    } else if (mainActivityType == activityTypeTreatment) {
      final treated = stats.where((s) => s.treated).length;
      final planned = stats.where((s) => s.isPlanned).length;
      content = Text(
        l10n.journeyStatsDetailTreatedSummary(treated, planned),
        key: const Key('journey-stats-detail-treated-summary'),
      );
    }
    if (content == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(BrandDimens.padCard),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BrandDimens.borderField,
      ),
      child: DefaultTextStyle(
        style:
            theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600) ??
            const TextStyle(),
        child: content,
      ),
    );
  }
}

class _ApiaryStatsCard extends StatelessWidget {
  const _ApiaryStatsCard({
    required this.stats,
    required this.apiaryName,
    required this.mainActivityType,
  });

  final ApiaryJourneyStats stats;
  final String apiaryName;
  final String mainActivityType;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = LocaleFormatting.of(context);
    final theme = Theme.of(context);

    return BrandCard(
      key: Key('journey-stats-detail-apiary-${stats.apiaryId}'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              LeadingIconTile(
                icon: Icons.hive_outlined,
                color: context.brand.cresta.color,
                tint: context.brand.cresta.tint,
                size: BrandDimens.sizeLeadingTileSmall,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  apiaryName,
                  style: TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: theme.colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              _VisitBadge(apiaryId: stats.apiaryId, visited: stats.isVisited),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _MiniStat(
                label: l10n.journeyStatsDetailHiveCountLabel,
                value: '${stats.hiveCount}',
              ),
              if (mainActivityType == activityTypeHarvest) ...[
                _MiniStat(
                  label: l10n.journeyStatsDetailHoneyKgLabel,
                  value: locale.decimal(stats.harvestHoneyKg),
                ),
                _MiniStat(
                  label: l10n.journeyStatsDetailSupersLabel,
                  value: '${stats.harvestHoneySupers}',
                ),
                _MiniStat(
                  label: l10n.journeyStatsDetailKgPerHiveLabel,
                  value: stats.kgPerHive == null
                      ? l10n.journeyStatsDetailNoDataValue
                      : locale.decimal(stats.kgPerHive!),
                ),
                _MiniStat(
                  label: l10n.journeyStatsDetailSupersPerHiveLabel,
                  value: stats.supersPerHive == null
                      ? l10n.journeyStatsDetailNoDataValue
                      : locale.decimal(stats.supersPerHive!),
                ),
              ] else if (mainActivityType == activityTypeFeeding) ...[
                _MiniStat(
                  label: l10n.journeyStatsDetailFeedAmountLabel,
                  value: locale.decimal(stats.feedingAmountTotal),
                ),
              ] else if (mainActivityType == activityTypeTreatment) ...[
                _MiniStat(
                  label: l10n.journeyStatsDetailHivesInvolvedLabel,
                  value: '${stats.treatmentHivesInvolved}',
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// A compact label/value pair for one metric inside an [_ApiaryStatsCard] —
/// smaller and denser than the #49 stats section's own [_StatTile]
/// (journey_stats_section.dart), since several of these sit side by side on
/// one card rather than each being its own standalone tile.
class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label: $value',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: theme.colorScheme.onSurface,
              ),
            ),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The visited/planned pill on one [_ApiaryStatsCard] — a local copy of
/// journey_detail_screen.dart's own private `_VisitedBadge` (Dart privacy is
/// per-file, and this codebase's own convention — see that file's doc
/// comment on `_StatTile` — is to copy a small private tile/badge per
/// background rather than share one across files).
class _VisitBadge extends StatelessWidget {
  const _VisitBadge({required this.apiaryId, required this.visited});

  final String apiaryId;
  final bool visited;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final label = visited
        ? l10n.journeyDetailApiaryVisitedBadge
        : l10n.journeyDetailApiaryPlannedBadge;
    final background = visited
        ? theme.colorScheme.secondaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = visited
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      key: Key('journey-stats-detail-apiary-badge-$apiaryId'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(BrandDimens.radiusBadge),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
