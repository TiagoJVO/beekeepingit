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

class _RejectedTile extends ConsumerWidget {
  const _RejectedTile({required this.op});

  final RejectedOp op;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    final entityLabel = switch (op.entityType) {
      apiaryCounterEntityType => l10n.syncNeedsFixCounterLabel,
      _ => l10n.syncNeedsFixApiaryLabel,
    };
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
                      Text(entityLabel, style: theme.textTheme.titleSmall),
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
                  onPressed: () => _dismiss(ref),
                  child: Text(l10n.syncNeedsFixDismissAction),
                ),
                const SizedBox(width: 4),
                FilledButton.tonalIcon(
                  key: Key('needs-fix-fix-${op.id}'),
                  onPressed: () => context.goNamed(
                    'apiaryEdit',
                    pathParameters: {'id': op.fixApiaryId},
                  ),
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

  Future<void> _dismiss(WidgetRef ref) async {
    final repo = await ref.read(syncRejectedRepositoryProvider.future);
    await repo.dismiss(op.id);
  }
}
