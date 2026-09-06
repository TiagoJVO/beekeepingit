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
                              LocaleFormatting.of(context)
                                  .date(dateRange!.start),
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
    bool? reserveBottomChrome,
    this.maxItems,
    this.onViewAll,
    this.detailLocationBuilder,
    super.key,
  }) : reserveBottomChrome = reserveBottomChrome ?? !shrinkWrap;

  final AsyncValue<ActivitiesViewModel> viewModel;
  final String emptyText;
  final bool showApiary;
  final String? Function(String apiaryId)? apiaryNameOf;
  final bool shrinkWrap;

  /// Whether this list reserves the bottom chrome band itself (#789).
  ///
  /// Named separately from [shrinkWrap] rather than derived from it inline,
  /// the way `HistoryTimelineList` names its own (#773). The two coincide for
  /// today's callers — the embedded previews shrink-wrap inside a page that
  /// already reserves the band, the two full-screen lists do neither — but
  /// they mean unrelated things: one is "build every row up front", the other
  /// is "nobody above me has reserved the chrome's landing space". A future
  /// caller wanting a shrink-wrapped list somewhere nothing else reserves the
  /// band can say so, instead of silently getting no padding out of a layout
  /// flag.
  final bool reserveBottomChrome;

  final int? maxItems;
  final VoidCallback? onViewAll;

  /// Overrides where a row navigates on tap (#384) — defaults to the
  /// apiaries-branch activity detail route (`_ActivityTile`'s own doc
  /// comment) when omitted. A caller embedding this list in a DIFFERENT
  /// navigation branch (journey_detail_screen.dart's own activity rows)
  /// passes a location under ITS OWN branch instead, so the tab that opens
  /// stays the one the user was already on, and Back returns there —
  /// rather than silently crossing into the apiaries tab.
  final String Function(Activity activity)? detailLocationBuilder;

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
            // The two full-screen lists (#43's Activities tab, #42's
            // per-apiary list) are scrollables of their own and reserve the
            // bottom chrome band (#789): the Activities tab is a tab ROOT, so
            // the shell's quick-add FAB floats over this list's bottom-right,
            // and either list is where "Activity saved" lands when the add
            // flow returns to it. The embedded preview is a block inside the
            // detail page's own scroll view, which reserves that band once for
            // the whole page — reserving it again here would open a hole
            // mid-card.
            padding: reserveBottomChrome
                ? EdgeInsets.only(
                    bottom: BrandDimens.scrollBottomInsetOf(context),
                  )
                : EdgeInsets.zero,
            itemCount: visible.length + (showViewAll ? 1 : 0),
            separatorBuilder: (_, _) => const Divider(height: 1),
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
                detailLocationBuilder: detailLocationBuilder,
              );
            },
          ),
        );
      },
    );
  }
}

/// Below this ROW width an activity renders in its compact, three-line phone
/// form; at or above it the wide layout is preserved verbatim (#632).
///
/// 600 is Material 3's own compact/medium window boundary, and this app has no
/// reason to draw a different line. The number is compared against the row's
/// own constraints rather than the viewport, so a full-bleed list flips a
/// little below a 640px viewport (the tile's 20px gutters) and the apiary
/// detail's embedded card — which is narrower than the page it sits on —
/// flips a little later still. That is the intended reading: what the row can
/// fit depends on the room the row actually has, not on the size of the
/// screen behind it.
const double _kCompactRowBelowWidth = 600;

