import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../activities/activity_types.dart';
import 'journey_stats.dart';
import 'journeys_repository.dart';

/// The journey stats section (#49, FR-JO-1, D-2, D-21): apiaries visited
/// (feitos/planeados), hives harvested, honey collected, média
/// alças/colmeia, and how much is still missing — matching the Melargil
/// prototype's "Jornada detalhe" stat cards (docs/design/prototype.md).
///
/// This is deliberately the MINIMAL display surface for #49's own scope —
/// the aggregation logic (journeys_repository.dart's `getStats`/
/// `watchStats`, journey_stats.dart's `computeJourneyStats`) is the part
/// this issue is actually about. The full "Jornada detalhe" page (name,
/// period, apiaries-of-the-journey list, edit entry point) is #48's own
/// scope, which embeds this section rather than re-deriving the stats
/// itself — a plain `ConsumerWidget` keyed only by [journeyId] so #48 can
/// drop it into a larger scrollable column exactly like
/// apiary_detail_screen.dart embeds `_ApiaryActivitiesSection`.
///
/// The displayed metrics ADAPT to the journey's [mainActivityType] (#342,
/// FR-JO-3): every journey shows the universal progress metrics (apiaries
/// visited vs. planned, and how much is still missing — FR-JO-1), but the
/// harvest-only aggregations (hives harvested per D-2, honey collected, média
/// alças/colmeia) render ONLY for a harvest journey — they'd be meaningless on
/// a feeding/treatment/generic journey, whose activities carry no honey/supers
/// attributes. The caller already holds the journey (journey_detail_screen),
/// so the type is passed in rather than re-watched here.
class JourneyStatsSection extends ConsumerWidget {
  const JourneyStatsSection({
    required this.journeyId,
    required this.mainActivityType,
    super.key,
  });

  final String journeyId;
  final String mainActivityType;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final statsAsync = ref.watch(journeyStatsProvider(journeyId));

    final brand = context.brand;

    return Container(
      key: const Key('journey-stats-section'),
      padding: const EdgeInsets.all(BrandDimens.padCard),
      decoration: BoxDecoration(
        color: brand.cardColor,
        border: Border.all(color: brand.cardBorder),
        borderRadius: BrandDimens.borderCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(l10n.journeyStatsSectionTitle),
          const SizedBox(height: 12),
          statsAsync.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (err, _) => Text(
              l10n.journeyStatsError('$err'),
              key: const Key('journey-stats-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
            data: (stats) => _JourneyStatsBody(
              stats: stats,
              mainActivityType: mainActivityType,
            ),
          ),
        ],
      ),
    );
  }
}

class _JourneyStatsBody extends StatelessWidget {
  const _JourneyStatsBody({
    required this.stats,
    required this.mainActivityType,
  });

  final JourneyStats stats;
  final String mainActivityType;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = LocaleFormatting.of(context);

    // D-2 harvest aggregations (hives harvested, honey collected, média
    // alças/colmeia) only make sense for a harvest journey — a feeding/
    // treatment/generic journey's activities carry no honey/supers attributes,
    // so summing them would only ever show a meaningless 0 (#342, FR-JO-3).
    final isHarvest = mainActivityType == activityTypeHarvest;

    final averageSupersText = stats.averageSupersPerHive == null
        ? l10n.journeyStatsAverageSupersNoData
        : locale.decimal(stats.averageSupersPerHive!);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _StatTile(
              statKey: 'apiaries-visited',
              value: l10n.journeyStatsApiariesVisitedValue(
                stats.apiariesVisited,
                stats.apiariesPlanned,
              ),
              label: l10n.journeyStatsApiariesVisitedLabel,
            ),
            if (isHarvest) ...[
              _StatTile(
                statKey: 'hives-harvested',
                value: '${stats.hivesHarvested}',
                label: l10n.journeyStatsHivesHarvestedLabel,
              ),
              _StatTile(
                statKey: 'honey-collected',
                value: l10n.journeyStatsHoneyCollectedValue(
                  locale.decimal(stats.honeyCollectedKg),
                ),
                label: l10n.journeyStatsHoneyCollectedLabel,
              ),
              _StatTile(
                statKey: 'average-supers',
                value: averageSupersText,
                label: l10n.journeyStatsAverageSupersLabel,
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          l10n.journeyStatsMissingLabel(stats.apiariesMissing),
          key: const Key('journey-stats-missing'),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ],
    );
  }
}

/// One stat card: a large value over a small label, matching the
/// prototype's own stat-card shape (a bold number over a muted caption) —
/// the same visual language as apiary_detail_screen.dart's counter tiles (a
/// tinted, rounded tile carrying the figure), re-grounded for this section's
/// light card instead of that screen's plum hero: the tile ground is the
/// theme's raised-surface role and the value takes the Playfair display face
/// at the brand field radius, so the figure reads as a headline rather than
/// body copy while keeping its AA-safe `onSurface` ink.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.statKey,
    required this.value,
    required this.label,
  });

  final String statKey;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: Key('journey-stats-$statKey'),
      width: 148,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BrandDimens.borderField,
      ),
      child: Semantics(
        label: '$label: $value',
        child: ExcludeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(
                  fontFamily: AppTheme.displayFontFamily,
                  fontWeight: FontWeight.w600,
                  fontSize: 24,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
