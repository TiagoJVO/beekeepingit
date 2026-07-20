import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/field_action_button.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_widgets.dart';
import 'todo_apiary_picker_field.dart';
import 'todo_assignee_picker_field.dart';
import 'todo_priority.dart';
import 'todos_repository.dart';

/// Create a todo (#293, FR-TD-1), or — when [todoId] is given — view/edit/
/// complete/reopen/delete an existing one. Every field the issue's own AC
/// names (title, description, due date, priority, assignee, apiary
/// association) is editable here — mirrors add_activity_screen.dart's/
/// journey_form_screen.dart's own single-screen create/edit pattern
/// ([isEdit]) rather than two separate widgets, so the validation/save logic
/// has exactly one implementation for both flows.
///
/// Distinct from #52's quick-create (minimal fields, a bottom sheet) and
/// #53's list (read-only rows): this is the "Tarefas · Form" screen from the
/// prototype where ALL of a todo's fields are viewed and edited.
///
/// Offline-first (FR-OF-1): every write goes through [TodosRepository] —
/// queued for the write-back seam like every other local-first write in
/// this app — never a direct REST call (this repository's own doc comment).
/// [update] always resubmits every field as a FULL patch, matching
/// [TodosRepository.update]'s own established convention: an omitted due
/// date/assignee/apiary means "clear it".
class TodoFormScreen extends ConsumerStatefulWidget {
  const TodoFormScreen({this.todoId, super.key});

  /// Null for create; the todo being viewed/edited/completed/deleted for
  /// edit.
  final String? todoId;

  bool get isEdit => todoId != null;

  @override
  ConsumerState<TodoFormScreen> createState() => _TodoFormScreenState();
}

