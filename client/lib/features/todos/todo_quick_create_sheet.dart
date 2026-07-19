import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import 'todo_priority.dart';
import 'todos_repository.dart';

/// Opens the shared quick-create bottom sheet (#52, FR-TD-1, FR-UX-1,
/// FR-UX-2) — the FIRST todo create affordance in the app, reachable from
/// three entry points: the Todos tab's own FAB, the Apiaries tab's secondary
/// FAB, and the apiary detail page's "New todo" action (app_shell.dart,
/// apiary_detail_screen.dart). The last two pass [initialApiaryId] (and
/// [initialApiaryName] for display) to pre-associate that apiary — a
/// read-only chip, never an editable picker: quick-create's whole point is a
/// minimal field set (FR-UX-1), the association comes entirely from WHERE
/// the sheet was opened, not a choice made inside it. A full apiary picker
/// belongs to the eventual full create/edit form (#293), out of scope here.
///
/// Deliberately minimal (FR-UX-1: "large, gloves-friendly tap targets and a
/// minimal field set suitable for field use"): title, priority, due date —
/// no description, assignee or apiary picker. Shape mirrors
/// journey_quick_create_sheet.dart's own quick-create sheet
/// (`ConsumerStatefulWidget`, `GlobalKey<FormState>`, PrimaryActionButton/
/// SecondaryActionButton, keyboard-inset padding, busy state, a
/// pre-captured ScaffoldMessenger, mounted-checks around the awaited
/// create() call) — but `isDismissible: true`/`enableDrag: true` (the
/// journey sheet uses `false`/`false`): that sheet is a required step
/// mid-way through logging an activity, this one is a standalone action the
/// user can back out of casually at any time.
///
/// Creating a todo here goes through [TodosRepository.create] — the same
/// local-first write path (queued for the write-back seam,
/// services/todos/api/sync.go) every other todo write already uses, so the
/// new row appears immediately in the local store (offline-first AC) and is
/// recorded in history on the server's own apply (`writeTodoAuditLog`,
/// FR-HIS-1) with no client-side work needed beyond routing through this
/// same create() call.
///
/// Returns the new todo's id, or null if the user canceled.
Future<String?> showTodoQuickCreateSheet(
  BuildContext context, {
  String? initialApiaryId,
  String? initialApiaryName,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _TodoQuickCreateSheet(
      initialApiaryId: initialApiaryId,
      initialApiaryName: initialApiaryName,
    ),
  );
}

class _TodoQuickCreateSheet extends ConsumerStatefulWidget {
  const _TodoQuickCreateSheet({this.initialApiaryId, this.initialApiaryName});

  final String? initialApiaryId;
  final String? initialApiaryName;

  @override
  ConsumerState<_TodoQuickCreateSheet> createState() =>
      _TodoQuickCreateSheetState();
}

class _TodoQuickCreateSheetState extends ConsumerState<_TodoQuickCreateSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  String _priority = todoPriorityMedium;
  DateTime? _dueDate;
  bool _busy = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  void _clearDueDate() => setState(() => _dueDate = null);

  Future<void> _create() async {
    final l10n = AppLocalizations.of(context);
    if (!_formKey.currentState!.validate()) return;
    // Captured BEFORE the await (this class's own doc: mirrors
    // journey_quick_create_sheet.dart's convention) — the sheet's own
    // BuildContext may be gone by the time create() resolves.
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(todosRepositoryProvider.future);
      final id = await repo.create(
        title: _titleController.text.trim(),
        priority: _priority,
        dueDate: _dueDate == null ? null : _isoDate(_dueDate!),
        apiaryId: widget.initialApiaryId,
      );
      if (!mounted) return;
      Navigator.of(context).pop(id);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.todoCreatedConfirmation)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(l10n.todoSaveError('$e'))));
    }
  }

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        // The fields scroll, the action row stays pinned: with the
        // gloves-friendly control heights (58px fields, 60px primary button —
        // BrandDimens) this sheet's natural height exceeds a small phone's
        // viewport, and a single scroll view around EVERYTHING would push
        // Save/Cancel below the fold where a user in the field can't reach
        // them. Keeping the actions outside the scrollable keeps them
        // reachable at any screen size, text scale, or future field count.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        l10n.todoQuickCreateTitle,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      if (widget.initialApiaryId != null) ...[
                        _ApiaryChip(
                          name:
                              widget.initialApiaryName ??
                              widget.initialApiaryId!,
                        ),
                        const SizedBox(height: 16),
                      ],
                      TextFormField(
                        key: const Key('todo-quick-create-title-field'),
                        controller: _titleController,
                        autofocus: true,
                        maxLength: 200,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? l10n.todoTitleRequired
                            : null,
                        decoration: InputDecoration(
                          labelText: l10n.todoTitleLabel,
                        ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        key: const Key('todo-quick-create-priority-field'),
                        initialValue: _priority,
                        isExpanded: true,
                        decoration: InputDecoration(
                          // Reuses the Todos tab's own filter-label copy (DRY)
                          // — same concept ("Priority"), no second key needed.
                          labelText: l10n.todoFilterPriorityLabel,
                        ),
                        items: [
                          for (final p in knownTodoPriorities)
                            DropdownMenuItem(
                              value: p,
                              child: Text(todoPriorityLabel(l10n, p) ?? p),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _priority = value);
                        },
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              key: const Key(
                                'todo-quick-create-due-date-field',
                              ),
                              onTap: _pickDueDate,
                              child: InputDecorator(
                                decoration: InputDecoration(
                                  labelText: l10n.todoDueDateLabel,
                                ),
                                child: Text(
                                  _dueDate == null
                                      ? l10n.todoDueDateUnset
                                      : LocaleFormatting.of(
                                          context,
                                        ).date(_dueDate!),
                                ),
                              ),
                            ),
                          ),
                          if (_dueDate != null)
                            IconButton(
                              key: const Key(
                                'todo-quick-create-due-date-clear-button',
                              ),
                              tooltip: l10n.todoDueDateClearAction,
                              icon: const Icon(Icons.clear),
                              onPressed: _clearDueDate,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: SecondaryActionButton(
                    key: const Key('todo-quick-create-cancel-button'),
                    label: l10n.todoQuickCreateCancelAction,
                    busy: false,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: PrimaryActionButton(
                    key: const Key('todo-quick-create-save-button'),
                    label: l10n.saveButton,
                    busy: _busy,
                    onPressed: _create,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Read-only "For {apiary name}" chip (#52, FR-UX-2) — the contextual-create
/// entry points (apiaries-tab secondary FAB, apiary detail page) pre-fill
/// [_TodoQuickCreateSheetState.widget]'s `initialApiaryId` and show this
/// instead of an editable picker, since quick-create never lets the user
/// change the association — see this file's own top-level doc comment.
class _ApiaryChip extends StatelessWidget {
  const _ApiaryChip({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Chip(
        key: const Key('todo-quick-create-apiary-chip'),
        avatar: Icon(
          Icons.hive_outlined,
          size: 18,
          color: theme.colorScheme.onSecondaryContainer,
        ),
        label: Text(l10n.todoQuickCreateForApiary(name)),
        backgroundColor: theme.colorScheme.secondaryContainer,
        labelStyle: TextStyle(color: theme.colorScheme.onSecondaryContainer),
      ),
    );
  }
}
