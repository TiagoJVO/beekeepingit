import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/content_column.dart';
import '../../l10n/gen/app_localizations.dart';
import '../apiaries/apiaries_repository.dart';
import 'activities_repository.dart';
import 'activity_filters.dart';
import 'activity_list_widgets.dart';

/// The main Activities tab (#43, FR-AC-6): every activity across every
/// apiary in the caller's organization, offline-first over the local synced
/// set ([activitiesStreamProvider] — see activities_repository.dart's own
/// doc on how FR-TEN-2 scoping is enforced), filterable by type and date
/// range (combinable, #43 AC), showing which apiary each row belongs to
/// (unlike #42's embedded per-apiary section, where the apiary is already
/// the whole screen's context) and the performing user per row (#44).
///
/// No own AppBar/Scaffold — like ApiariesListScreen, this is the Activities
/// tab's root content within the app shell, which supplies the header.
///
/// Wrapped in a [ContentColumn] (#650): on a wide desktop viewport the
/// filter bar and row list stay within [BrandDimens.maxWidthList] instead of
/// stretching across the whole window — see that constant's own doc comment
/// for why 720, not the narrower [BrandDimens.maxWidthContent], is load-
/// bearing for the activity row's own compact/wide breakpoint.
class ActivitiesListScreen extends ConsumerWidget {
  const ActivitiesListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final type = ref.watch(activityTypeFilterProvider(allActivitiesScope));
    final dateRange = ref.watch(
      activityDateRangeFilterProvider(allActivitiesScope),
    );
    final viewModel = ref.watch(
      activitiesViewModelProvider((scope: allActivitiesScope, apiaryId: null)),
    );
    // Apiary id -> name, to label each row with its apiary (#43 AC). Reuses
    // the same org-scoped local apiaries stream the Apiaries tab itself
    // reads from — no separate fetch.
    final apiaryNames = <String, String>{
      for (final a
          in ref.watch(apiariesStreamProvider).value ?? const <Apiary>[])
        a.id: a.name,
    };

    return ContentColumn(
      child: Column(
        children: [
          ActivityFilterBar(
            type: type,
            dateRange: dateRange,
            onTypeChanged: (v) =>
                ref
                        .read(
                          activityTypeFilterProvider(allActivitiesScope)
                              .notifier,
                        )
                        .state =
                    v,
            onDateRangeChanged: (v) =>
                ref
                        .read(
                          activityDateRangeFilterProvider(allActivitiesScope)
                              .notifier,
                        )
                        .state =
                    v,
          ),
          Expanded(
            child: ActivityListView(
              viewModel: viewModel,
              emptyText: l10n.activitiesEmpty,
              showApiary: true,
              apiaryNameOf: (id) => apiaryNames[id],
            ),
          ),
        ],
      ),
    );
  }
}