class _TodoFormScreenState extends ConsumerState<TodoFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();

  String _priority = todoPriorityMedium;
  DateTime? _dueDate;
  String? _assigneeId;
  String? _apiaryId;
  // Local status/completedAt mirror (#293) — this form loads the existing
  // todo ONCE via `getById` (like add_activity_screen.dart/
  // journey_form_screen.dart's own `_loadExisting`, not a live watch), so the
  // complete/reopen toggle updates THIS local copy directly on success
  // (mirrors journey_form_screen.dart's own `_close()`), rather than relying
  // on a provider that was never watching for live changes in the first
  // place.
  String _status = 'open';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.isEdit) _loadExisting();
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  /// Loads the existing todo and pre-fills every field (#293 AC: "view and
  /// edit every field") — mirrors add_activity_screen.dart's own
  /// `_loadExisting`, including its error handling and its "l10n/messenger
  /// only read inside the catch block" rule.
  Future<void> _loadExisting() async {
    setState(() => _busy = true);
    try {
      final repo = await ref.read(todosRepositoryProvider.future);
      final existing = await repo.getById(widget.todoId!);
      if (!mounted) return;
      if (existing != null) {
        _titleController.text = existing.title;
        _descriptionController.text = existing.description ?? '';
        _priority = existing.priority;
        _dueDate = existing.dueDate == null
            ? null
            : DateTime.tryParse(existing.dueDate!);
        _assigneeId = existing.assigneeId;
        _apiaryId = existing.apiaryId;
        _status = existing.status;
      }
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.todoLoadError('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Due dates can legitimately be in the FUTURE (#293 AC) — unlike
  /// add_activity_screen.dart's own `_pickDate` (occurredAt, capped at
  /// today+1), this deliberately does NOT cap `lastDate` at today.
  Future<void> _pickDueDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  void _clearDueDate() => setState(() => _dueDate = null);

  /// Saves via [TodosRepository.create] (add) or [TodosRepository.update]
  /// (#293, edit) depending on [isEdit] — a FULL resubmit of all six fields,
  /// matching the repository's own established convention (an omitted due
  /// date/assignee/apiary means "clear"). Navigates to the saved todo's
  /// detail on success (create -> the new todo; edit -> the same todo, so
  /// the user sees their saved changes).
  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(todosRepositoryProvider.future);
      final title = _titleController.text.trim();
      final description = _descriptionController.text.trim();
      final dueDate = _dueDate == null ? null : _isoDate(_dueDate!);
      String savedId;
      if (widget.isEdit) {
        savedId = widget.todoId!;
        await repo.update(
          savedId,
          title: title,
          priority: _priority,
          description: description.isEmpty ? null : description,
          dueDate: dueDate,
          assigneeId: _assigneeId,
          apiaryId: _apiaryId,
        );
      } else {
        savedId = await repo.create(
          title: title,
          priority: _priority,
          description: description.isEmpty ? null : description,
          dueDate: dueDate,
          assigneeId: _assigneeId,
          apiaryId: _apiaryId,
        );
      }
      if (!mounted) return;
      context.go('/todos/$savedId');
      messenger.showSnackBar(SnackBar(content: Text(l10n.todoSaveSuccess)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(l10n.todoSaveError('$e'))));
    }
  }

  /// Toggles complete/reopen IN PLACE (#293 AC) — a narrow status-only write
  /// via [TodosRepository.complete]/[TodosRepository.reopen] (never a full
  /// [TodosRepository.update] resubmit), updating this form's own local
  /// [_status] mirror directly on success rather than navigating away.
  Future<void> _toggleComplete() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final wasDone = _status == 'done';
    setState(() => _busy = true);
    try {
      final repo = await ref.read(todosRepositoryProvider.future);
      if (wasDone) {
        await repo.reopen(widget.todoId!);
      } else {
        await repo.complete(widget.todoId!);
      }
      if (!mounted) return;
      setState(() => _status = wasDone ? 'open' : 'done');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            wasDone ? l10n.todoReopenSuccess : l10n.todoCompleteSuccess,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            wasDone ? l10n.todoReopenError('$e') : l10n.todoCompleteError('$e'),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Delete confirmation (#293 AC: "delete the todo from the form") —
  /// mirrors add_activity_screen.dart's [DeleteActivityConfirmDialog]/
  /// `_confirmDelete` exactly, including the post-await `mounted` re-check.
  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const DeleteTodoConfirmDialog(),
    );
    if (!mounted) return;
    if (confirmed != true) return;
    await _delete();
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(todosRepositoryProvider.future);
      await repo.delete(widget.todoId!);
      if (!mounted) return;
      context.go('/todos');
      messenger.showSnackBar(SnackBar(content: Text(l10n.todoDeleteSuccess)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.todoDeleteError('$e'))),
      );
    }
  }

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isDone = _status == 'done';

    if (_busy && widget.isEdit && _titleController.text.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

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
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LabeledField(
                  label: l10n.todoTitleLabel,
                  child: TextFormField(
                    key: const Key('todo-title-field'),
                    controller: _titleController,
                    maxLength: 500,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? l10n.todoTitleRequired
                        : null,
                  ),
                ),
                const SizedBox(height: BrandDimens.gapField),
                LabeledField(
                  label: l10n.todoDescriptionLabel,
                  child: TextFormField(
                    key: const Key('todo-description-field'),
                    controller: _descriptionController,
                    minLines: 3,
                    maxLines: 6,
                    maxLength: 10000,
                    textInputAction: TextInputAction.newline,
                  ),
                ),
                const SizedBox(height: BrandDimens.gapField),
                _dueDateField(l10n),
                const SizedBox(height: BrandDimens.gapField),
                LabeledField(
                  label: l10n.todoPriorityFieldLabel,
                  child: DropdownButtonFormField<String>(
                    key: const Key('todo-priority-field'),
                    initialValue: _priority,
                    isExpanded: true,
                    items: [
                      for (final p in knownTodoPriorities)
                        DropdownMenuItem(
                          value: p,
                          child: Text(todoPriorityLabel(l10n, p) ?? p),
                        ),
                      // A stored priority this client version doesn't know
                      // (replicated from a newer server, D-20) still renders —
                      // mirrors add_activity_screen.dart's own `disease` field
                      // fix for the identical
                      // initialValue-must-be-in-items assertion risk.
                      if (!knownTodoPriorities.contains(_priority))
                        DropdownMenuItem(
                          value: _priority,
                          child: Text(
                            todoPriorityLabel(l10n, _priority) ?? _priority,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _priority = v);
                    },
                  ),
                ),
                const SizedBox(height: BrandDimens.gapField),
                TodoAssigneePickerField(
                  selectedAssigneeId: _assigneeId,
                  onChanged: (v) => setState(() => _assigneeId = v),
                ),
                const SizedBox(height: BrandDimens.gapField),
                TodoApiaryPickerField(
                  selectedApiaryId: _apiaryId,
                  onChanged: (v) => setState(() => _apiaryId = v),
                ),
                const SizedBox(height: 24),
                PrimaryActionButton(
                  key: const Key('todo-save-button'),
                  label: l10n.saveButton,
                  busy: _busy,
                  onPressed: _save,
                ),
                if (widget.isEdit) ...[
                  const SizedBox(height: 12),
                  SecondaryActionButton(
                    key: const Key('todo-complete-toggle-button'),
                    label: isDone
                        ? l10n.todoReopenAction
                        : l10n.todoCompleteAction,
                    icon: isDone ? Icons.replay : Icons.check_circle_outline,
                    busy: _busy,
                    onPressed: _toggleComplete,
                  ),
                  const SizedBox(height: 12),
                  SecondaryActionButton(
                    key: const Key('todo-delete-button'),
                    label: l10n.deleteTodo,
                    icon: Icons.delete_outline,
                    destructive: true,
                    busy: _busy,
                    onPressed: _confirmDelete,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dueDateField(AppLocalizations l10n) {
    final dueText = _dueDate == null
        ? l10n.todoDueDateUnset
        : LocaleFormatting.of(context).date(_dueDate!);
    return LabeledField(
      label: l10n.todoDueDateFieldLabel,
      child: InkWell(
        key: const Key('todo-due-date-field'),
        onTap: _pickDueDate,
        child: InputDecorator(
          decoration: InputDecoration(
            suffixIcon: _dueDate == null
                ? null
                : IconButton(
                    key: const Key('todo-due-date-clear-button'),
                    tooltip: l10n.todoDueDateClearAction,
                    constraints: const BoxConstraints(
                      minWidth: kMinTapTarget,
                      minHeight: kMinTapTarget,
                    ),
                    icon: const Icon(Icons.clear),
                    onPressed: _clearDueDate,
                  ),
          ),
          child: Text(dueText),
        ),
      ),
    );
  }
}

/// Confirmation dialog shown before deleting a todo (#293 AC: "delete the
/// todo from the form") — mirrors add_activity_screen.dart's
/// [DeleteActivityConfirmDialog]/journey_form_screen.dart's
/// [DeleteJourneyConfirmDialog] exactly (danger styling via the theme's
/// error color, [kMinTapTarget] tap targets, cancel/dismiss is always a
/// no-op). Pulled out as its own public widget for the same testability
/// reason those two are.
class DeleteTodoConfirmDialog extends StatelessWidget {
  const DeleteTodoConfirmDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('todo-delete-confirm-dialog'),
      icon: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
      title: Text(l10n.deleteTodoConfirmTitle),
      content: Text(l10n.deleteTodoConfirmMessage),
      actions: [
        TextButton(
          key: const Key('todo-delete-confirm-cancel'),
          style: TextButton.styleFrom(
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.deleteTodoCancelAction),
        ),
        TextButton(
          key: const Key('todo-delete-confirm-delete'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.deleteTodoConfirmAction),
        ),
      ],
    );
  }
}
