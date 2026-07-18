import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
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
        Text(l10n.journeyApiariesLabel, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          key: const Key('journey-apiaries-search-field'),
          controller: _searchController,
          decoration: InputDecoration(
            hintText: l10n.apiariesSearchHint,
            prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (v) => setState(() => _query = v),
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
              return Padding(
                key: const Key('journey-apiaries-empty'),
                padding: const EdgeInsets.all(16),
                child: Text(l10n.journeyApiariesNoneAvailable),
              );
            }
            final filtered = filterApiariesByQuery(apiaries, _query);
            if (filtered.isEmpty) {
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l10n.apiariesSearchNoResults),
              );
            }
            return Container(
              key: const Key('journey-apiaries-list'),
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: filtered.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
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
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kMinTapTarget),
          child: ExcludeSemantics(
            child: ListTile(
              title: Text(label),
              trailing: Icon(
                selected ? Icons.check_box : Icons.check_box_outline_blank,
                color: selected ? theme.colorScheme.primary : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
