import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/field_action_button.dart';
import '../../core/widgets/option_row.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../apiaries/apiaries_repository.dart';
import '../apiaries/apiary_search_decoration.dart';
import 'add_activity_screen.dart';

/// The Activities tab's own create flow (#634, FR-UX-2/FR-AC-2).
///
/// An activity is always recorded AT an apiary (FR-AC-2, D-2), which is why
/// the only create entry point used to live on the apiary detail page. #634
/// is the product owner's judgement that this cost too much: logging an
/// activity is the app's central field action, and reaching it took four
/// taps starting from a different tab. FR-UX-2's quick-add is contextual to
/// the active area and Activities IS an area, so the tab gets its own
/// quick-add — consistent with D-35's "no FAB on Home" reasoning rather than
/// a contradiction of it — and this screen supplies the apiary context the
/// form needs by ASKING for it first, matching the prototype's apiary ->
/// type -> fields order.
///
/// It lives in the ACTIVITIES branch (app_router.dart), not the apiaries
/// one, so Back returns to the Activities list and the tab never switches
/// under the user — the same branch-ownership rule `journeyActivityDetail`
/// follows for the journey-scoped activity detail (#384).
///
/// Three cases, all driven by the org's locally-synced apiary set
/// ([apiariesStreamProvider] — offline-first, no network call):
///   - **none** — the flow cannot continue, so it says why and offers the
///     one action that unblocks it (create an apiary). Never a dead end.
///   - **exactly one** — there is nothing to choose, so the picker step is
///     skipped and the form renders directly for that apiary. Asking a
///     gloved user to confirm the only possible answer is a tap that buys
///     nothing (FR-UX-1).
///   - **two or more** — the picker step. Picking navigates to
///     `/activities/new/:apiaryId`, which go_router stacks UNDER the picker
///     page, so the choice is a real navigation step Back can undo.
class NewActivityFlowScreen extends ConsumerStatefulWidget {
  const NewActivityFlowScreen({this.apiaryId, super.key});

  /// Set by the `:apiaryId` route once the user has picked one. Null on
  /// `/activities/new`, where the apiary is still to be resolved.
  final String? apiaryId;

  @override
  ConsumerState<NewActivityFlowScreen> createState() =>
      _NewActivityFlowScreenState();
}

class _NewActivityFlowScreenState extends ConsumerState<NewActivityFlowScreen> {
  /// The sole apiary's id, LATCHED the first time the stream resolves to
  /// exactly one. Without the latch this screen would keep watching the live
  /// apiary set while the form is on screen, and a teammate's apiary syncing
  /// in mid-edit would swap the half-filled form for the picker — silently,
  /// since [UnsavedChangesMixin] clears its dirty flag on dispose, so not
  /// even the discard guard would fire. Once an apiary is resolved the flow
  /// stops watching entirely (the early return below runs before the
  /// `ref.watch`), so later emissions can't disturb it.
  String? _soleApiaryId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final chosen = widget.apiaryId ?? _soleApiaryId;
    if (chosen != null) return _form(chosen);

    return ref
        .watch(apiariesStreamProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(child: Text(l10n.apiariesError('$err'))),
          data: (apiaries) {
            if (apiaries.isEmpty) return const _NoApiariesStep();
            if (apiaries.length == 1) {
              // Latched here rather than via setState: the value is used by
              // this very build, and the next one takes the early return.
              final id = apiaries.single.id;
              _soleApiaryId = id;
              return _form(id);
            }
            return _ApiaryStep(apiaries: apiaries);
          },
        );
  }

  /// The type/fields step, under a banner naming the apiary it will be
  /// recorded at. The banner is this flow's own concern, not the form's: on
  /// the apiaries-branch entry point the apiary is the whole screen the user
  /// came from, whereas here it is a choice they just made (or one made for
  /// them, in the single-apiary case) and every screen after it would
  /// otherwise look identical for any apiary — so a mis-tap in the picker
  /// would file the activity against the wrong one with nothing on screen to
  /// notice it by.
  Widget _form(String apiaryId) => Column(
    children: [
      _ApiaryContextBanner(apiaryId: apiaryId),
      // Back to the Activities list rather than the apiary detail page: the
      // user started on this tab, so this is where the saved activity should
      // land them (see AddActivityScreen.returnLocation).
      Expanded(
        child: AddActivityScreen(
          apiaryId: apiaryId,
          returnLocation: '/activities',
        ),
      ),
    ],
  );
}

