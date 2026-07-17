import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/gen/app_localizations.dart';
import '../activities/activity_filters.dart';
import '../activities/activity_list_widgets.dart';
import 'apiaries_repository.dart';

/// The full, single-apiary activities list (#42, FR-AC-5): every activity for
/// one apiary, filterable by type and date range. Reached from the apiary
/// detail page's embedded preview once it caps
/// (`_ApiaryActivitiesSection._previewLimit`) — a pushed, full-height screen
/// whose [ActivityListView] is NOT `shrinkWrap`ped, so it lazily virtualizes
/// its rows however many an apiary has accumulated over the seasons (the
/// embedded preview can't, being nested in the detail page's own scroll view).
///
/// Shares the per-apiary filter scope (keyed by [apiaryId]) with the detail
/// page's embedded section, so a filter set in one carries over to the other.
/// `showApiary: false` — the apiary is the whole screen's context already,
/// same as the embedded section.
class ApiaryActivitiesScreen extends ConsumerWidget {
  const ApiaryActivitiesScreen({required this.apiaryId, super.key});

  final String apiaryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final type = ref.watch(activityTypeFilterProvider(apiaryId));
    final dateRange = ref.watch(activityDateRangeFilterProvider(apiaryId));
    final viewModel = ref.watch(
      activitiesViewModelProvider((scope: apiaryId, apiaryId: apiaryId)),
    );
    // The apiary name titles the screen (there's no per-row apiary label here,
    // unlike #43's cross-apiary tab). Falls back to the generic activities
    // title while the narrow per-id watch is still resolving.
    final apiary = ref.watch(apiaryByIdProvider(apiaryId)).value;

    return Scaffold(
      appBar: AppBar(title: Text(apiary?.name ?? l10n.activitiesTitle)),
      body: Column(
        children: [
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
          Expanded(
            child: ActivityListView(
              viewModel: viewModel,
              emptyText: l10n.apiaryActivitiesEmpty,
            ),
          ),
        ],
      ),
    );
  }
}
