import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../members/members_repository.dart';
import '../profile/profile_repository.dart';
import 'activities_repository.dart';
import 'activity_display.dart';
import 'activity_filters.dart';
import 'activity_types.dart';

/// The single mapping from an activity type to its brand accent + tile tint
/// (`context.brand`'s cresta/feeding/treatment/generic roles) — every screen
/// that renders a typed activity row/chip/picker reuses this rather than its
/// own switch (activities list, apiary detail's embedded section, the
/// add-activity type picker).
ActivityTypeVisual activityTypeVisual(BuildContext context, String type) {
  final brand = context.brand;
  return switch (type) {
    activityTypeHarvest => brand.cresta,
    activityTypeFeeding => brand.feeding,
    activityTypeTreatment => brand.treatment,
    _ => brand.generic,
  };
}

/// The Material icon paired with [activityTypeVisual] for a given type.
IconData activityTypeIcon(String type) => switch (type) {
  activityTypeHarvest => Icons.hive_outlined,
  activityTypeFeeding => Icons.restaurant_outlined,
  activityTypeTreatment => Icons.healing_outlined,
  _ => Icons.event_note_outlined,
};

/// The type + date-range filter bar shared by #42's apiary-scoped section
/// and #43's main Activities tab (DRY, #42/#43 AC: filterable by type and
/// date range, combinable). Purely presentational: the caller owns the
/// actual filter STATE (activity_filters.dart's scoped providers) and passes
/// the current selection + change callbacks in, so this widget has no
/// opinion on which screen/scope it belongs to.
///
/// Gloves-friendly (FR-UX-1/FR-AX-1): every interactive control here meets
/// the app's 44x44 [kMinTapTarget] minimum, matching apiaries_list_screen.
/// dart's own view toggle.
class ActivityFilterBar extends StatelessWidget {
  const ActivityFilterBar({
    required this.type,
    required this.dateRange,
    required this.onTypeChanged,
    required this.onDateRangeChanged,
    super.key,
  });

  final String? type;
  final ActivityDateRange? dateRange;
  final ValueChanged<String?> onTypeChanged;
  final ValueChanged<ActivityDateRange?> onDateRangeChanged;

  bool get _hasFilter => type != null || dateRange != null;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<String?>(
            key: const Key('activity-filter-type-field'),
            initialValue: type,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l10n.activityFilterTypeLabel,
              isDense: true,
            ),
            items: [
              DropdownMenuItem(
                value: null,
                child: Text(l10n.activityFilterTypeAll),
              ),
              for (final t in knownActivityTypes)
                DropdownMenuItem(
                  value: t,
                  child: Text(activityTypeLabel(l10n, t) ?? t),
                ),
            ],
            onChanged: onTypeChanged,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const Key('activity-filter-date-range-field'),
                  onTap: () => _pickRange(context),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.activityFilterDateRangeLabel,
                      isDense: true,
                    ),
                    child: Text(
                      dateRange == null
                          ? l10n.activityFilterDateRangeUnset
                          : l10n.activityFilterDateRangeValue(
                              LocaleFormatting.of(
                                context,
                              ).date(dateRange!.start),
                              LocaleFormatting.of(context).date(dateRange!.end),
                            ),
                    ),
                  ),
                ),
              ),
              if (_hasFilter) ...[
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('activity-filter-clear-button'),
                  tooltip: l10n.activityFilterClearAction,
                  constraints: const BoxConstraints(
                    minWidth: kMinTapTarget,
                    minHeight: kMinTapTarget,
                  ),
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    onTypeChanged(null);
                    onDateRangeChanged(null);
                  },
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickRange(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: now.add(const Duration(days: 1)),
      initialDateRange: dateRange == null
          ? null
          : DateTimeRange(start: dateRange!.start, end: dateRange!.end),
    );
    if (picked != null) {
      onDateRangeChanged(
        ActivityDateRange(start: picked.start, end: picked.end),
      );
    }
  }
}

/// One activities list's body (#42/#43): loading/error states, the two
/// distinct empty states (mirrors apiaries_list_screen.dart's own
/// `hasAnyApiaries` vs. "search matched nothing" split — here "zero
/// activities at all" vs. "the current filters matched none", #42/#43 AC),
/// and the list itself, one row per activity with its attribution (#44).
///
/// [showApiary]/[apiaryNameOf] are only used by #43's main, cross-apiary tab
/// to show which apiary each row belongs to — #42's embedded per-apiary
/// section passes `showApiary: false` since the apiary is already the whole
/// screen's own context. [shrinkWrap] lets #42 embed this inside an outer
/// `SingleChildScrollView` (apiary_detail_screen.dart) without two nested
/// unbounded scrollables fighting each other.
///
/// [maxItems] caps how many rows this list renders — used by #42's embedded
/// preview, which is `shrinkWrap`ped and so can't lazily virtualize (every
/// built row is laid out up front): over many seasons an apiary can
/// accumulate hundreds of activities, and building them all on every filter
/// change or sync write is wasteful. When the filtered set exceeds [maxItems]
/// the surplus rows are hidden behind a "view all" row ([onViewAll]) that
/// opens the full, properly-virtualized per-apiary list instead. Capping only
/// takes effect when [onViewAll] is also supplied, so rows are never hidden
/// with no way to reach them. The full-screen list (`apiary_activities_
/// screen.dart`) and #43's main tab leave both null and render every row.
class ActivityListView extends ConsumerWidget {
  const ActivityListView({
    required this.viewModel,
    required this.emptyText,
    this.showApiary = false,
    this.apiaryNameOf,
    this.shrinkWrap = false,
    this.maxItems,
    this.onViewAll,
    super.key,
  });