/// Names the apiary the activity is being recorded at. Its own widget so a
/// live apiary-set emission (a rename, a teammate's new apiary) rebuilds only
/// this strip and never the form above it. Renders nothing at all while the
/// name is unknown — an apiary is always chosen from the synced set, so this
/// is a cold-stream flicker, not a state worth captioning.
class _ApiaryContextBanner extends ConsumerWidget {
  const _ApiaryContextBanner({required this.apiaryId});

  final String apiaryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref
        .watch(apiariesStreamProvider)
        .value
        ?.where((a) => a.id == apiaryId)
        .firstOrNull
        ?.name;
    if (name == null) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Container(
      key: const Key('new-activity-apiary-banner'),
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(
            Icons.hive_outlined,
            size: 18,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The zero-apiary case: explain, then offer the action that unblocks the
/// flow. `context.go` deliberately crosses into the apiaries branch — the
/// new-apiary form belongs to that tab, and landing the user there is the
/// point of the action.
class _NoApiariesStep extends StatelessWidget {
  const _NoApiariesStep();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      key: const Key('new-activity-no-apiaries'),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          EmptyState(
            message: l10n.newActivityNoApiaries,
            icon: Icons.hive_outlined,
          ),
          const SizedBox(height: 8),
          PrimaryActionButton(
            key: const Key('new-activity-add-apiary-button'),
            label: l10n.addApiary,
            icon: Icons.add,
            onPressed: () => context.go('/apiaries/new'),
          ),
        ],
      ),
    );
  }
}

/// The apiary step: search over the org's locally-synced apiaries and pick
/// one. A single-select list rather than a form field, since this IS the
/// whole step — its own row renders via `core/widgets/option_row.dart`'s
/// [OptionRow] (`OptionRowMode.navigate`), the shared skeleton #762
/// extracted from this row and `TodoApiaryPickerField`/
/// `ApiaryMultiSelectField`'s own rows.
class _ApiaryStep extends StatefulWidget {
  const _ApiaryStep({required this.apiaries});

  final List<Apiary> apiaries;

  @override
  State<_ApiaryStep> createState() => _ApiaryStepState();
}

class _ApiaryStepState extends State<_ApiaryStep> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final brand = context.brand;
    final theme = Theme.of(context);
    final filtered = filterApiariesByQuery(widget.apiaries, _query);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                header: true,
                child: Text(
                  l10n.newActivityApiaryTitle,
                  style: TextStyle(
                    fontFamily: AppTheme.displayFontFamily,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                l10n.newActivityApiaryPrompt,
                style: TextStyle(
                  fontFamily: AppTheme.bodyFontFamily,
                  fontSize: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('new-activity-apiary-search-field'),
                controller: _searchController,
                decoration: apiarySearchDecoration(l10n),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        Expanded(
          child: filtered.isEmpty
              ? EmptyState(message: l10n.apiariesSearchNoResults)
              : ListView.separated(
                  key: const Key('new-activity-apiary-list'),
                  // The bottom gutter is the chrome band, not a gutter
                  // (#789). Not for a FAB — this is a pushed route, so the
                  // shell hides its quick-add — but for a toast: every row
                  // here is a tap target, and a bar re-presented from the
                  // screen the user came from would sit on the last apiary
                  // and block choosing it. Inside the shell `MediaQuery`
                  // reports no bottom inset, so this resolves to the bare
                  // constant; `scrollBottomInsetOf` is still the right call,
                  // because it is right on either side of the shell.
                  padding: EdgeInsets.fromLTRB(
                    16,
                    0,
                    16,
                    BrandDimens.scrollBottomInsetOf(context),
                  ),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final apiary = filtered[index];
                    return OptionRow(
                      key: Key('new-activity-apiary-option-${apiary.id}'),
                      label: apiary.name,
                      subtitle: l10n.hiveCountValue(apiary.hiveCount),
                      mode: OptionRowMode.navigate,
                      cardColor: brand.cardColor,
                      cardShape: RoundedRectangleBorder(
                        borderRadius: BrandDimens.borderCard,
                        side: BorderSide(color: brand.cardBorder),
                      ),
                      onTap: () => context.go('/activities/new/${apiary.id}'),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
