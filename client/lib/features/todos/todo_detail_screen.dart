import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/app_theme.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_theme.dart';
import '../../theming/brand_widgets.dart';
import '../apiaries/apiaries_repository.dart';
import '../members/members_repository.dart';
import 'todo_display.dart';
import 'todo_priority.dart';
import 'todos_repository.dart';

/// Read-focused todo detail (#293, FR-TD-1, FR-HIS-1): every field of a
/// todo, read-only, plus a prominent complete/reopen toggle — mirrors
/// activity_detail_screen.dart's/journey_detail_screen.dart's own dedicated
/// view screen, distinct from the edit form (todo_form_screen.dart), which
/// owns editing and delete. Reachable by tapping a row on the main Todos tab
/// (todo_list_widgets.dart's `_TodoTile`).
///
/// Offline-first (FR-OF-1): reads entirely from the local synced set via
/// [todoByIdProvider] (a live per-id watch, todos_repository.dart) — no
/// network. Assignee/apiary names are resolved the same way the form's own
/// pickers source their candidates ([memberNamesProvider]/
/// [apiariesStreamProvider]), via [todoAssigneeLabel]/[todoApiaryLabel]
/// (todo_display.dart)'s null/known/unknown-fallback precedence.
class TodoDetailScreen extends ConsumerStatefulWidget {
  const TodoDetailScreen({required this.todoId, super.key});

  final String todoId;

  @override
  ConsumerState<TodoDetailScreen> createState() => _TodoDetailScreenState();
}

class _TodoDetailScreenState extends ConsumerState<TodoDetailScreen> {
  bool _busy = false;

  /// Toggles complete/reopen IN PLACE (#293 AC), no navigation — a narrow
  /// status-only write via [TodosRepository.complete]/[TodosRepository.
  /// reopen]. Unlike the form's own toggle, this screen doesn't keep a
  /// separate local status mirror: it watches [todoByIdProvider] live
  /// (this class's own doc comment), so a successful write is reflected by
  /// the SAME live query once the local store re-emits — this handler only
  /// owns the busy flag and the success/error toast.
  Future<void> _toggleComplete(Todo todo) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(todosRepositoryProvider.future);
      if (todo.isDone) {
        await repo.reopen(todo.id);
      } else {
        await repo.complete(todo.id);
      }
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            todo.isDone ? l10n.todoReopenSuccess : l10n.todoCompleteSuccess,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            todo.isDone
                ? l10n.todoReopenError('$e')
                : l10n.todoCompleteError('$e'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final todoAsync = ref.watch(todoByIdProvider(widget.todoId));

    return Scaffold(
      body: todoAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.todosError('$err')),
          ),
        ),
        data: (todo) {
          if (todo == null) {
            // Deleted/not found (a stale deep link) — nothing sensible to
            // render; bounce back to the Todos tab rather than show a blank
            // detail page, mirroring activity_detail_screen.dart's/
            // journey_detail_screen.dart's own null-bounce.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (context.mounted) context.go('/todos');
            });
            return const SizedBox.shrink();
          }
          return _TodoDetailBody(
            todo: todo,
            busy: _busy,
            onToggleComplete: () => _toggleComplete(todo),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('todo-detail-edit-button'),
        heroTag: 'todo-detail-edit-button',
        onPressed: () => context.go('/todos/${widget.todoId}/edit'),
        icon: const Icon(Icons.edit_outlined),
        label: Text(l10n.editTodoAction),
      ),
    );
  }
}

class _TodoDetailBody extends ConsumerWidget {
  const _TodoDetailBody({
    required this.todo,
    required this.busy,
    required this.onToggleComplete,
  });

  final Todo todo;
  final bool busy;
  final VoidCallback onToggleComplete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final memberNames =
        ref.watch(memberNamesProvider).value ?? const <String, String>{};
    final apiaries =
        ref.watch(apiariesStreamProvider).value ?? const <Apiary>[];

