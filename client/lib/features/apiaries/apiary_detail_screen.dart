import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/sync/powersync_schema.dart';
import '../../core/widgets/actions_speed_dial.dart';
import '../../core/widgets/tap_target.dart';
import '../../core/widgets/unsaved_changes.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../activities/activity_filters.dart';
import '../activities/activity_list_widgets.dart';
import '../history/history_section.dart';
import 'apiaries_repository.dart';
import 'counter_types.dart';

/// Read-focused apiary detail (FR-AP-7, #32): name, location, hive count and
/// notes (FR-AP-8, #196), matching the Melargil prototype's "Apiário
/// detalhe" screen shape — a dedicated view screen, distinct from the edit
/// form (apiary_form_screen.dart). Reachable from the list (list screen's
/// onTap) and, once the map screen lands (parallel #33 work), from there
/// too. Renders gracefully when optional fields (location, notes) are empty
/// (#32 AC). `location` now genuinely reflects the form-set coordinates
/// (#252 wires the form's write path through — this screen's own render
/// logic was already correct, it just had nothing to show before). The
/// optional free-text place label (#252, e.g. "Montargil") renders alongside
/// the coordinates when set. Editing happens via the FAB, which pushes the
/// existing form at `/apiaries/:id/edit`.
class ApiaryDetailScreen extends ConsumerWidget {
  const ApiaryDetailScreen({required this.apiaryId, super.key});

  final String apiaryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // A narrow per-id watch (HIGH finding) rather than the whole-org
    // apiariesStreamProvider: this screen only ever renders ONE apiary, so
    // watching the entire list just to firstWhere() it meant any write to
    // any OTHER apiary/counter in the org re-triggered this screen's full
    // rebuild+rescan. apiaryByIdProvider (apiaries_repository.dart) is a
    // family-keyed StreamProvider mirroring apiaryCountersProvider's
    // existing per-id pattern -- overridable in widget tests the same way.
    final apiaryAsync = ref.watch(apiaryByIdProvider(apiaryId));
    // Read directly (not just inside the `data:` branch below) so the
    // add-todo FAB can gate its own presence on the apiary actually having
    // loaded (#389 kept this gate as-is even though the full form's own
    // apiary picker no longer needs the NAME up front the way #52's
    // quick-create sheet's read-only chip did), without touching the other
    // two FABs' existing unconditional-render behavior.
    final apiary = apiaryAsync.value;

    return Scaffold(
      body: apiaryAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.apiariesError('$err')),
          ),
        ),
        data: (apiary) {
          if (apiary == null) {
            // Deleted/not found (e.g. a stale deep link) — nothing sensible
            // to render; bounce back to the list rather than show a blank
            // detail page.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/apiaries');
            });
            return const SizedBox.shrink();
          }
          return _ApiaryDetailBody(apiary: apiary);
        },
      ),
      // A single "Actions" control (#347, FR-UX-1/FR-UX-2) that expands to the
      // actions valid for this apiary, replacing the previous stack of three
      // FABs. The options are built for the current scope: the add-todo option
      // only joins the list once the apiary has actually loaded — unlike
      // add-activity/edit, which only need [apiaryId].
      floatingActionButton: ActionsSpeedDial(
        actions: [
          // Contextual create-todo entry point (#52, FR-UX-2) — routes to
          // the full create form pre-selecting this apiary via
          // `?apiaryId=` (#389, replacing the old quick-create sheet, whose
          // read-only "For {name}" chip this apiary picker prefill now
          // supersedes).
          if (apiary != null)
            SpeedDialAction(
              key: const Key('apiary-detail-add-todo-button'),
              label: l10n.addTodo,
              icon: Icons.task_alt_outlined,
              onPressed: () => context.go('/todos/new?apiaryId=${apiary.id}'),
            ),
          // Add-activity entry point (#39, FR-AC-2): the natural place to log
          // an activity is right where the apiary itself already is. Only the
          // add flow — the activities LIST is #42/#43's scope.
          SpeedDialAction(
            key: const Key('apiary-detail-add-activity-button'),
            label: l10n.addActivityAction,
            icon: Icons.event_note_outlined,
            onPressed: () => context.go('/apiaries/$apiaryId/activities/new'),
          ),
          SpeedDialAction(
            key: const Key('apiary-detail-edit-button'),
            label: l10n.editApiaryAction,
            icon: Icons.edit_outlined,
            onPressed: () => context.go('/apiaries/$apiaryId/edit'),
          ),
        ],
      ),
    );
  }
}

