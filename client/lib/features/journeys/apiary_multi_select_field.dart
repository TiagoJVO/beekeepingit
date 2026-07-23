import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../apiaries/apiaries_repository.dart';

/// The apiaries-to-visit multi-select picker (#45, FR-JO-4) — the FIRST
/// multi-select widget in this codebase (no prior precedent existed to
/// mirror; built following the same conventions every other picker/list in
/// this app already uses: [ApiariesListScreen]'s search+filter pattern
/// [filterApiariesByQuery], [kMinTapTarget]-sized rows, and
/// `Semantics(button:, selected:, label:)` per-row like
/// apiaries_list_screen.dart's own view-toggle segments).
///
/// A search field over the org's locally-synced apiary set (client-side,
/// offline-first — same [filterApiariesByQuery] the apiaries list itself
/// uses, FR-AP-6/D-17) narrows a checkable list; tapping a row toggles its
/// membership in [selectedApiaryIds]. Deliberately NOT its own
/// state-management provider: [selectedApiaryIds]/[onChanged] are plain
/// callback-driven props, so the owning form (journey_form_screen.dart)
/// stays the single source of truth for "what will be saved" — this widget
/// only presents/toggles it.
class ApiaryMultiSelectField extends ConsumerStatefulWidget {
  const ApiaryMultiSelectField({
    required this.selectedApiaryIds,
    required this.onChanged,
    super.key,
  });

  final Set<String> selectedApiaryIds;
  final ValueChanged<Set<String>> onChanged;

  @override
  ConsumerState<ApiaryMultiSelectField> createState() =>
      _ApiaryMultiSelectFieldState();
}

class _ApiaryMultiSelectFieldState
    extends ConsumerState<ApiaryMultiSelectField> {
  final _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _toggle(String apiaryId) {
    final next = Set<String>.from(widget.selectedApiaryIds);
    if (!next.remove(apiaryId)) next.add(apiaryId);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final apiariesAsync = ref.watch(apiariesStreamProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The picker's own label sits above its search field (the prototype's
        // label-above-control pattern), so the whole multi-select reads as
        // one labelled form field like every other field on the form.
        LabeledField(
          label: l10n.journeyApiariesLabel,
          child: TextField(
            key: const Key('journey-apiaries-search-field'),
            controller: _searchController,
            decoration: InputDecoration(
              hintText: l10n.apiariesSearchHint,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        const SizedBox(height: 8),
        apiariesAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (err, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.apiariesError('$err')),
          ),
          data: (apiaries) {
            if (apiaries.isEmpty) {
              return EmptyState(
                key: const Key('journey-apiaries-empty'),
                message: l10n.journeyApiariesNoneAvailable,
                icon: Icons.hive_outlined,
              );
            }
            final filtered = filterApiariesByQuery(apiaries, _query);
            if (filtered.isEmpty) {
              return EmptyState(message: l10n.apiariesSearchNoResults);
            }
            return Container(
              key: const Key('journey-apiaries-list'),
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                color: context.brand.cardColor,
                border: Border.all(color: context.brand.cardBorder),
                borderRadius: BrandDimens.borderCard,
              ),
              clipBehavior: Clip.antiAlias,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: filtered.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  thickness: 1,
                  color: context.brand.cardBorder,
                ),
                itemBuilder: (context, i) {
                  final apiary = filtered[i];
                  final selected = widget.selectedApiaryIds.contains(apiary.id);
                  return _ApiaryCheckTile(
                    key: Key('journey-apiary-option-${apiary.id}'),
                    label: apiary.name,
                    selected: selected,
                    onTap: () => _toggle(apiary.id),
                  );
                },
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        Text(
          key: const Key('journey-apiaries-selected-count'),
          l10n.journeyApiariesSelectedCount(widget.selectedApiaryIds.length),
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// One checkable apiary row — a full [kMinTapTarget] tap target,
/// `Semantics(button:, selected:, label:)` so a screen-reader user hears
/// "Serra Norte, selected/not selected, button" (matching
/// apiaries_list_screen.dart's `_ToggleSegment` convention).
class _ApiaryCheckTile extends StatelessWidget {
  const _ApiaryCheckTile({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: kMinTapTarget),
            child: ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          fontFamily: AppTheme.bodyFontFamily,
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(
                      selected
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      color: selected
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
