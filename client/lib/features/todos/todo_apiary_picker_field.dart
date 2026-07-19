import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../apiaries/apiaries_repository.dart';

/// The todo/apiary association picker (#293, #51, FR-TD-1) — a SINGLE-select
/// variant of journey_form_screen.dart's `ApiaryMultiSelectField` (same
/// search-over-the-locally-synced-set + `Semantics(button/selected/label)`
/// row shape), since a todo relates to at most one apiary rather than a set:
/// tapping a different row REPLACES [selectedApiaryId] instead of adding to
/// it. A leading "No apiary" row is always shown — the explicit clear
/// affordance (#293 AC: "set, change, or clear the todo's apiary
/// association") — regardless of whether the org has any apiaries at all,
/// so an existing association can always be cleared.
///
/// Fully offline-capable: [apiariesStreamProvider] is the org's locally-
/// synced apiary set (apiaries_repository.dart), no network call.
class TodoApiaryPickerField extends ConsumerStatefulWidget {
  const TodoApiaryPickerField({
    required this.selectedApiaryId,
    required this.onChanged,
    super.key,
  });

  /// Null for a general, org-level todo (#51's own default).
  final String? selectedApiaryId;
  final ValueChanged<String?> onChanged;

  @override
  ConsumerState<TodoApiaryPickerField> createState() =>
      _TodoApiaryPickerFieldState();
}

class _TodoApiaryPickerFieldState extends ConsumerState<TodoApiaryPickerField> {
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
    final theme = Theme.of(context);
    final apiariesAsync = ref.watch(apiariesStreamProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.todoApiaryFieldLabel, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        TextField(
          key: const Key('todo-apiary-search-field'),
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
            final filtered = filterApiariesByQuery(apiaries, _query);
            return Container(
              key: const Key('todo-apiary-list'),
              constraints: const BoxConstraints(maxHeight: 280),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outlineVariant),
                borderRadius: BorderRadius.circular(12),
              ),
              child: ListView(
                shrinkWrap: true,
                children: [
                  _TodoOptionTile(
                    key: const Key('todo-apiary-option-none'),
                    label: l10n.todoApiaryNone,
                    selected: widget.selectedApiaryId == null,
                    onTap: () => widget.onChanged(null),
                  ),
                  if (apiaries.isEmpty)
                    Padding(
                      key: const Key('todo-apiary-empty'),
                      padding: const EdgeInsets.all(16),
                      child: Text(l10n.journeyApiariesNoneAvailable),
                    )
                  else if (filtered.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(l10n.apiariesSearchNoResults),
                    )
                  else
                    for (final apiary in filtered) ...[
                      const Divider(height: 1),
                      _TodoOptionTile(
                        key: Key('todo-apiary-option-${apiary.id}'),
                        label: apiary.name,
                        selected: widget.selectedApiaryId == apiary.id,
                        onTap: () => widget.onChanged(apiary.id),
                      ),
                    ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// One selectable, single-select row shared by [TodoApiaryPickerField] — a
/// full [kMinTapTarget] tap target, `Semantics(button:, selected:, label:)`
/// so a screen-reader user hears e.g. "Serra Norte, selected, button",
/// mirroring apiary_multi_select_field.dart's own `_ApiaryCheckTile` but with
/// a radio (single-select) rather than a checkbox (multi-select) affordance.
class _TodoOptionTile extends StatelessWidget {
  const _TodoOptionTile({
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
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: selected ? theme.colorScheme.primary : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
