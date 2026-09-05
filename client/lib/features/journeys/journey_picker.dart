import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../organization/organization_repository.dart';
import 'journey_matching.dart';
import 'journey_status.dart';
import 'journeys_repository.dart';

/// Live candidate journeys for one (apiary, activity type) pair (#46, FR-JO-1,
/// D-21) — the picker's data source. Family-keyed + autoDispose, mirroring
/// [activitiesByApiaryProvider]'s own per-key live-query convention: opening
/// the picker for a different apiary/type never reuses a stale subscription.
final journeyMatchesProvider = StreamProvider.autoDispose
    .family<List<Journey>, ({String apiaryId, String activityType})>((
      ref,
      args,
    ) async* {
      final repo = await ref.watch(journeysRepositoryProvider.future);
      final org = await ref.watch(organizationProvider.future);
      yield* repo.watchMatching(
        apiaryId: args.apiaryId,
        activityType: args.activityType,
        organizationId: org?.id,
      );
    });

/// Live relaxed candidate journeys for one (apiary, activity type) pair
/// (#440, D-31) — the data source for the picker's "attach to a journey that
/// didn't plan this apiary" toggle: open, type-matching journeys whose plan
/// does NOT include this apiary. Family-keyed + autoDispose, mirroring
/// [journeyMatchesProvider]'s own per-key live-query convention.
final journeyUnplannedMatchesProvider = StreamProvider.autoDispose
    .family<List<Journey>, ({String apiaryId, String activityType})>((
      ref,
      args,
    ) async* {
      final repo = await ref.watch(journeysRepositoryProvider.future);
      final org = await ref.watch(organizationProvider.future);
      yield* repo.watchTypeMatchingUnplanned(
        apiaryId: args.apiaryId,
        activityType: args.activityType,
        organizationId: org?.id,
      );
    });

/// The result of a picker session (#46 AC: deselect / switch / create-new),
/// returned by [showJourneyPickerSheet]. `null` (no outcome at all) means the
/// sheet was dismissed without a choice — the caller's current selection is
/// left exactly as it was.
sealed class JourneyPickerOutcome {
  const JourneyPickerOutcome();
}

/// The user explicitly chose "no journey" (deselect).
class JourneyPickerNone extends JourneyPickerOutcome {
  const JourneyPickerNone();
}

/// The user picked an existing journey (open or closed — the confirm warning
/// for a closed one is enforced at SAVE time by the caller, not here).
class JourneyPickerSelected extends JourneyPickerOutcome {
  const JourneyPickerSelected(
    this.journeyId, {
    this.addCurrentApiaryToPlan = false,
  });
  final String journeyId;

  /// True only when the journey was chosen from the #440/D-31 "attach to a
  /// journey that didn't plan this apiary" relaxed list — the caller must
  /// then add the current apiary to this journey's plan on save
  /// ([JourneysRepository.addApiaryToPlan]). False for every ordinary
  /// planned-apiary match (open or closed): those already plan the apiary, so
  /// growing the plan would be a no-op at best and, on edit, could wrongly
  /// re-add an apiary the user had removed from the plan — so plan-growth is
  /// scoped strictly to this deliberate relaxed pick.
  final bool addCurrentApiaryToPlan;
}

/// The user tapped the inline create-new-journey shortcut — the caller opens
/// [showJourneyQuickCreateSheet] next (kept as a separate step/file so each
/// sheet stays independently simple/testable, journey_quick_create_sheet.dart's
/// own doc explains the split).
class JourneyPickerCreateNew extends JourneyPickerOutcome {
  const JourneyPickerCreateNew();
}

/// Opens the journey picker as a modal bottom sheet scoped to [apiaryId] +
/// [activityType] (D-21's entire matching rule) — the AC's "switch to a
/// different matching open journey", "deselect", and "show hidden [closed]
/// journeys" toggle all live here. [currentJourneyId] highlights the
/// currently-attached journey (if any) so the sheet opens showing what's
/// already selected, not always defaulting to nothing.
Future<JourneyPickerOutcome?> showJourneyPickerSheet(
  BuildContext context, {
  required String apiaryId,
  required String activityType,
  required String? currentJourneyId,
}) {
  return showModalBottomSheet<JourneyPickerOutcome>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _JourneyPickerSheet(
      apiaryId: apiaryId,
      activityType: activityType,
      currentJourneyId: currentJourneyId,
    ),
  );
}