class _ApiaryDetailBody extends StatelessWidget {
  const _ApiaryDetailBody({required this.apiary});

  final Apiary apiary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HeroCard(
                key: const Key('apiary-detail-header'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      apiary.name,
                      style: TextStyle(
                        fontFamily: AppTheme.displayFontFamily,
                        fontWeight: FontWeight.w600,
                        fontSize: 26,
                        color: context.brand.onHeroSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _LocationRow(apiary: apiary),
                    const SizedBox(height: 16),
                    _CountersSection(apiary: apiary),
                  ],
                ),
              ),
              if (apiary.notes != null && apiary.notes!.trim().isNotEmpty) ...[
                const SizedBox(height: 14),
                Semantics(
                  label: l10n.apiaryNotesLabel,
                  child: NotesCard(
                    key: const Key('apiary-detail-notes'),
                    text: apiary.notes!,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              _ApiaryActivitiesSection(apiaryId: apiary.id),
              const SizedBox(height: 14),
              // This apiary's change history (#60, FR-HIS-1, history.md §8):
              // the per-entity timeline lives ON the entity's detail screen,
              // capped like the activities section above and linking out to
              // the full list for the same virtualization reason.
              HistorySection(
                entityType: apiaryEntityType,
                entityId: apiary.id,
                onViewAll: () => context.go('/apiaries/${apiary.id}/history'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// This apiary's activities (#42, FR-AC-5): filterable by type and date
/// range (combinable), offline over the local synced set — embedded
/// directly on the detail page rather than a separate pushed screen, per
/// #42's own AC ("the apiary detail page lists all activities for that
/// apiary"). Shares [ActivityFilterBar]/[ActivityListView] with #43's main
/// Activities tab (DRY); `showApiary: false` there since this screen IS the
/// apiary context already. [ActivityListView.shrinkWrap]s its list — the
/// outer `SingleChildScrollView` above already owns the page's scrolling, so
/// this section can't also be an unbounded scrollable.
///
/// Because a `shrinkWrap`ped list can't lazily virtualize (it builds every
/// row up front), the embedded preview is capped at [_previewLimit]: over
/// many seasons an apiary accumulates hundreds of activities, and rebuilding
/// all of them on every filter change or sync write is wasteful. Beyond the
/// cap the section links to the full, properly-virtualized per-apiary list
/// (`/apiaries/:id/activities`, apiary_activities_screen.dart) — which still
/// satisfies #42's "lists all activities for that apiary" AC.
class _ApiaryActivitiesSection extends ConsumerWidget {
  const _ApiaryActivitiesSection({required this.apiaryId});

  /// How many activities the embedded preview renders before deferring the
  /// rest to the full per-apiary list.
  static const _previewLimit = 5;

  final String apiaryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final type = ref.watch(activityTypeFilterProvider(apiaryId));
    final dateRange = ref.watch(activityDateRangeFilterProvider(apiaryId));
    final viewModel = ref.watch(
      activitiesViewModelProvider((scope: apiaryId, apiaryId: apiaryId)),
    );

    return Container(
      key: const Key('apiary-detail-activities-section'),
      decoration: BoxDecoration(
        color: context.brand.cardColor,
        border: Border.all(color: context.brand.cardBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(
            l10n.activitiesTitle,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          ),
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
          ActivityListView(
            viewModel: viewModel,
            emptyText: l10n.apiaryActivitiesEmpty,
            shrinkWrap: true,
            maxItems: _previewLimit,
            onViewAll: () => context.go('/apiaries/$apiaryId/activities'),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({required this.apiary});

  final Apiary apiary;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final color = context.brand.onHeroSurfaceMuted;
    // Location (#252): the repository's Apiary model now carries
    // locationLon/locationLat (threaded through the local schema/repository
    // the same way notes was threaded here by #196) — render the formatted
    // coordinates when set, the honest "not set" empty state otherwise. No
    // mini-map here (out of scope for this row — the full map view,
    // apiary_map_screen.dart, is reachable from the list's map toggle).
    final locationText = apiary.hasLocation
        ? l10n.apiaryLocationValue(
            apiary.locationLat!.toStringAsFixed(5),
            apiary.locationLon!.toStringAsFixed(5),
          )
        : l10n.apiaryLocationNotSet;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          key: const Key('apiary-detail-location'),
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.location_on_outlined, size: 17, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                locationText,
                style: theme.textTheme.bodyMedium?.copyWith(color: color),
              ),
            ),
          ],
        ),
        if (apiary.placeLabel != null &&
            apiary.placeLabel!.trim().isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            key: const Key('apiary-detail-place-label'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.place_outlined, size: 17, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  apiary.placeLabel!,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The apiary's typed counters (#256/#346, FR-AP-7, D-20), managed
/// generically over the known set (counter_types.dart) — matching the
/// Melargil prototype's "Apiário detalhe" counters block (tappable value
/// cards + an inline stepper editor + an "add a counter" action):
///
///   - the HIVES counter always displays — 0 when no counter row exists —
///     sourced from [Apiary.hiveCount] (already the counters-backed value,
///     apiaries_repository.dart), so it renders synchronously with the rest
///     of the header and its text/key stay byte-identical to the pre-#256
///     badge (the e2e's "12 hives"/"No hives" assertions);
///   - every OTHER known type renders only when a counter row exists for
///     this apiary ([apiaryCountersProvider]); types this client version has
///     no label for are skipped ([counterValueLabel] returns null). Adding a
///     future countable is a constants-and-strings append — no changes here.
///
/// Every card is tappable to edit its value (#346 AC): tapping opens an
/// inline stepper (−/value/+ with a direct-entry number field) that writes
/// the new value through [ApiariesRepository.setCounter] — an
/// `apiary_counter` op on the offline-sync path, history-tracked server-side
/// (FR-HIS). An "add counter" action opens a type picker over the addable
/// known set (known types minus hive, which is always present, minus types
/// that already have a row) so `UNIQUE(apiary_id, counter_type)` can never be
/// violated. Local UI state only (which card is being edited, its draft
/// value) lives in the widget; the persisted write goes through the
/// repository, keeping business logic out of the widget.
///
/// While the counter rows are still loading (or errored), only the hives
/// card shows — no spinner: the extra cards are progressive enhancement, and
/// the always-on hives card already covers the screen's primary content
/// (also keeps widget tests' pumpAndSettle safe — an indefinite spinner
/// would never settle in the PowerSync-less test environment).
class _CountersSection extends ConsumerStatefulWidget {
  const _CountersSection({required this.apiary});

  final Apiary apiary;

  @override
  ConsumerState<_CountersSection> createState() => _CountersSectionState();
}

class _CountersSectionState extends ConsumerState<_CountersSection> {
  /// The counter type currently open in the inline editor, or null when no
  /// editor is showing. Local UI state — the persisted value lives in the
  /// repository/counter rows, not here.
  String? _editingType;
  final _valueController = TextEditingController();
  bool _saving = false;

  /// The stored value at the moment the editor opened — the baseline
  /// [_maybeCloseEditor] compares the draft against to decide whether
  /// collapsing needs a discard confirmation (#393).
  int _openedValue = 0;

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  void _openEditor(String counterType, int currentValue) {
    setState(() {
      _editingType = counterType;
      _valueController.text = '$currentValue';
      _openedValue = currentValue;
    });
  }

  void _closeEditor() => setState(() => _editingType = null);

  /// Tapping the same counter card again while its editor is open collapses
  /// it (#393) — mirroring the card's role as the editor's own toggle rather
  /// than a one-way "open" action. Prompts for confirmation only when the
  /// draft actually differs from the value the editor opened with; an
  /// unchanged draft (or the freshly-opened add-counter case, whose
  /// [_openedValue] is 0) collapses immediately.
  Future<void> _maybeCloseEditor() async {
    if (_saving) return;
    if (_draftValue == _openedValue) {
      _closeEditor();
      return;
    }
    final discard = await showDiscardChangesDialog(context);
    if (discard && mounted) _closeEditor();
  }

  int get _draftValue {
    final n = int.tryParse(_valueController.text.trim()) ?? 0;
    return n < 0 ? 0 : n;
  }

  void _bumpBy(int delta) {
    final next = (_draftValue + delta).clamp(0, 1 << 30);
    _valueController.text = '$next';
  }

  Future<void> _save() async {
    final type = _editingType;
    if (type == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      final repo = await ref.read(apiariesRepositoryProvider.future);
      await repo.setCounter(widget.apiary.id, type, _draftValue);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _editingType = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.apiarySaveError('$e'))),
      );
    }
  }

  Future<void> _pickCounterToAdd(List<String> addable) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => _AddCounterSheet(addableTypes: addable),
    );
    if (!mounted || selected == null) return;
    // Open the editor at 0 so the user sets the initial value; saving creates
    // the row (setCounter upserts), so UNIQUE is preserved.
    _openEditor(selected, 0);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final apiary = widget.apiary;
    final counters = ref.watch(apiaryCountersProvider(apiary.id));
    final rows = counters.value ?? const <ApiaryCounter>[];

    // The types that already have a row (hive is always considered present —
    // it renders unconditionally from [Apiary.hiveCount]).
    final present = <String>{
      counterTypeHive,
      for (final c in rows) c.counterType,
    };
    // Addable = known, non-hive types this client can label that don't yet
    // have a row — the add-counter picker's options, respecting UNIQUE.
    final addable = <String>[
      for (final type in knownCounterTypes)
        if (type != counterTypeHive &&
            !present.contains(type) &&
            counterTypeLabel(l10n, type) != null)
          type,
    ];

    final others = <ApiaryCounter>[
      for (final counter in rows)
        if (counter.counterType != counterTypeHive &&
            counterValueLabel(l10n, counter.counterType, counter.value) != null)
          counter,
    ];

    return Column(
      key: const Key('apiary-detail-counters-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _CounterCard(
              key: const Key('apiary-detail-hive-count'),
              label: l10n.hiveCountValue(apiary.hiveCount),
              onTap: () => _editingType == counterTypeHive
                  ? _maybeCloseEditor()
                  : _openEditor(counterTypeHive, apiary.hiveCount),
            ),
            for (final counter in others)
              _CounterCard(
                key: Key('apiary-detail-counter-${counter.counterType}'),
                label: counterValueLabel(
                  l10n,
                  counter.counterType,
                  counter.value,
                )!,
                onTap: () => _editingType == counter.counterType
                    ? _maybeCloseEditor()
                    : _openEditor(counter.counterType, counter.value),
              ),
          ],
        ),
        if (_editingType != null) ...[
          const SizedBox(height: 12),
          _CounterEditor(
            typeLabel: counterTypeLabel(l10n, _editingType!) ?? _editingType!,
            controller: _valueController,
            saving: _saving,
            onDecrement: () => setState(() => _bumpBy(-1)),
            onIncrement: () => setState(() => _bumpBy(1)),
            onSave: _save,
          ),
        ],
        if (addable.isNotEmpty) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('apiary-detail-add-counter-button'),
              style: TextButton.styleFrom(
                foregroundColor: context.brand.onHeroSurface,
                minimumSize: const Size(kMinTapTarget, kMinTapTarget),
              ),
              onPressed: () => _pickCounterToAdd(addable),
              icon: const Icon(Icons.add),
              label: Text(l10n.apiaryAddCounterAction),
            ),
          ),
        ],
      ],
    );
  }
}

