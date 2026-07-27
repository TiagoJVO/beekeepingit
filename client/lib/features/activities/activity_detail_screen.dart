import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/sync/powersync_schema.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../history/history_section.dart';
import '../profile/profile_repository.dart';
import 'activities_repository.dart';
import 'activity_display.dart';
import 'activity_types.dart';
import 'add_activity_screen.dart' show DeleteActivityConfirmDialog;

/// Read-focused activity detail (#310, FR-AC-3/5/6, FR-TEN-2): the activity's
/// type, date, every populated per-type attribute and its performer
/// (attribution), read-only — mirroring apiary_detail_screen.dart's own
/// dedicated view screen, distinct from the edit form (add_activity_screen.
/// dart). Reachable by tapping a row in either the per-apiary Activities
/// section (apiary detail) or the main all-apiaries Activities tab (both use
/// the shared _ActivityTile in activity_list_widgets.dart). Offers Edit
/// (routes to the existing edit form) and Delete (the existing confirm
/// dialog), completing the tappable list-row -> detail -> edit/delete path
/// deferred when #40/#41 shipped the edit/delete surfaces reachable by direct
/// route only.
///
/// Offline-first (FR-OF-1): reads entirely from the local synced set via
/// [activityByIdProvider] (a live per-id watch, activities_repository.dart) —
/// no network. A narrow per-id watch (not the whole-org list) mirrors
/// apiary_detail_screen.dart's own [apiaryByIdProvider] choice so an unrelated
/// activity write never rebuilds this screen.
class ActivityDetailScreen extends ConsumerStatefulWidget {
  const ActivityDetailScreen({
    required this.apiaryId,
    required this.activityId,
    super.key,
  });

  final String apiaryId;
  final String activityId;

  @override
  ConsumerState<ActivityDetailScreen> createState() =>
      _ActivityDetailScreenState();
}

class _ActivityDetailScreenState extends ConsumerState<ActivityDetailScreen> {
  // Shared in-flight flag for the Delete action. Owned here (not in the delete
  // button alone) so the Edit FAB is disabled for the SAME window a delete is
  // running: otherwise Edit could open the edit form for a row that's
  // concurrently being removed, and the edit's `UPDATE ... WHERE id = ?` would
  // silently affect zero rows while still reporting success.
  bool _busy = false;

  /// Delete confirmation (#310 AC: Delete with the existing confirmation step)
  /// — reuses [DeleteActivityConfirmDialog] + [ActivitiesRepository.delete]
  /// exactly as add_activity_screen.dart's own delete does, including the
  /// post-await `mounted` re-checks.
  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const DeleteActivityConfirmDialog(),
    );
    if (!mounted) return;
    if (confirmed != true) return;
    await _delete();
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(activitiesRepositoryProvider.future);
      await repo.delete(widget.activityId);
      if (!mounted) return;
      context.go('/apiaries/${widget.apiaryId}');
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.activityDeleteSuccess)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.activityDeleteError('$e'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final activityAsync = ref.watch(activityByIdProvider(widget.activityId));

    return Scaffold(
      body: activityAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.activitiesError('$err')),
          ),
        ),
        data: (activity) {
          if (activity == null) {
            // Deleted/not found (a stale deep link, or the just-confirmed
            // delete above) — nothing sensible to render; bounce back to the
            // owning apiary rather than show a blank detail page, mirroring
            // apiary_detail_screen.dart's own null-bounce.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/apiaries/${widget.apiaryId}');
            });
            return const SizedBox.shrink();
          }
          return _ActivityDetailBody(
            apiaryId: widget.apiaryId,
            activity: activity,
            busy: _busy,
            onDelete: _confirmDelete,
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('activity-detail-edit-button'),
        heroTag: 'activity-detail-edit-button',
        // Disabled while a delete is in flight (see [_busy]).
        onPressed: _busy
            ? null
            : () => context.go(
                '/apiaries/${widget.apiaryId}/activities/${widget.activityId}/edit',
              ),
        icon: const Icon(Icons.edit_outlined),
        label: Text(l10n.editActivityAction),
      ),
    );
  }
}

class _ActivityDetailBody extends ConsumerWidget {
  const _ActivityDetailBody({
    required this.apiaryId,
    required this.activity,
    required this.busy,
    required this.onDelete,
  });

  final String apiaryId;
  final Activity activity;
  final bool busy;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final brand = context.brand;
    final currentUserId = ref.watch(profileProvider).value?.id;

    final typeLabel = activityTypeLabel(l10n, activity.type) ?? activity.type;
    final dateText = LocaleFormatting.of(context).date(activity.occurredAtDate);
    final attribution = activityAttributionText(l10n, activity, currentUserId);
    final rows = activityDetailRows(l10n, activity);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HeroCard(
                key: const Key('activity-detail-header'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      typeLabel,
                      style: TextStyle(
                        fontFamily: AppTheme.displayFontFamily,
                        fontWeight: FontWeight.w600,
                        fontSize: 24,
                        color: brand.onHeroSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _HeaderRow(
                      icon: Icons.event_outlined,
                      label: l10n.activityOccurredAtLabel,
                      value: dateText,
                    ),
                    const SizedBox(height: 8),
                    _HeaderRow(
                      key: const Key('activity-detail-attribution'),
                      icon: Icons.person_outline,
                      label: l10n.activityPerformedByLabel,
                      value: attribution,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (rows.isEmpty)
                BrandCard(
                  key: const Key('activity-detail-no-attributes'),
                  child: Text(
                    l10n.activityNoAttributesSummary,
                    style: theme.textTheme.bodyMedium,
                  ),
                )
              else
                BrandCard(
                  key: const Key('activity-detail-attributes'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SectionHeader(l10n.activityDetailAttributesHeader),
                      const SizedBox(height: 8),
                      for (final row in rows) ...[
                        _AttributeRow(label: row.label, value: row.value),
                        if (row != rows.last) const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),
              const SizedBox(height: 14),
              // This activity's change history (#60, FR-HIS-1, history.md
              // §8) — same per-entity timeline component the apiary detail
              // screen embeds, pointed at this entity instead. Sits after
              // the content cards and before the destructive delete action.
              HistorySection(
                entityType: activityEntityType,
                entityId: activity.id,
                onViewAll: () => context.go(
                  '/apiaries/${activity.apiaryId}/activities/${activity.id}/history',
                ),
              ),
              const SizedBox(height: 24),
              SecondaryActionButton(
                key: const Key('activity-detail-delete-button'),
                label: l10n.deleteActivity,
                icon: Icons.delete_outline,
                destructive: true,
                busy: busy,
                onPressed: onDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A labeled row inside the primary-container header (date, attribution) —
/// icon + "Label: value", tinted for the container's onPrimaryContainer
/// foreground.
class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.icon,
    required this.label,
    required this.value,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = context.brand.onHeroSurfaceMuted;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$label: $value',
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// One read-only attribute: its field label above the stored value, reusing
/// the same `.arb` labels the add/edit form shows (activity_display.dart's
/// [activityDetailRows]).
class _AttributeRow extends StatelessWidget {
  const _AttributeRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Label + value announce as a single "Label: value" stop for a
    // screen-reader user, rather than two disconnected swipes — matching
    // _HeaderRow's own single-node treatment.
    return Semantics(
      label: '$label: $value',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(value, style: theme.textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}
