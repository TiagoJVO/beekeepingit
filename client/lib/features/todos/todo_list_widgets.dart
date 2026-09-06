import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import 'todo_filters.dart';
import 'todo_priority.dart';
import 'todos_repository.dart';

/// The main Todos tab's body (#53): loading/error states, the two distinct
/// empty states (mirrors activity_list_widgets.dart's `ActivityListView` own
/// `hasAnyActivities` vs. "filters matched nothing" split — here "zero
/// todos at all" vs. "the current filters matched none", #53 AC), and the
/// list itself, one row per todo distinguishing open/overdue/done (#53 AC).
class TodoListView extends StatelessWidget {
  const TodoListView({required this.viewModel, super.key});

  final AsyncValue<TodosViewModel> viewModel;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return viewModel.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (err, _) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(l10n.todosError('$err')),
        ),
      ),
      data: (vm) {
        if (!vm.hasAnyTodos) {
          return EmptyState(
            message: l10n.todosEmpty,
            icon: Icons.checklist_outlined,
          );
        }
        if (vm.filtered.isEmpty) {
          return EmptyState(message: l10n.todosFilterNoResults);
        }
        return ListView.separated(
          key: const Key('todo-list'),
          padding: const EdgeInsets.fromLTRB(
            BrandDimens.gutter,
            4,
            BrandDimens.gutter,
            BrandDimens.scrollBottomInset,
          ),
          itemCount: vm.filtered.length,
          separatorBuilder: (_, _) =>
              const SizedBox(height: BrandDimens.gapCard),
          itemBuilder: (context, i) =>
              _TodoTile(todo: vm.filtered[i], today: vm.today),
        );
      },
    );
  }
}

class _TodoTile extends StatelessWidget {
  const _TodoTile({required this.todo, required this.today});

  final Todo todo;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final overdue = isOverdue(todo, today);
    final priorityLabel =
        todoPriorityLabel(l10n, todo.priority) ?? todo.priority;
    final dueText = todo.dueDate == null
        ? l10n.todoDueDateUnset
        : LocaleFormatting.of(context).date(DateTime.parse(todo.dueDate!));
    final statusWord = todo.isDone
        ? l10n.todoFilterStatusDone
        : overdue
        ? l10n.todoFilterStatusOverdue
        : l10n.todoFilterStatusOpen;
    final brand = context.brand;
    // The leading tile's brand accent carries the same three-way status
    // split the icon does: muted/generic for done, the terracotta treatment
    // accent for overdue (an attention state), the gold cresta accent for a
    // plain open row. Colours come from `context.brand`, never a raw hex.
    final statusVisual = todo.isDone
        ? brand.generic
        : overdue
        ? brand.treatment
        : brand.cresta;
    final statusIcon = todo.isDone
        ? Icons.check_circle
        : overdue
        ? Icons.warning_amber_outlined
        : Icons.radio_button_unchecked;

    // Composed from [BrandCard] in [BrandRowCard]'s exact shape (leading tile
    // · title/subtitle · trailing · chevron) rather than [BrandRowCard]
    // itself, because a done todo's title must keep its strikethrough (#53
    // AC: "distinguishes ... completed" — a non-colour-only signal, WCAG 2.2
    // AA 1.4.1) and BrandRowCard takes a plain title String with no room for
    // a per-row text decoration.
    return BrandCard(
      key: Key('todo-${todo.id}'),
      // The row's WHOLE announcement (#662, FR-AX-1): [BrandCard] excludes
      // its child's semantics, so the status — the meaning behind the
      // leading tile's icon/colour and the overdue badge, and the only
      // signal that a row is done or late — has to be spelled out here
      // rather than left on the widgets that draw it (WCAG 2.2 AA 1.1.1).
      semanticLabel:
          '${todo.title}. $dueText · $priorityLabel. '
          '${l10n.todoStatusSemanticLabel(statusWord)}',
      // Tapping a row opens the read-focused detail screen (#293), not the
      // edit form directly — mirrors _ActivityTile/journey list row's own
      // tap-to-detail convention (activity_list_widgets.dart,
      // journeys_list_screen.dart).
      onTap: () => context.go('/todos/${todo.id}'),
      child: Row(
        children: [
          // The leading icon is the ONLY status signal for an open,
          // non-overdue row (no visible badge — that's reserved for
          // overdue/done, this file's own doc comment). Its text alternative
          // (WCAG 2.2 AA 1.1.1) lives in the card's `semanticLabel` above,
          // not in a `Semantics` wrapper here: the card speaks as one node
          // and excludes its children (#662).
          LeadingIconTile(
            icon: statusIcon,
            color: statusVisual.color,
            tint: statusVisual.tint,
            size: BrandDimens.sizeLeadingTileSmall,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  todo.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                    color: todo.isDone
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onSurface,
                    decoration: todo.isDone ? TextDecoration.lineThrough : null,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '$dueText · $priorityLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.bodyFontFamily,
                    fontSize: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          // Text + icon together (never color alone, WCAG 2.2 AA 1.4.1, #53
          // AC): only rendered for an overdue row — done/open rows are
          // already distinguished by the leading tile + (for done) the
          // strikethrough title above.
          if (overdue) ...[
            const SizedBox(width: 10),
            _OverdueBadge(label: l10n.todoOverdueBadge),
          ],
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: Icon(Icons.chevron_right, color: brand.trailingIcon),
          ),
        ],
      ),
    );
  }
}

/// The overdue badge (#53 AC: "distinguishes ... overdue") — text + a
/// warning icon together, never color alone (WCAG 2.2 AA 1.4.1), styled with
/// the theme's error container so it reads as a genuine attention state,
/// unlike the neutral priority/status pills elsewhere in this app (e.g.
/// journey_list_screen.dart's `_StatusBadge`/`_ProgressBadge`, which are
/// deliberately muted since "closed"/"progress" aren't alarm states).
class _OverdueBadge extends StatelessWidget {
  const _OverdueBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const Key('todo-overdue-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(BrandDimens.radiusBadge),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: 14,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
        ],
      ),
    );
  }
}
