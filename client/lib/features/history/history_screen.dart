import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/gen/app_localizations.dart';
import 'history_repository.dart';
import 'history_section.dart';

/// The full per-entity history timeline (#60, FR-HIS-1): every recorded
/// change for one entity, reached from the detail screen's capped
/// [HistorySection] once it hits its preview limit — the same
/// preview-then-full-screen split apiary_activities_screen.dart already
/// establishes for #42's activities.
///
/// Its [HistoryTimelineList] is NOT `shrinkWrap`ped, so it lazily
/// virtualizes however many entries an entity has accumulated. That matters
/// more here than for activities: an audit log is append-only and only ever
/// grows, and the whole per-org log replicates to the device (Sync Rules
/// can't express a LIMIT — infra/helm/beekeepingit/charts/powersync/
/// values.yaml).
///
/// Entity-agnostic like the section it shares its list with: one screen and
/// one route shape serve every entity type, so #315's journeys and EPIC-05's
/// todos need no screen of their own.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({
    required this.entityType,
    required this.entityId,
    super.key,
  });

  final String entityType;
  final String entityId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final historyAsync = ref.watch(
      entityHistoryProvider(
        HistoryTarget(entityType: entityType, entityId: entityId),
      ),
    );

    return Scaffold(
      appBar: AppBar(title: Text(l10n.historyScreenTitle)),
      body: historyAsync.when(
        loading: () =>
            const Center(child: CircularProgressIndicator.adaptive()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.historyError('$err'),
              key: const Key('history-screen-error'),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (entries) => HistoryTimelineList(entries: entries),
      ),
    );
  }
}