  final AsyncValue<ActivitiesViewModel> viewModel;
  final String emptyText;
  final bool showApiary;
  final String? Function(String apiaryId)? apiaryNameOf;
  final bool shrinkWrap;
  final int? maxItems;
  final VoidCallback? onViewAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // The caller's own id (#44): drives the "You" vs. name/"Member <id>"
    // attribution split (activity_display.dart's activityAttributionText).
    final currentUserId = ref.watch(profileProvider).value?.id;
    // The org member-name roster (#44), for showing OTHER performers' real
    // names. Online-fetched + session-cached (memberNamesProvider); empty
    // offline or before first load, in which case attribution falls back to
    // a short id fragment — never an error, so the offline-first list still
    // renders.
    final memberNames =
        ref.watch(memberNamesProvider).value ?? const <String, String>{};

    return viewModel.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.activitiesError('$err')),
        ),
      ),
      data: (vm) {
        if (!vm.hasAnyActivities) {
          return EmptyState(message: emptyText);
        }
        if (vm.filtered.isEmpty) {
          return EmptyState(message: l10n.activitiesFilterNoResults);
        }
        // Cap the rendered rows only when there's a "view all" escape hatch,
        // so a capped preview never strands rows the user can't reach (#42/
        // #308).
        final capping = maxItems != null && onViewAll != null;
        final visible = capping && vm.filtered.length > maxItems!
            ? vm.filtered.take(maxItems!).toList()
            : vm.filtered;
        final showViewAll = visible.length < vm.filtered.length;
        // Transparent Material ancestor so each now-tappable [_ActivityTile]
        // and the "view all" row (#310) paint their ink splash on a Material
        // nearer than any colored container they're embedded in — the apiary
        // detail's per-apiary section wraps this list in a surface-tinted
        // Container (apiary_detail_screen.dart), which would otherwise hide the
        // tap ink (and trips a debug assertion). No visual change:
        // MaterialType.transparency paints nothing itself.
        return Material(
          type: MaterialType.transparency,
          child: ListView.separated(
            key: const Key('activity-list'),
            shrinkWrap: shrinkWrap,
            physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
            itemCount: visible.length + (showViewAll ? 1 : 0),
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              if (i == visible.length) {
                return _ViewAllActivitiesTile(
                  total: vm.filtered.length,
                  onTap: onViewAll!,
                );
              }
              final activity = visible[i];
              return _ActivityTile(
                activity: activity,
                currentUserId: currentUserId,
                memberNames: memberNames,
                apiaryName: showApiary
                    ? apiaryNameOf?.call(activity.apiaryId)
                    : null,
              );
            },
          ),
        );
      },
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.activity,
    required this.currentUserId,
    required this.memberNames,
    this.apiaryName,
  });

  final Activity activity;
  final String? currentUserId;
  final Map<String, String> memberNames;
  final String? apiaryName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dateText = LocaleFormatting.of(context).date(activity.occurredAtDate);
    final typeLabel = activityTypeLabel(l10n, activity.type) ?? activity.type;
    final title = apiaryName == null ? typeLabel : '$apiaryName · $typeLabel';
    final subtitle = '$dateText · ${activitySummaryLine(l10n, activity)}';
    final attribution = activityAttributionText(
      l10n,
      activity,
      currentUserId,
      memberNames: memberNames,
    );
    final typeVisual = activityTypeVisual(context, activity.type);

    return ListTile(
      key: Key('activity-${activity.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      // Tapping a row opens the activity detail (#310, FR-AC-3/5/6). Both the
      // per-apiary section (apiary detail) and the main all-apiaries tab use
      // this shared tile, so this single onTap wires both list surfaces. The
      // detail route lives under the apiaries branch (app_router.dart) — where
      // every activity view/edit/delete surface lives — so a tap from the
      // Activities tab crosses into that branch's stack (Back returns to the
      // apiary context), consistent with where edit/delete already live.
      onTap: () => context.go(
        '/apiaries/${activity.apiaryId}/activities/${activity.id}',
      ),
      leading: LeadingIconTile(
        icon: activityTypeIcon(activity.type),
        color: typeVisual.color,
        tint: typeVisual.tint,
        size: BrandDimens.sizeLeadingTileSmall,
      ),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Semantics(
        label: l10n.activityPerformedBySemanticLabel(attribution),
        child: ExcludeSemantics(
          child: Chip(
            key: const Key('activity-attribution'),
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.person_outline, size: 16),
            label: Text(attribution),
          ),
        ),
      ),
    );
  }
}

/// The "view all N activities" row shown at the foot of a capped preview
/// (#42's embedded per-apiary section): opens the full, lazily-virtualized
/// per-apiary list rather than rendering every hidden row inline. Sized to
/// the app's gloves-friendly tap minimum (FR-UX-1/FR-AX-1) like the filter
/// bar's own controls.
class _ViewAllActivitiesTile extends StatelessWidget {
  const _ViewAllActivitiesTile({required this.total, required this.onTap});

  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    // An InkWell (not a ListTile) — the embedded preview wraps this list in a
    // decorated Container, and a tappable ListTile there trips Flutter's
    // "ink splashes may be invisible" assertion. Mirrors the filter bar's own
    // InkWell tap targets, sized to the gloves-friendly minimum
    // (FR-UX-1/FR-AX-1). Wrapped in Semantics(button:) to keep the button
    // role a ListTile would have exposed to assistive tech (WCAG 2.2 AA).
    return Semantics(
      button: true,
      child: InkWell(
        key: const Key('activity-list-view-all'),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTapTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.apiaryActivitiesViewAll(total),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, color: theme.colorScheme.primary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
