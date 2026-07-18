import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../members/members_repository.dart';

/// The todo assignee picker (#293, FR-TD-1) — a single-select list of the
/// caller's org roster ([memberNamesProvider], `user_id -> display name`,
/// members_repository.dart's own online-fetch + session-cache, empty
/// offline/pre-first-fetch), same `Semantics(button/selected/label)` row
/// shape as [TodoApiaryPickerField] (todo_apiary_picker_field.dart), plus an
/// explicit "Unassigned" clear row (#293 AC: "set, change, or clear").
///
/// Two edge cases this widget deliberately handles rather than just
/// rendering whatever the roster happens to contain:
///
/// - An EMPTY roster (offline, or the org roster hasn't loaded yet) still
///   shows the "Unassigned" row — an existing assignee can always be
///   cleared offline, even though no OTHER member can be picked until the
///   roster is available.
/// - A currently-selected [selectedAssigneeId] that ISN'T (yet, or anymore)
///   in [memberNamesProvider]'s map still renders its own row, labeled with
///   a short id fragment (mirrors todo_display.dart's `todoAssigneeLabel`
///   fallback) rather than disappearing from the list — so the picker never
///   silently shows a blank/missing selection for a real, already-set
///   assignee.
class TodoAssigneePickerField extends ConsumerWidget {
  const TodoAssigneePickerField({
    required this.selectedAssigneeId,
    required this.onChanged,
    super.key,
  });

  /// Null when the todo is unassigned (FR-TD-1's own default).
  final String? selectedAssigneeId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final memberNamesAsync = ref.watch(memberNamesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.todoAssigneeFieldLabel, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        memberNamesAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          // Best-effort by design (mirrors memberNamesProvider's own doc
          // comment): a lookup failure degrades to the same empty-roster
          // rendering below rather than an error screen blocking the rest of
          // the form.
          error: (_, _) => _RosterList(
            l10n: l10n,
            theme: theme,
            memberNames: const {},
            selectedAssigneeId: selectedAssigneeId,
            onChanged: onChanged,
          ),
          data: (memberNames) => _RosterList(
            l10n: l10n,
            theme: theme,
            memberNames: memberNames,
            selectedAssigneeId: selectedAssigneeId,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}

class _RosterList extends StatelessWidget {
  const _RosterList({
    required this.l10n,
    required this.theme,
    required this.memberNames,
    required this.selectedAssigneeId,
    required this.onChanged,
  });

  final AppLocalizations l10n;
  final ThemeData theme;
  final Map<String, String> memberNames;
  final String? selectedAssigneeId;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    // A currently-selected id absent from the roster still gets its own row
    // (short-id fallback) — see this file's own class doc comment.
    final entries = {...memberNames};
    final selected = selectedAssigneeId;
    if (selected != null && selected.isNotEmpty && !entries.containsKey(selected)) {
      entries[selected] = l10n.todoAssigneeUnknown(_shortId(selected));
    }

    return Container(
      key: const Key('todo-assignee-list'),
      constraints: const BoxConstraints(maxHeight: 280),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          _TodoOptionTile(
            key: const Key('todo-assignee-option-none'),
            label: l10n.todoAssigneeUnassigned,
            selected: selected == null || selected.isEmpty,
            onTap: () => onChanged(null),
          ),
          if (entries.isEmpty)
            Padding(
              key: const Key('todo-assignee-empty'),
              padding: const EdgeInsets.all(16),
              child: Text(l10n.todoAssigneeNoneAvailable),
            )
          else
            for (final entry in entries.entries) ...[
              const Divider(height: 1),
              _TodoOptionTile(
                key: Key('todo-assignee-option-${entry.key}'),
                label: entry.value,
                selected: selected == entry.key,
                onTap: () => onChanged(entry.key),
              ),
            ],
        ],
      ),
    );
  }
}

String _shortId(String id) => id.length <= 8 ? id : id.substring(id.length - 8);

/// One selectable, single-select row — deliberately duplicated from
/// todo_apiary_picker_field.dart's own private `_TodoOptionTile` (same
/// small-duplication precedent this codebase already accepts for minor,
/// self-contained widgets, e.g. each journey/activity detail screen's own
/// `_HeaderRow`).
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
