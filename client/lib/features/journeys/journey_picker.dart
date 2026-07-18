import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
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
  const JourneyPickerSelected(this.journeyId);
  final String journeyId;
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

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.journeyPickerTitle, style: theme.textTheme.titleLarge),
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
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _NoJourneyTile(
                          selected: widget.currentJourneyId == null,
                          onTap: () => Navigator.of(
                            context,
                          ).pop(const JourneyPickerNone()),
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
                            onTap: () => Navigator.of(
                              context,
                            ).pop(JourneyPickerSelected(journey.id)),
                          ),
                        if (candidates.closed.isNotEmpty) ...[
                          const Divider(),
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
                                onTap: () => Navigator.of(
                                  context,
                                ).pop(JourneyPickerSelected(journey.id)),
                              ),
                        ],
                        const Divider(),
                        _CreateJourneyTile(
                          onTap: () => Navigator.of(
                            context,
                          ).pop(const JourneyPickerCreateNew()),
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinTapTarget),
        child: ExcludeSemantics(
          child: ListTile(
            key: const Key('journey-picker-none-option'),
            onTap: onTap,
            leading: Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? theme.colorScheme.primary : null,
            ),
            title: Text(l10n.journeyPickerNoneOption),
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
  });

  final Journey journey;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final closed = journey.status == journeyStatusClosed;
    final label = closed
        ? l10n.journeyPickerClosedOptionSemanticLabel(journey.name)
        : journey.name;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinTapTarget),
        child: ExcludeSemantics(
          child: ListTile(
            key: Key('journey-picker-option-${journey.id}'),
            onTap: onTap,
            leading: Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? theme.colorScheme.primary : null,
            ),
            title: Text(journey.name),
            trailing: closed
                ? Chip(
                    label: Text(l10n.journeyStatusClosedLabel),
                    visualDensity: VisualDensity.compact,
                  )
                : null,
          ),
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
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: kMinTapTarget),
        child: ExcludeSemantics(
          child: ListTile(
            key: const Key('journey-picker-create-new-option'),
            onTap: onTap,
            leading: Icon(
              Icons.add_circle_outline,
              color: theme.colorScheme.primary,
            ),
            title: Text(
              l10n.journeyPickerCreateNewAction,
              style: TextStyle(color: theme.colorScheme.primary),
            ),
          ),
        ),
      ),
    );
  }
}
