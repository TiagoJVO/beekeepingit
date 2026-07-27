import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../members/members_repository.dart';
import '../profile/profile_repository.dart';
import 'history_display.dart';
import 'history_repository.dart';

/// The per-entity change-history timeline (#60, FR-HIS-1, history.md §8),
/// embedded on an entity's own detail screen — the AC's "per-entity timeline
/// on that entity's detail screen", not a separate destination.
///
/// Entity-agnostic on purpose: it takes a bare [entityType]/[entityId] pair
/// rather than an apiary or an activity, so the same widget serves both of
/// #60's entities today and whatever attaches next (#315's journeys, and the
/// todo history EPIC-05 records) with no new UI. That is exactly what #60's
/// own note anticipates — "Todo history reuses the same view component".
///
/// Renders **offline** from the local synced logs; a device with no local
/// slice falls back to the owning service's REST timeline
/// ([entityHistoryProvider]). Both look identical here by construction.
///
/// Like the activities section it sits beside, the embedded preview is
/// capped at [_previewLimit] and defers the rest to a full, properly
/// virtualized screen: this list `shrinkWrap`s inside the detail page's own
/// `SingleChildScrollView`, so it builds every row up front and cannot
/// lazily virtualize. An audit log only ever grows, which makes that cap
/// more load-bearing here than it is for activities.
class HistorySection extends ConsumerWidget {
  const HistorySection({
    super.key,
    required this.entityType,
    required this.entityId,
    required this.onViewAll,
  });

  /// How many entries the embedded preview renders before deferring to the
  /// full history screen.
  static const _previewLimit = 5;

  final String entityType;
  final String entityId;
  final VoidCallback onViewAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final historyAsync = ref.watch(
      entityHistoryProvider(
        HistoryTarget(entityType: entityType, entityId: entityId),
      ),
    );

    return Container(
      key: const Key('history-section'),
      decoration: BoxDecoration(
        color: context.brand.cardColor,
        border: Border.all(color: context.brand.cardBorder),
        borderRadius: BrandDimens.borderCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            l10n.historySectionTitle,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          ),
          historyAsync.when(
            // A bounded, non-spinner loading state: the local query resolves
            // in a frame or two, and a spinner inside a shrink-wrapped
            // section both janks the page and (per apiary_detail_screen_test's
            // own note) makes `pumpAndSettle` hang in widget tests.
            loading: () => const SizedBox.shrink(),
            error: (err, _) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Text(
                l10n.historyError('$err'),
                key: const Key('history-error'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
            data: (entries) => HistoryTimelineList(
              entries: entries,
              shrinkWrap: true,
              maxItems: _previewLimit,
              onViewAll: onViewAll,
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// The timeline itself — shared verbatim by the capped detail-screen
/// [HistorySection] and the full history screen, so the two can never drift
/// in how an entry reads.
///
/// [shrinkWrap] false (the full screen) gives a properly virtualized list;
/// true (the embedded preview) builds [maxItems] rows up front and shows a
/// "view all" link when more exist.
class HistoryTimelineList extends ConsumerWidget {
  const HistoryTimelineList({
    super.key,
    required this.entries,
    this.shrinkWrap = false,
    this.maxItems,
    this.onViewAll,
  });

  final List<HistoryEntry> entries;
  final bool shrinkWrap;
  final int? maxItems;
  final VoidCallback? onViewAll;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    if (entries.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        child: Text(
          l10n.historyEmpty,
          key: const Key('history-empty'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    // The roster is best-effort and online-only: `.value ?? {}` (never
    // `.when`) so an unresolved actor degrades to a short id fragment rather
    // than blocking the whole timeline behind a spinner — the same idiom
    // activity_list_widgets.dart uses for the identical lookup.
    final memberNames =
        ref.watch(memberNamesProvider).value ?? const <String, String>{};
    final currentUserId = ref.watch(profileProvider).value?.id;

    final cap = maxItems;
    final visible = (cap != null && entries.length > cap)
        ? entries.sublist(0, cap)
        : entries;
    final hasMore = visible.length < entries.length;

    final list = ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.zero,
      itemCount: visible.length,
      itemBuilder: (context, i) => _HistoryEntryTile(
        entry: visible[i],
        currentUserId: currentUserId,
        memberNames: memberNames,
      ),
    );

    // The full-screen case returns the scrollable BARE — wrapping a
    // non-shrink-wrapped ListView in a Column hands the viewport unbounded
    // height and throws at layout. Only the embedded, shrink-wrapped preview
    // needs the surrounding Column, and only it can ever have a "view all"
    // link (the full screen already shows everything).
    if (!shrinkWrap) return list;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        list,
        if (hasMore && onViewAll != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('history-view-all-button'),
              onPressed: onViewAll,
              child: Text(l10n.historyViewAllAction),
            ),
          ),
      ],
    );
  }
}

/// One timeline row: what changed, which fields, who, and when.
///
/// The three visually-separate lines are collapsed into a single
/// [Semantics] label (WCAG 2.2 AA) so a screen reader announces the entry
/// as one coherent sentence instead of three orphaned fragments — the row
/// is not interactive, so it carries no button/tap semantics.
class _HistoryEntryTile extends StatelessWidget {
  const _HistoryEntryTile({
    required this.entry,
    required this.currentUserId,
    required this.memberNames,
  });

  final HistoryEntry entry;
  final String? currentUserId;
  final Map<String, String> memberNames;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final event = historyEventLabel(l10n, entry.kind);
    final actor = historyActorText(
      l10n,
      entry.actorUserId,
      currentUserId,
      memberNames: memberNames,
    );
    final timestamp = LocaleFormatting.of(context).dateTime(entry.recordedAt);
    final changed = historyChangedFieldsText(l10n, entry);
    final detail = historyDetailText(l10n, entry);

    return Semantics(
      label: l10n.historyEntrySemanticLabel(event, actor, timestamp),
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _iconFor(entry.kind),
              size: 20,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(event, style: theme.textTheme.bodyLarge),
                  if (changed != null)
                    Text(
                      changed,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  if (detail != null)
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  Text(
                    '$actor · $timestamp',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _iconFor(HistoryEventKind kind) => switch (kind) {
    HistoryEventKind.created => Icons.add_circle_outline,
    HistoryEventKind.updated => Icons.edit_outlined,
    HistoryEventKind.deleted => Icons.delete_outline,
    HistoryEventKind.superseded => Icons.sync_problem_outlined,
    HistoryEventKind.unknown => Icons.history,
  };
}
