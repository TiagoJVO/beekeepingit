import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../activities/activities_repository.dart';
import '../activities/activity_filters.dart';
import '../activities/activity_list_widgets.dart';
import '../activities/activity_types.dart';
import '../apiaries/apiaries_repository.dart';
import 'journey_stats_section.dart';
import 'journey_status.dart';
import 'journeys_repository.dart';

/// The journey detail page (#48, FR-JO-3, D-21): the apiaries visited in the
/// journey, each apiary's activities attributed to it via the STORED
/// `journey_id` (D-21 — never a live re-match), and the #49 aggregated stats
/// section embedded directly. Reached by tapping a row on the main Journeys
/// tab (journeys_list_screen.dart); editing/closing/deleting the journey
/// itself stays on the existing form (journey_form_screen.dart), reachable
/// from here via the edit FAB — mirrors apiary_detail_screen.dart's own
/// "read-focused detail page, FAB pushes the edit form" split.
///
/// Fully offline: every provider this screen (and [JourneyStatsSection], and
/// the embedded [ActivityListView]s) reads is a live watch over the local
/// PowerSync-synced SQLite store — no network call is ever made to render
/// it (EPIC-06).
class JourneyDetailScreen extends ConsumerWidget {
  const JourneyDetailScreen({required this.journeyId, super.key});

  final String journeyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final journeyAsync = ref.watch(journeyByIdProvider(journeyId));

    return Scaffold(
      body: journeyAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.journeysError('$err')),
          ),
        ),
        data: (journey) {
          if (journey == null) {
            // Deleted/not found (e.g. a stale deep link) — nothing sensible
            // to render; bounce back to the list rather than show a blank
            // detail page, mirroring apiary_detail_screen.dart's own
            // handling of the same case.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/journeys');
            });
            return const SizedBox.shrink();
          }
          return _JourneyDetailBody(journey: journey);
        },
      ),
      floatingActionButton: Semantics(
        button: true,
        label: l10n.editJourneyAction,
        child: ExcludeSemantics(
          child: FloatingActionButton.extended(
            key: const Key('journey-detail-edit-button'),
            heroTag: 'journey-detail-edit-button',
            onPressed: () => context.go('/journeys/$journeyId/edit'),
            icon: const Icon(Icons.edit_outlined),
            label: Text(l10n.editJourneyAction),
          ),
        ),
      ),
    );
  }
}

class _JourneyDetailBody extends StatelessWidget {
  const _JourneyDetailBody({required this.journey});

  final Journey journey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final brand = context.brand;
    final typeLabel =
        activityTypeLabel(l10n, journey.mainActivityType) ??
        journey.mainActivityType;
    final statusLabel =
        journeyStatusLabel(l10n, journey.status) ?? journey.status;
    final defaultAttributesSummary = _defaultAttributesSummary(
      l10n,
      journey.mainActivityType,
      journey.defaultAttributes,
    );

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HeroCard(
                key: const Key('journey-detail-header'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      journey.name,
                      style: TextStyle(
                        fontFamily: AppTheme.displayFontFamily,
                        fontWeight: FontWeight.w600,
                        fontSize: 26,
                        color: brand.onHeroSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            typeLabel,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: brand.onHeroSurfaceMuted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _StatusBadge(
                          label: statusLabel,
                          closed: !journey.isOpen,
                        ),
                      ],
                    ),
                    // Journey-level subtype attribute defaults (#385) — only
                    // rendered when the journey actually has any set.
                    if (defaultAttributesSummary != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        defaultAttributesSummary,
                        key: const Key('journey-detail-default-attributes'),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: brand.onHeroSurfaceMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              JourneyStatsSection(
                journeyId: journey.id,
                mainActivityType: journey.mainActivityType,
              ),
              const SizedBox(height: 14),
              _JourneyApiariesSection(journey: journey),
            ],
          ),
        ),
      ),
    );
  }
}

