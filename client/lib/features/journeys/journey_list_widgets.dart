import 'package:flutter/material.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../activities/activity_types.dart';
import 'journey_filters.dart';
import 'journey_status.dart';

/// The type, status and date-range filter bar for the main Journeys tab
/// (#47/#658, FR-JO-2, D-35 — the status control is D-35's, the rest #47's;
/// see journey_filters.dart) — mirrors activity_list_widgets.dart's own `ActivityFilterBar`
/// almost exactly (same combinable-filters UX), but filters journeys
/// instead of activities. Purely presentational: the caller
/// (journeys_list_screen.dart) owns the actual filter STATE
/// (journey_filters.dart's scoped providers) and passes the current
/// selection + change callbacks in.
///
/// Kept as its own small widget (rather than generalizing
/// [ActivityFilterBar] to serve both features) to keep this story's diff
/// additive and narrowly scoped — see the PR description.
///
/// Gloves-friendly (FR-UX-1/FR-AX-1): every interactive control here meets
/// the app's 44x44 [kMinTapTarget] minimum, matching `ActivityFilterBar`'s
/// own.
class JourneyFilterBar extends StatelessWidget {
  const JourneyFilterBar({
    required this.type,
    required this.status,
    required this.dateRange,
    required this.onTypeChanged,
    required this.onStatusChanged,
    required this.onDateRangeChanged,
    super.key,
  });

  final String? type;

  /// The selected [knownJourneyStatuses] value, or null for "all statuses"
  /// (#658, D-35) — same null-is-cleared shape as [type].
  final String? status;

  final JourneyDateRange? dateRange;
  final ValueChanged<String?> onTypeChanged;
  final ValueChanged<String?> onStatusChanged;
  final ValueChanged<JourneyDateRange?> onDateRangeChanged;

  bool get _hasFilter => type != null || status != null || dateRange != null;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        BrandDimens.gutter,
        8,
        BrandDimens.gutter,
        4,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Type and status share one row (like TodoFilterBar's own status +
          // priority pair) rather than each taking a full-width line, so
          // adding the status filter doesn't push the list itself further
          // down the screen.
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  key: const Key('journey-filter-type-field'),
                  initialValue: type,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.journeyFilterTypeLabel,
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(l10n.journeyFilterTypeAll),
                    ),
                    for (final t in knownActivityTypes)
                      DropdownMenuItem(
                        value: t,
                        child: Text(activityTypeLabel(l10n, t) ?? t),
                      ),
                  ],
                  onChanged: onTypeChanged,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                // The open/all control D-35 needs so Home's "view all
                // journeys" has a filtered list to land on. Built from
                // [knownJourneyStatuses] (not a hardcoded open/closed pair)
                // for the same reason the type dropdown iterates
                // knownActivityTypes: a status the vocabulary gains later
                // shows up here without touching this widget.
                child: DropdownButtonFormField<String?>(
                  key: const Key('journey-filter-status-field'),
                  initialValue: status,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.journeyFilterStatusLabel,
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(l10n.journeyFilterStatusAll),
                    ),
                    for (final s in knownJourneyStatuses)
                      DropdownMenuItem(
                        value: s,
                        child: Text(journeyStatusLabel(l10n, s) ?? s),
                      ),
                  ],
                  onChanged: onStatusChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: InkWell(
                  key: const Key('journey-filter-date-range-field'),
                  borderRadius: BrandDimens.borderField,
                  onTap: () => _pickRange(context),
                  child: InputDecorator(
                    decoration: InputDecoration(
                      labelText: l10n.journeyFilterDateRangeLabel,
                      isDense: true,
                    ),
                    child: Text(
                      dateRange == null
                          ? l10n.journeyFilterDateRangeUnset
                          : l10n.journeyFilterDateRangeValue(
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
                  key: const Key('journey-filter-clear-button'),
                  tooltip: l10n.journeyFilterClearAction,
                  constraints: const BoxConstraints(
                    minWidth: kMinTapTarget,
                    minHeight: kMinTapTarget,
                  ),
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    onTypeChanged(null);
                    onStatusChanged(null);
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
        JourneyDateRange(start: picked.start, end: picked.end),
      );
    }
  }
}