    final priorityLabel =
        todoPriorityLabel(l10n, todo.priority) ?? todo.priority;
    final dueText = todo.dueDate == null
        ? l10n.todoDueDateUnset
        : LocaleFormatting.of(context).date(DateTime.parse(todo.dueDate!));
    final assigneeText = todoAssigneeLabel(l10n, todo.assigneeId, memberNames);
    final apiaryText = todoApiaryLabel(l10n, todo.apiaryId, apiaries);
    final statusText = todo.isDone
        ? l10n.todoFilterStatusDone
        : l10n.todoFilterStatusOpen;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            BrandDimens.gutterForm,
            BrandDimens.gutterForm,
            BrandDimens.gutterForm,
            BrandDimens.scrollBottomInset,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              HeroCard(
                key: const Key('todo-detail-header'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      todo.title,
                      style: TextStyle(
                        fontFamily: AppTheme.displayFontFamily,
                        fontWeight: FontWeight.w600,
                        fontSize: 24,
                        color: context.brand.onHeroSurface,
                        decoration: todo.isDone
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    const SizedBox(height: 12),
                    _HeaderRow(
                      key: const Key('todo-detail-status'),
                      icon: todo.isDone
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      label: l10n.todoFilterStatusLabel,
                      value: statusText,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              BrandCard(
                key: const Key('todo-detail-fields'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SectionHeader(l10n.todoDetailFieldsHeader),
                    const SizedBox(height: 8),
                    _DetailRow(
                      key: const Key('todo-detail-description'),
                      label: l10n.todoDescriptionLabel,
                      value: todo.description ?? l10n.todoDescriptionUnset,
                    ),
                    const SizedBox(height: 12),
                    _DetailRow(
                      key: const Key('todo-detail-due-date'),
                      label: l10n.todoDueDateFieldLabel,
                      value: dueText,
                    ),
                    const SizedBox(height: 12),
                    _DetailRow(
                      key: const Key('todo-detail-priority'),
                      label: l10n.todoPriorityFieldLabel,
                      value: priorityLabel,
                    ),
                    const SizedBox(height: 12),
                    _DetailRow(
                      key: const Key('todo-detail-assignee'),
                      label: l10n.todoAssigneeFieldLabel,
                      value: assigneeText,
                    ),
                    const SizedBox(height: 12),
                    _DetailRow(
                      key: const Key('todo-detail-apiary'),
                      label: l10n.todoApiaryFieldLabel,
                      value: apiaryText,
                    ),
                    if (todo.isDone && todo.completedAt != null) ...[
                      const SizedBox(height: 12),
                      _DetailRow(
                        key: const Key('todo-detail-completed-at'),
                        label: l10n.todoCompletedAtLabel,
                        value: LocaleFormatting.of(
                          context,
                        ).dateTime(DateTime.parse(todo.completedAt!).toLocal()),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 24),
              PrimaryActionButton(
                key: const Key('todo-detail-complete-toggle-button'),
                label: todo.isDone
                    ? l10n.todoReopenAction
                    : l10n.todoCompleteAction,
                icon: todo.isDone ? Icons.replay : Icons.check_circle_outline,
                busy: busy,
                onPressed: onToggleComplete,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A labeled row inside the plum [HeroCard] header — icon + "Label: value",
/// tinted for the hero surface's muted foreground. Mirrors
/// activity_detail_screen.dart's own private `_HeaderRow` (duplicated, not
/// shared — same small-duplication precedent that file's own doc comment
/// documents for `journey_detail_screen.dart`'s near-identical
/// `_StatusBadge`).
class _HeaderRow extends StatelessWidget {
  const _HeaderRow({
    required this.icon,
    required this.label,
    required this.value,
    super.key,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = context.brand.onHeroSurfaceMuted;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '$label: $value',
            style: theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}

/// One read-only field: its label above the stored value, with a merged
/// "Label: value" semantics announcement (WCAG 2.2 AA) — mirrors
/// activity_detail_screen.dart's own private `_AttributeRow`.
class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value, super.key});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label: $value',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(value, style: theme.textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}