/// The muted "Defaults: Apivar/amitraz · Varroose" summary line under the
/// [HeroCard]'s type label (#385) — one value per set default key, in the
/// same per-type field order journey_default_attributes_section.dart shows
/// them, skipping any key with no value set. Returns null (caller skips
/// rendering the line) when the journey has no defaults at all, or its
/// `main_activity_type` carries none (generic).
String? _defaultAttributesSummary(
  AppLocalizations l10n,
  String mainActivityType,
  Map<String, dynamic> defaultAttributes,
) {
  final values = <String>[];
  switch (mainActivityType) {
    case activityTypeTreatment:
      final context = defaultAttributes['treatment_context'] as String?;
      if (context != null) {
        values.add(treatmentContextLabel(l10n, context) ?? context);
      }
      final type = defaultAttributes['treatment_type'] as String?;
      if (type != null) values.add(type);
      final disease = defaultAttributes['disease'] as String?;
      if (disease != null) values.add(disease);
    case activityTypeFeeding:
      final feedType = defaultAttributes['feed_type'] as String?;
      if (feedType != null) values.add(feedType);
    case activityTypeHarvest:
      final lotBatch = defaultAttributes['lot_batch'] as String?;
      if (lotBatch != null && lotBatch.isNotEmpty) values.add(lotBatch);
  }
  if (values.isEmpty) return null;
  return l10n.journeyDetailDefaultAttributesLabel(values.join(' · '));
}

/// Open/closed pill sitting ON the plum [HeroCard] — styled exactly like
/// apiary_detail_screen.dart's own `_CounterBadge` (a translucent white wash
/// of `onHeroSurface`, so the pill reads against the plum without inventing
/// a colour), not journeys_list_screen.dart's/journey_form_screen.dart's own
/// `_StatusBadge`/`_StatusChip` (those sit on a plain, light card ground).
/// Open carries the stronger wash and weight; both keep the white
/// `onHeroSurface` ink, which is comfortably AA on either. Kept as its own
/// small private widget rather than a shared export — this codebase's
/// established convention: those two files already carry their own
/// near-identical copies for their own backgrounds.
class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.closed});

  final String label;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brand = context.brand;
    return Container(
      key: const Key('journey-detail-status-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: brand.onHeroSurface.withValues(alpha: closed ? 0.12 : 0.22),
        borderRadius: BorderRadius.circular(BrandDimens.radiusBadge),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: brand.onHeroSurface,
          fontWeight: closed ? FontWeight.w600 : FontWeight.w700,
        ),
      ),
    );
  }
}

/// This journey's apiaries (#48, FR-JO-3): every planned apiary
/// (journeys_repository.dart's `watchPlanApiariesByJourney` — the SAME live
/// map the Journeys tab's own progress badge reads, #47) plus any apiary
/// with at least one activity attributed to this journey (D-21) even if it
/// has since fallen out of the plan (an edge case the #46 activity form's
/// manual-override path can produce) — each rendered as "visited" (has a
/// matching activity) or "planned" (still awaiting one). "Visited" uses the
/// exact same membership rule #49's own stats aggregation does
/// (journey_stats.dart's `computeJourneyStats` doc): an apiary counts as
/// visited once ANY activity's stored `journey_id` matches, regardless of
/// that activity's own type. Visited apiaries expand to list their own
/// activities via the shared [ActivityListView] (activity_list_widgets.
/// dart) — same widget/keys/tap-to-detail navigation as the apiary detail
/// page's own per-apiary section (#42) and the main Activities tab (#43).
class _JourneyApiariesSection extends ConsumerWidget {
  const _JourneyApiariesSection({required this.journey});

  final Journey journey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final brand = context.brand;
    final plannedApiaryIds =
        ref.watch(journeyPlanApiariesByJourneyProvider).value?[journey.id] ??
        const <String>[];
    final apiaryNames = <String, String>{
      for (final a
          in ref.watch(apiariesStreamProvider).value ?? const <Apiary>[])
        a.id: a.name,
    };
    final activitiesAsync = ref.watch(activitiesByJourneyProvider(journey.id));

    return Container(
      key: const Key('journey-detail-apiaries-section'),
      padding: const EdgeInsets.all(BrandDimens.padCard),
      decoration: BoxDecoration(
        color: brand.cardColor,
        border: Border.all(color: brand.cardBorder),
        borderRadius: BrandDimens.borderCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(l10n.journeyDetailApiariesTitle),
          const SizedBox(height: 12),
          activitiesAsync.when(
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(),
              ),
            ),
            error: (err, _) => Text(
              l10n.journeysError('$err'),
              key: const Key('journey-detail-apiaries-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
            data: (activities) => _ApiaryEntries(
              journeyId: journey.id,
              plannedApiaryIds: plannedApiaryIds,
              activities: activities,
              apiaryNames: apiaryNames,
            ),
          ),
        ],
      ),
    );
  }
}