/// One tappable counter value card (Melargil prototype's counter tile): the
/// visual shape of the original hive-count badge, now a button that opens the
/// inline value editor. 44x44 minimum tap target (D-18, gloves-friendly).
class _CounterCard extends StatelessWidget {
  const _CounterCard({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = context.brand;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: brand.onHeroSurface.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: kMinTapTarget,
              minWidth: kMinTapTarget,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Center(
                widthFactor: 1,
                child: Text(
                  label,
                  style: TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: brand.onHeroSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The inline stepper editor for one counter's value (#346, Melargil
/// prototype's −/value/+/OK row): a decrement button, a direct-entry number
/// field (so a big jump doesn't need dozens of taps — and so the e2e can type
/// a value), an increment button, and a save action. Purely presentational —
/// it reports intent up to [_CountersSectionState], which owns the draft
/// value and the persisted write.
class _CounterEditor extends StatelessWidget {
  const _CounterEditor({
    required this.typeLabel,
    required this.controller,
    required this.saving,
    required this.onDecrement,
    required this.onIncrement,
    required this.onSave,
  });

  final String typeLabel;
  final TextEditingController controller;
  final bool saving;
  final VoidCallback onDecrement;
  final VoidCallback onIncrement;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final brand = context.brand;
    return Container(
      key: const Key('apiary-detail-counter-editor'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: brand.onHeroSurface.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              typeLabel,
              style: TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontWeight: FontWeight.w600,
                fontSize: 14,
                color: brand.onHeroSurface,
              ),
            ),
          ),
          IconButton(
            key: const Key('apiary-counter-decrement'),
            tooltip: l10n.counterDecrementLabel,
            constraints: const BoxConstraints(
              minWidth: kMinTapTarget,
              minHeight: kMinTapTarget,
            ),
            onPressed: saving ? null : onDecrement,
            icon: Icon(Icons.remove, color: brand.onHeroSurface),
          ),
          SizedBox(
            width: 64,
            // The type name already renders at the row's left (#393) — a
            // second, redundant floating label on this 64px field truncates
            // unreadably ("Hi..."). `InputDecoration.labelText` combined with
            // `floatingLabelBehavior: never` looked like the fix (keep the
            // label out of view but still reachable via
            // `InputDecoration.labelText`'s semantics), but it isn't: once
            // the field holds text — which it always does here, since
            // [_CountersSectionState._openEditor] pre-fills it with the
            // current value, even "0" — InputDecorator's `_shouldShowLabel`
            // goes false (never-floating + non-empty content), which drives
            // the label's `AnimatedOpacity` to 0. An opacity-0 subtree is
            // EXCLUDED from the semantics tree by default in Flutter unless
            // `alwaysIncludeSemantics` is set (not exposed via
            // `InputDecoration`) — so the accessible name silently vanished
            // the moment the editor opened, which is exactly what timed out
            // the e2e's `getByLabel("Hives")` on PR #400 (#393 regression).
            // An explicit [Semantics] label sidesteps InputDecorator's
            // visibility-linked semantics entirely: it stays on the merged
            // node regardless of what the (now label-less) decoration paints.
            child: Semantics(
              label: typeLabel,
              child: TextField(
                key: const Key('apiary-counter-edit-field'),
                controller: controller,
                enabled: !saving,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: TextStyle(
                  fontFamily: AppTheme.bodyFontFamily,
                  fontWeight: FontWeight.w700,
                  fontSize: 18,
                  color: brand.onHeroSurface,
                ),
                decoration: const InputDecoration(isDense: true),
              ),
            ),
          ),
          IconButton(
            key: const Key('apiary-counter-increment'),
            tooltip: l10n.counterIncrementLabel,
            constraints: const BoxConstraints(
              minWidth: kMinTapTarget,
              minHeight: kMinTapTarget,
            ),
            onPressed: saving ? null : onIncrement,
            icon: Icon(Icons.add, color: brand.onHeroSurface),
          ),
          const SizedBox(width: 4),
          TextButton(
            key: const Key('apiary-counter-save'),
            style: TextButton.styleFrom(
              foregroundColor: brand.onHeroSurface,
              minimumSize: const Size(kMinTapTarget, kMinTapTarget),
            ),
            onPressed: saving ? null : onSave,
            child: Text(l10n.saveButton),
          ),
        ],
      ),
    );
  }
}

/// The add-counter type picker (#346 AC): a modal sheet listing the addable
/// known counter types. Pops the chosen type string (or null on dismiss).
/// The caller only ever passes types that don't yet have a row, so picking
/// one can never violate `UNIQUE(apiary_id, counter_type)`.
class _AddCounterSheet extends StatelessWidget {
  const _AddCounterSheet({required this.addableTypes});

  final List<String> addableTypes;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Text(
                l10n.apiaryAddCounterTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (addableTypes.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: Text(l10n.apiaryNoCountersToAdd),
              )
            else
              for (final type in addableTypes)
                ListTile(
                  key: Key('apiary-add-counter-option-$type'),
                  title: Text(counterTypeLabel(l10n, type) ?? type),
                  onTap: () => Navigator.of(context).pop(type),
                ),
          ],
        ),
      ),
    );
  }
}
