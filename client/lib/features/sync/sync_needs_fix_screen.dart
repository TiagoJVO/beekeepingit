import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/sync/powersync_schema.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_widgets.dart';
import 'sync_rejected_repository.dart';

/// The **needs-fix list** (sync.md §8 notify-and-fix, D-12, EPIC-06 #7): the
/// offline writes the server permanently rejected, retained in the local
/// dead-letter (powersync_connector.dart) so the user can recover them rather
/// than lose them. Each row shows what was rejected and why, with **Fix**
/// (deep-link to the offending apiary's edit screen — correct and re-save
/// queues a fresh, valid op) and **Dismiss** (give up on that edit). A fixed
/// entry clears itself when the corrected re-save uploads (the connector's
/// clear-on-success); Dismiss is for edits the user decides to abandon.
///
/// Mirrors `apiaries_list_screen.dart`'s AsyncValue-driven list + empty state.
///
/// **Fix routing (#379):** apiary/apiary_counter rejections deep-link to the
/// apiary edit screen (unchanged); journey/todo rejections deep-link to their
/// OWN edit screen (`op.fixApiaryId` doubles as their own id for every
/// non-counter entity type — see `RejectedOp.fixApiaryId`'s doc);
/// journey_plan_item has no edit screen of its own, so it routes to the
/// owning journey's detail screen (`op.journeyId`, read from the rejected
/// op's payload) with a `/journeys` fallback if that's unavailable; activity
/// routes to the Activities tab root rather than attempting the two-id
/// `activityEdit` route (`:id` + `:activityId`), which would need a local
/// lookup this screen doesn't have a reliable source for once the local
/// activity row may itself be gone — see [_navigateToFix].
class SyncNeedsFixScreen extends ConsumerWidget {
  const SyncNeedsFixScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final rejected = ref.watch(syncRejectedOpsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('needs-fix-back-button'),
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/account'),
        ),
        title: Text(l10n.syncNeedsFixTitle),
      ),
      body: rejected.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.syncNeedsFixLoadError('$err')),
          ),
        ),
        data: (ops) {
          if (ops.isEmpty) {
            return EmptyState(
              key: const Key('needs-fix-empty'),
              message: l10n.syncNeedsFixEmpty,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: ops.length,
            separatorBuilder: (_, __) => const SizedBox(height: 4),
            itemBuilder: (context, i) => _RejectedTile(op: ops[i]),
          );
        },
      ),
    );
  }
}

class _RejectedTile extends ConsumerStatefulWidget {
  const _RejectedTile({required this.op});

  final RejectedOp op;

  @override
  ConsumerState<_RejectedTile> createState() => _RejectedTileState();
}

class _RejectedTileState extends ConsumerState<_RejectedTile> {
  /// Guards against a double-tap firing [_dismiss] twice while the first
  /// call is still in flight (#380) — this row isn't built from the shared
  /// [PrimaryActionButton]/[SecondaryActionButton] family (a plain
  /// [TextButton], to keep this compact dismiss/fix row layout), so it needs
  /// its own local in-flight guard rather than inheriting theirs.
  bool _dismissing = false;

  @override
  Widget build(BuildContext context) {
    final op = widget.op;
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final entityLabel = switch (op.entityType) {
      apiaryCounterEntityType => l10n.syncNeedsFixCounterLabel,
      activityEntityType => l10n.syncNeedsFixActivityLabel,
      journeyEntityType => l10n.syncNeedsFixJourneyLabel,
      journeyPlanItemEntityType => l10n.syncNeedsFixJourneyPlanLabel,
      todoEntityType => l10n.syncNeedsFixTodoLabel,
      // apiaryEntityType, and the fallback for anything unrecognized.
      _ => l10n.syncNeedsFixApiaryLabel,
    };
    final title = op.displayName == null
        ? entityLabel
        : l10n.syncNeedsFixTitleWithName(entityLabel, op.displayName!);
    final message = op.primaryMessage.isNotEmpty
        ? op.primaryMessage
        : l10n.syncNeedsFixGenericProblem;

    return Card(
      key: Key('needs-fix-${op.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.sync_problem_outlined,
                  color: theme.colorScheme.error,
                  size: 22,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(message, style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: Key('needs-fix-dismiss-${op.id}'),
                  onPressed: _dismissing ? null : _dismiss,
                  child: Text(l10n.syncNeedsFixDismissAction),
                ),
                const SizedBox(width: 4),
                FilledButton.tonalIcon(
                  key: Key('needs-fix-fix-${op.id}'),
                  onPressed: () => _navigateToFix(context, op),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: Text(l10n.syncNeedsFixFixAction),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    setState(() => _dismissing = true);
    try {
      final repo = await ref.read(syncRejectedRepositoryProvider.future);
      await repo.dismiss(widget.op.id);
    } finally {
      if (mounted) setState(() => _dismissing = false);
    }
  }
}

/// Where the "Fix" action sends each entity type (#379's fix plan item 5 —
/// see [SyncNeedsFixScreen]'s own class doc for the full rationale). Extracted
/// as a top-level function (not a method) so the routing decision itself is
/// easy to reason about independent of the tile's widget state.
void _navigateToFix(BuildContext context, RejectedOp op) {
  switch (op.entityType) {
    case journeyEntityType:
      // fixApiaryId doubles as the journey's own id for this entity type
      // (RejectedOp.fixApiaryId's doc).
      context.goNamed('journeyEdit', pathParameters: {'id': op.fixApiaryId});
    case journeyPlanItemEntityType:
      final journeyId = op.journeyId;
      if (journeyId == null) {
        // No edit screen of its own, and the owning journey id wasn't
        // available (a pre-existing dead-letter row, or a malformed
        // payload) — land on the Journeys tab rather than a dead end.
        context.go('/journeys');
      } else {
        context.goNamed('journeyDetail', pathParameters: {'id': journeyId});
      }
    case todoEntityType:
      // fixApiaryId doubles as the todo's own id for this entity type too.
      context.goNamed('todoEdit', pathParameters: {'id': op.fixApiaryId});
    case activityEntityType:
      // activityEdit needs BOTH the owning apiary id and the activity id —
      // this screen has no reliable local source for the former once the
      // activity row may itself be gone (the "simplest robust first cut"
      // the fix plan calls for). The Activities tab lets the user find and
      // fix the record themselves.
      context.go('/activities');
    default:
      // apiaryEntityType and apiaryCounterEntityType: unchanged behavior —
      // fixApiaryId is the owning apiary's id for both.
      context.goNamed('apiaryEdit', pathParameters: {'id': op.fixApiaryId});
  }
}
