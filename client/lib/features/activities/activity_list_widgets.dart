import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../profile/profile_repository.dart';
import 'activities_repository.dart';
import 'activity_display.dart';
import 'activity_filters.dart';
import 'activity_types.dart';

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
              border: const OutlineInputBorder(),
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
                      border: const OutlineInputBorder(),
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
class ActivityListView extends ConsumerWidget {
  const ActivityListView({
    required this.viewModel,
    required this.emptyText,
    this.showApiary = false,
    this.apiaryNameOf,
    this.shrinkWrap = false,
    super.key,
  });

  final AsyncValue<ActivitiesViewModel> viewModel;
  final String emptyText;
  final bool showApiary;
  final String? Function(String apiaryId)? apiaryNameOf;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // The caller's own id (#44): drives the "You" vs. "Member <id>"
    // attribution split (activity_display.dart's activityAttributionText).
    final currentUserId = ref.watch(profileProvider).value?.id;

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
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(emptyText),
            ),
          );
        }
        if (vm.filtered.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.activitiesFilterNoResults),
            ),
          );
        }
        return ListView.separated(
          key: const Key('activity-list'),
          shrinkWrap: shrinkWrap,
          physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
          itemCount: vm.filtered.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final activity = vm.filtered[i];
            return _ActivityTile(
              activity: activity,
              currentUserId: currentUserId,
              apiaryName: showApiary
                  ? apiaryNameOf?.call(activity.apiaryId)
                  : null,
            );
          },
        );
      },
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.activity,
    required this.currentUserId,
    this.apiaryName,
  });

  final Activity activity;
  final String? currentUserId;
  final String? apiaryName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final dateText = LocaleFormatting.of(context).date(activity.occurredAtDate);
    final typeLabel = activityTypeLabel(l10n, activity.type) ?? activity.type;
    final title = apiaryName == null ? typeLabel : '$apiaryName · $typeLabel';
    final subtitle = '$dateText · ${activitySummaryLine(l10n, activity)}';
    final attribution = activityAttributionText(l10n, activity, currentUserId);

    return ListTile(
      key: Key('activity-${activity.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: Icon(_iconFor(activity.type)),
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

  IconData _iconFor(String type) => switch (type) {
    activityTypeHarvest => Icons.hive_outlined,
    activityTypeFeeding => Icons.restaurant_outlined,
    activityTypeTreatment => Icons.healing_outlined,
    _ => Icons.event_note_outlined,
  };
}