/// A [ListTile], deliberately, not a [BrandRowCard] — settled in #758
/// (FR-AC-5, FR-UX-1, D-18) after #662 landed, which was the only reason
/// PR #755 left the question open instead of answering it. Four reasons this
/// row stays put, so the question stops reopening:
///
/// Structural: [BrandRowCard] is a fixed two-line row — a `String` title and
/// subtitle, `maxLines: 2` hardcoded on the subtitle (`brand_widgets.dart`)
/// — with no responsive variant. This row is three capped single lines below
/// [_kCompactRowBelowWidth], and one line plus a trailing [Chip] above it.
/// Adopting would mean adding a third-line slot, a `subtitleMaxLines`
/// override and a compact/wide variant to a widget three OTHER screens
/// share, for this one caller. `todo_list_widgets.dart`'s `_TodoTile`
/// declined the same widget for the same class of reason (there, a
/// strikethrough title `BrandRowCard`'s plain `String` has no room for).
///
/// Density, as numbers: [BrandCard]'s fixed `padCard` (32px total, and it
/// does not scale with text) plus the `gapCard` (10px) separator cards
/// require between them takes this row's on-screen pitch from ~89px to
/// ~109px at a 375px width — a ~22% loss on the screen #632 existed to make
/// dense (at current `padCard`/`gapCard` values — re-measure rather than
/// assume if those tokens move). `activity_row_density_test.dart`'s "at
/// least eight rows" assertion would NOT catch this: it measures a single
/// row's own height, not the list's pitch, and the loss here lives entirely
/// in the gap a card imposes between rows.
///
/// Nesting: this tile renders inside `apiary_detail_screen.dart`'s card
/// `Container` AND inside `journey_detail_screen.dart`'s `_ApiaryCard`
/// [BrandCard] (~line 454) — a [BrandRowCard] in either spot is a card
/// inside a card. The current `ListTile` + `Divider(height: 1)` composition
/// is the same pattern `MenuListCard` uses for its own grouped rows, so this
/// row is already speaking the shared vocabulary's container dialect, not
/// lacking one.
///
/// Accessibility: the row already announces once and is already guarded —
/// `a11y_field_ux_test.dart` (~line 751) covers it in the same sweep as the
/// [BrandCard] rows, so the announce-once contract does not live only in
/// [BrandRowCard]. Adopting would INVERT this: [BrandCard]'s
/// `ExcludeSemantics` would silence [_AttributionLine]'s and the [Chip]'s
/// own `Semantics` labels, which would then need re-routing through
/// `trailingSemanticLabel`.
///
/// This flips if [BrandRowCard] ever grows a genuine responsive three-line
/// variant for reasons of its own — another caller needing it — adopt then.
/// What was rejected here is adding those params for this caller alone.
class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.activity,
    required this.currentUserId,
    required this.memberNames,
    this.apiaryName,
    this.detailLocationBuilder,
  });

  final Activity activity;
  final String? currentUserId;
  final Map<String, String> memberNames;
  final String? apiaryName;
  final String Function(Activity activity)? detailLocationBuilder;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dateText = LocaleFormatting.of(context).date(activity.occurredAtDate);
    final typeLabel = activityTypeLabel(l10n, activity.type) ?? activity.type;
    final title = apiaryName == null ? typeLabel : '$apiaryName · $typeLabel';
    final attribution = activityAttributionText(
      l10n,
      activity,
      currentUserId,
      memberNames: memberNames,
    );
    final typeVisual = activityTypeVisual(context, activity.type);

    // Measured on the ROW's own width, not the screen's (#632): the same tile
    // renders full-bleed on the Activities tab AND inside the apiary detail's
    // padded card, which is narrower than the viewport it sits in — the case
    // where the defect was worst. `MediaQuery.sizeOf` would have called both
    // "wide" at the same viewport.
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < _kCompactRowBelowWidth;
        // Compact: the date plus this type's headline metric(s) only — the
        // rest is one tap away on the detail screen. Wide: every attribute,
        // exactly as before, because at that width it still lands on one line.
        final String summary;
        if (compact) {
          final headline = activityHeadlineLine(l10n, activity);
          summary = headline.isEmpty ? dateText : '$dateText · $headline';
        } else {
          summary = '$dateText · ${activitySummaryLine(l10n, activity)}';
        }

        return ListTile(
          key: Key('activity-${activity.id}'),
          // No extra vertical padding in the compact form: [ListTile]'s own
          // three-line minimum (88px, comfortably above the 44px gloves floor,
          // D-18) already sizes the row, and adding 16px on top of it cost a
          // whole activity per phone screen for nothing.
          contentPadding: compact
              ? const EdgeInsets.symmetric(horizontal: 20)
              : const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          // The compact row is three lines (type · date+headline · actor), so
          // the leading tile aligns to the top of them rather than floating in
          // the middle of a tall row.
          isThreeLine: compact,
          // Tapping a row opens the activity detail (#310, FR-AC-3/5/6). Both
          // the per-apiary section (apiary detail) and the main all-apiaries
          // tab use this shared tile, so this single onTap wires both list
          // surfaces. The detail route lives under the apiaries branch
          // (app_router.dart) — where every activity view/edit/delete surface
          // lives — so a tap from the Activities tab crosses into that
          // branch's stack (Back returns to the apiary context), consistent
          // with where edit/delete already live. [detailLocationBuilder]
          // (#384) overrides this for a caller embedding this tile in a
          // different branch's own stack (journey_detail_screen.dart) — see
          // ActivityListView's own doc comment.
          onTap: () => context.go(
            detailLocationBuilder?.call(activity) ??
                '/apiaries/${activity.apiaryId}/activities/${activity.id}',
          ),
          leading: LeadingIconTile(
            icon: activityTypeIcon(activity.type),
            color: typeVisual.color,
            tint: typeVisual.tint,
            size: BrandDimens.sizeLeadingTileSmall,
          ),
          // Capped + ellipsized at both widths (#632 AC: long values truncate
          // at a sensible boundary, never mid-token) — an uncapped `Text` soft-
          // wrapped a long apiary name or lot/batch id mid-word instead.
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: compact
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(summary, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 2),
                    // The actor moves BENEATH the text at this width instead of
                    // reserving a chip beside it: the fixed-width chip was what
                    // squeezed the subtitle into roughly a 145px column on a
                    // 375px screen. Still one line, still per-row (FR-TEN-2),
                    // still labelled for screen readers (D-18).
                    _AttributionLine(attribution: attribution),
                  ],
                )
              : Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: compact
              ? null
              : Semantics(
                  label: l10n.activityPerformedBySemanticLabel(attribution),
                  child: ExcludeSemantics(
                    child: Chip(
                      key: const Key('activity-attribution'),
                      visualDensity: VisualDensity.compact,
                      avatar: const Icon(Icons.person_outline, size: 16),
                      label: Text(
                        attribution,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// The compact row's third line: who performed the activity (#44, FR-TEN-2),
/// as an icon + muted text rather than the wide layout's trailing [Chip].
///
/// Carries the same [AppLocalizations.activityPerformedBySemanticLabel]
/// wrapper the chip does, so the announcement a screen reader makes does not
/// change with the viewport (D-18, WCAG 2.2 AA).
class _AttributionLine extends StatelessWidget {
  const _AttributionLine({required this.attribution});

  final String attribution;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Semantics(
      label: l10n.activityPerformedBySemanticLabel(attribution),
      child: ExcludeSemantics(
        child: Row(
          key: const Key('activity-attribution'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_outline,
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                attribution,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
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