/// Groups [activities] by apiary and orders the combined apiary-id set:
/// planned apiaries first (in the plan's own order), then any apiary with an
/// attributed activity that isn't (or is no longer) in the plan — a
/// seen-ids guard against a duplicate entry when an id appears in both.
class _ApiaryEntries extends StatelessWidget {
  const _ApiaryEntries({
    required this.journeyId,
    required this.plannedApiaryIds,
    required this.activities,
    required this.apiaryNames,
  });

  final String journeyId;
  final List<String> plannedApiaryIds;
  final List<Activity> activities;
  final Map<String, String> apiaryNames;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final byApiary = <String, List<Activity>>{};
    for (final activity in activities) {
      (byApiary[activity.apiaryId] ??= []).add(activity);
    }

    final seen = <String>{};
    final apiaryIds = <String>[
      for (final id in plannedApiaryIds)
        if (seen.add(id)) id,
      for (final id in byApiary.keys)
        if (seen.add(id)) id,
    ];

    if (apiaryIds.isEmpty) {
      return EmptyState(
        key: const Key('journey-detail-apiaries-empty'),
        message: l10n.journeyDetailApiariesEmpty,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final apiaryId in apiaryIds) ...[
          _ApiaryCard(
            journeyId: journeyId,
            apiaryId: apiaryId,
            // A raw internal id would leak into user-facing text if this
            // apiary isn't in the currently-loaded list (deleted since, or
            // apiariesStreamProvider hasn't emitted yet) — a localized
            // placeholder instead, mirroring activity_list_widgets.dart's own
            // "unresolved name" convention (there it omits the apiary label
            // entirely; here the apiary name IS the card's own heading, so a
            // placeholder reads better than blank).
            apiaryName:
                apiaryNames[apiaryId] ?? l10n.journeyDetailApiaryNameUnknown,
            isPlanned: plannedApiaryIds.contains(apiaryId),
            activities: byApiary[apiaryId] ?? const [],
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// One apiary card: name, the visited/planned badge (#48 AC: "planned items
/// not yet executed are clearly distinguished from completed items"), and —
/// only once visited — its own activities via [ActivityListView]. A
/// planned-but-not-visited apiary shows a short placeholder line instead of
/// an activity list (there's nothing to list yet).
class _ApiaryCard extends StatelessWidget {
  const _ApiaryCard({
    required this.journeyId,
    required this.apiaryId,
    required this.apiaryName,
    required this.isPlanned,
    required this.activities,
  });

  final String journeyId;
  final String apiaryId;
  final String apiaryName;
  final bool isPlanned;
  final List<Activity> activities;

  bool get _isVisited => activities.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return BrandCard(
      key: Key('journey-detail-apiary-$apiaryId'),
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
              _VisitedBadge(apiaryId: apiaryId, visited: _isVisited),
            ],
          ),
          if (_isVisited) ...[
            const SizedBox(height: 8),
            ActivityListView(
              viewModel: AsyncValue.data(
                ActivitiesViewModel(
                  hasAnyActivities: true,
                  filtered: activities,
                ),
              ),
              // Unreachable: this branch only renders when [activities] is
              // non-empty, so [ActivityListView] never hits its own empty
              // state.
              emptyText: '',
              shrinkWrap: true,
              // #384: keep a tap on this journey's own activity inside the
              // Journeys branch (see ActivityListView's own doc comment) —
              // apiaryId travels as a query parameter for
              // journeyActivityDetail's own route (app_router.dart).
              detailLocationBuilder: (activity) =>
                  '/journeys/$journeyId/activities/${activity.id}'
                  '?apiaryId=${activity.apiaryId}',
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              l10n.journeyDetailApiaryNotVisitedYet,
              key: Key('journey-detail-apiary-not-visited-$apiaryId'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The visited/planned pill on one [_ApiaryCard] — keyed per-apiary (not a
/// single shared literal key) since multiple cards render side by side on
/// the same page, unlike the single-instance badges elsewhere in this file.
class _VisitedBadge extends StatelessWidget {
  const _VisitedBadge({required this.apiaryId, required this.visited});

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
      key: Key('journey-detail-apiary-badge-$apiaryId'),
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
