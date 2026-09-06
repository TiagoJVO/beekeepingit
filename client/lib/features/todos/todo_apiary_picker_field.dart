import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/option_row.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../apiaries/apiaries_repository.dart';
import '../apiaries/apiary_search_decoration.dart';

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
    final brand = context.brand;
    final apiariesAsync = ref.watch(apiariesStreamProvider);

    return LabeledField(
      label: l10n.todoApiaryFieldLabel,
      // A GROUP, not one control: the search box plus a list of selectable
      // rows that each announce their own name. Annotating the label onto it
      // would fold it into the search box and nest the rows beneath (#629).
      labelsChild: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('todo-apiary-search-field'),
            controller: _searchController,
            decoration: apiarySearchDecoration(l10n),
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
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: brand.cardColor,
                  border: Border.all(color: brand.cardBorder),
                  borderRadius: BrandDimens.borderCard,
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    OptionRow(
                      key: const Key('todo-apiary-option-none'),
                      label: l10n.todoApiaryNone,
                      mode: OptionRowMode.singleSelect,
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
                        Divider(height: 1, color: brand.cardBorder),
                        OptionRow(
                          key: Key('todo-apiary-option-${apiary.id}'),
                          label: apiary.name,
                          mode: OptionRowMode.singleSelect,
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
      ),
    );
  }
}