class _JourneyPickerSheet extends ConsumerStatefulWidget {
  const _JourneyPickerSheet({
    required this.apiaryId,
    required this.activityType,
    required this.currentJourneyId,
  });

  final String apiaryId;
  final String activityType;
  final String? currentJourneyId;

  @override
  ConsumerState<_JourneyPickerSheet> createState() =>
      _JourneyPickerSheetState();
}

class _JourneyPickerSheetState extends ConsumerState<_JourneyPickerSheet> {
  bool _showHidden = false;
  // #440/D-31: distinct from _showHidden (which reveals CLOSED planned
  // matches) — this reveals OPEN journeys that did NOT plan this apiary,
  // still filtered to the matching activity type. Opt-in; off by default so
  // the planned-first view is unchanged.
  bool _showUnplanned = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final matchesAsync = ref.watch(
      journeyMatchesProvider((
        apiaryId: widget.apiaryId,
        activityType: widget.activityType,
      )),
    );
    final unplannedAsync = ref.watch(
      journeyUnplannedMatchesProvider((
        apiaryId: widget.apiaryId,
        activityType: widget.activityType,
      )),
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          BrandDimens.gutter,
          BrandDimens.gutter,
          BrandDimens.gutter,
          24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(l10n.journeyPickerTitle),
            const SizedBox(height: 8),
            Flexible(
              child: matchesAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (err, _) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(l10n.journeyPickerError('$err')),
                ),
                data: (matches) {
                  final candidates = splitJourneyCandidates(matches);
                  // The relaxed set is a secondary, opt-in affordance: a
                  // transient load/error in its own live query must never
                  // block the main picker, so fall back to an empty list
                  // rather than surfacing its own loading/error UI.
                  final unplanned = unplannedPickerCandidates(
                    unplannedAsync.value ?? const [],
                    planned: candidates.open,
                  );
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _NoJourneyTile(
                          selected: widget.currentJourneyId == null,
                          onTap: () =>
                              Navigator.of(context)
                                  .pop(const JourneyPickerNone()),
                        ),
                        if (candidates.open.isEmpty && !_showHidden)
                          Padding(
                            key: const Key('journey-picker-no-matches'),
                            padding: const EdgeInsets.symmetric(
                              vertical: 16,
                              horizontal: 4,
                            ),
                            child: Text(
                              l10n.journeyPickerNoOpenMatches,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        for (final journey in candidates.open)
                          _JourneyTile(
                            journey: journey,
                            selected: journey.id == widget.currentJourneyId,
                            onTap: () =>
                                Navigator.of(context)
                                    .pop(JourneyPickerSelected(journey.id)),
                          ),
                        if (candidates.closed.isNotEmpty) ...[
                          Divider(color: context.brand.cardBorder),
                          SwitchListTile(
                            key: const Key('journey-picker-show-hidden-toggle'),
                            title: Text(l10n.journeyPickerShowHiddenToggle),
                            value: _showHidden,
                            onChanged: (v) => setState(() => _showHidden = v),
                          ),
                          if (_showHidden)
                            for (final journey in candidates.closed)
                              _JourneyTile(
                                journey: journey,
                                selected: journey.id == widget.currentJourneyId,
                                onTap: () =>
                                    Navigator.of(context)
                                        .pop(JourneyPickerSelected(journey.id)),
                              ),
                        ],
                        if (unplanned.isNotEmpty) ...[
                          Divider(color: context.brand.cardBorder),
                          SwitchListTile(
                            key: const Key(
                              'journey-picker-show-unplanned-toggle',
                            ),
                            title: Text(l10n.journeyPickerShowUnplannedToggle),
                            value: _showUnplanned,
                            onChanged: (v) =>
                                setState(() => _showUnplanned = v),
                          ),
                          if (_showUnplanned)
                            for (final journey in unplanned)
                              _JourneyTile(
                                journey: journey,
                                selected: journey.id == widget.currentJourneyId,
                                addsApiaryToPlan: true,
                                onTap: () => Navigator.of(context).pop(
                                  JourneyPickerSelected(
                                    journey.id,
                                    addCurrentApiaryToPlan: true,
                                  ),
                                ),
                              ),
                        ],
                        Divider(color: context.brand.cardBorder),
                        _CreateJourneyTile(
                          onTap: () =>
                              Navigator.of(context)
                                  .pop(const JourneyPickerCreateNew()),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "No journey" option — always the first row, so deselecting is never
/// harder to reach than picking one (#46 AC: "the user can deselect the
/// pre-filled journey").
class _NoJourneyTile extends StatelessWidget {
  const _NoJourneyTile({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: l10n.journeyPickerNoneOption,
      child: ExcludeSemantics(
        child: _PickerRow(
          rowKey: const Key('journey-picker-none-option'),
          icon: selected ? Icons.radio_button_checked : Icons.radio_button_off,
          iconColor: selected
              ? theme.colorScheme.tertiary
              : theme.colorScheme.onSurfaceVariant,
          title: l10n.journeyPickerNoneOption,
          onTap: onTap,
        ),
      ),
    );
  }
}

/// One branded picker row — the shared shape behind the "no journey",
/// per-journey and create-new options: a full [kMinTapTarget]-tall ink row
/// with a leading state icon, the option's label, and an optional trailing
/// badge. Replaces the three files-worth of near-identical [ListTile]s these
/// options used to each build, so the sheet's rows pick up the brand type
/// scale/colours in one place.
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.rowKey,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.onTap,
    this.trailing,
  });

  final Key rowKey;
  final IconData icon;
  final Color iconColor;
  final String title;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: rowKey,
        borderRadius: BrandDimens.borderCard,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTapTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: iconColor),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontFamily: AppTheme.bodyFontFamily,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 10), trailing!],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _JourneyTile extends StatelessWidget {
  const _JourneyTile({
    required this.journey,
    required this.selected,
    required this.onTap,
    this.addsApiaryToPlan = false,
  });

  final Journey journey;
  final bool selected;
  final VoidCallback onTap;

  /// #440/D-31: true for a row in the picker's "attach to a journey that
  /// didn't plan this apiary" relaxed list. Gives the row a DISTINCT
  /// screen-reader label and visible badge disclosing that picking it also
  /// adds the current apiary to the journey's plan — the same per-row
  /// disclosure a closed journey gets, so neither a sighted nor an assistive
  /// user has to infer the side effect from which toggle they opened. Never
  /// combined with a closed journey (the relaxed list is open-only), so the
  /// two disclosures are mutually exclusive.
  final bool addsApiaryToPlan;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final closed = journey.status == journeyStatusClosed;
    final String label;
    final String? badgeText;
    if (closed) {
      label = l10n.journeyPickerClosedOptionSemanticLabel(journey.name);
      badgeText = l10n.journeyStatusClosedLabel;
    } else if (addsApiaryToPlan) {
      label = l10n.journeyPickerUnplannedOptionSemanticLabel(journey.name);
      badgeText = l10n.journeyPickerAddsApiaryBadge;
    } else {
      label = journey.name;
      badgeText = null;
    }
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: ExcludeSemantics(
        child: _PickerRow(
          rowKey: Key('journey-picker-option-${journey.id}'),
          icon: selected ? Icons.radio_button_checked : Icons.radio_button_off,
          iconColor: selected
              ? theme.colorScheme.tertiary
              : theme.colorScheme.onSurfaceVariant,
          title: journey.name,
          trailing: badgeText == null ? null : _PickerBadge(text: badgeText),
          onTap: onTap,
        ),
      ),
    );
  }
}

/// A small pill badge shown at the trailing edge of a picker row — the
/// closed-journey status marker (D-21) and the #440/D-31 "adds this apiary to
/// the plan" disclosure share this one shape so both read identically.
class _PickerBadge extends StatelessWidget {
  const _PickerBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(BrandDimens.radiusBadge),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// The inline create-new-journey shortcut (#46 AC) — pops
/// [JourneyPickerCreateNew] so the CALLER opens
/// journey_quick_create_sheet.dart next (this sheet's own doc explains why
/// that's a separate step/file rather than swapping content in place here).
class _CreateJourneyTile extends StatelessWidget {
  const _CreateJourneyTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: l10n.journeyPickerCreateNewAction,
      child: ExcludeSemantics(
        child: _PickerRow(
          rowKey: const Key('journey-picker-create-new-option'),
          icon: Icons.add_circle_outline,
          iconColor: theme.colorScheme.tertiary,
          title: l10n.journeyPickerCreateNewAction,
          onTap: onTap,
        ),
      ),
    );
  }
}
