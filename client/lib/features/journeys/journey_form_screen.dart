import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/widgets/field_action_button.dart';
import '../../core/widgets/tap_target.dart';
import '../../l10n/gen/app_localizations.dart';
import '../activities/activity_types.dart';
import 'apiary_multi_select_field.dart';
import 'journey_status.dart';
import 'journeys_repository.dart';

/// Create a journey (#45, FR-JO-4), or — when [journeyId] is given — edit an
/// existing one (name, main activity type, apiaries-to-visit plan) and
/// close it (D-21). Mirrors add_activity_screen.dart's own single-screen
/// create/edit pattern ([isEdit]) rather than two separate widgets, so the
/// validation/save logic has exactly one implementation for both flows.
/// Delete rides along here too, as a destructive action only shown in edit
/// mode — mirroring [AddActivityScreen]'s own delete-button-on-the-edit-form
/// placement, since there is no dedicated journey detail screen yet (#48).
///
/// Offline-first (FR-OF-1/Q-SYNC): every write goes straight to the local
/// store via [JourneysRepository] — queued for the write-back seam like
/// every other local-first write in this app. `organization_id` is derived
/// server-side from the caller's token once the queued write reconciles.
class JourneyFormScreen extends ConsumerStatefulWidget {
  const JourneyFormScreen({this.journeyId, super.key});

  /// Null for create; the journey being edited/closed/deleted for edit.
  final String? journeyId;

  bool get isEdit => journeyId != null;

  @override
  ConsumerState<JourneyFormScreen> createState() => _JourneyFormScreenState();
}

class _JourneyFormScreenState extends ConsumerState<JourneyFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  String _mainActivityType = activityTypeHarvest;
  String _status = journeyStatusOpen;
  Set<String> _apiaryIds = {};
  bool _busy = false;
  String? _apiaryIdsError;

  @override
  void initState() {
    super.initState();
    if (widget.isEdit) _loadExisting();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// Loads the existing journey and pre-fills the form (mirrors
  /// add_activity_screen.dart's own `_loadExisting`, including its error
  /// handling and its "l10n/messenger only read inside the catch block"
  /// rule).
  Future<void> _loadExisting() async {
    setState(() => _busy = true);
    try {
      final repo = await ref.read(journeysRepositoryProvider.future);
      final existing = await repo.getById(widget.journeyId!);
      if (!mounted) return;
      if (existing != null) {
        _nameController.text = existing.name;
        _mainActivityType = existing.mainActivityType;
        _status = existing.status;
        _apiaryIds = existing.apiaryIds.toSet();
      }
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.journeyLoadError('$e'))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _validate(AppLocalizations l10n) {
    final formOk = _formKey.currentState!.validate();
    final hasApiary = _apiaryIds.isNotEmpty;
    setState(() {
      _apiaryIdsError = hasApiary ? null : l10n.journeyApiariesRequired;
    });
    return formOk && hasApiary;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    if (!_validate(l10n)) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(journeysRepositoryProvider.future);
      final name = _nameController.text.trim();
      if (widget.isEdit) {
        await repo.update(
          widget.journeyId!,
          name: name,
          mainActivityType: _mainActivityType,
          status: _status,
          apiaryIds: _apiaryIds.toList(),
        );
      } else {
        await repo.create(
          name: name,
          mainActivityType: _mainActivityType,
          apiaryIds: _apiaryIds.toList(),
        );
      }
      if (!mounted) return;
      context.go('/journeys');
      messenger.showSnackBar(SnackBar(content: Text(l10n.journeySaveSuccess)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.journeySaveError('$e'))),
      );
    }
  }

  /// Closes the journey in place (D-21) — no confirmation dialog (unlike
  /// delete): closing only changes visibility in the #46 activity-form
  /// picker's default view, it never discards data.
  Future<void> _close() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(journeysRepositoryProvider.future);
      await repo.close(widget.journeyId!);
      if (!mounted) return;
      setState(() {
        _status = journeyStatusClosed;
        _busy = false;
      });
      messenger.showSnackBar(SnackBar(content: Text(l10n.journeyCloseSuccess)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.journeyCloseError('$e'))),
      );
    }
  }

  /// Delete confirmation — mirrors add_activity_screen.dart's
  /// [DeleteActivityConfirmDialog]/`_confirmDelete` exactly, including the
  /// post-await `mounted` re-check.
  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => const DeleteJourneyConfirmDialog(),
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
      final repo = await ref.read(journeysRepositoryProvider.future);
      await repo.delete(widget.journeyId!);
      if (!mounted) return;
      context.go('/journeys');
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.journeyDeleteSuccess)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.journeyDeleteError('$e'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isClosed = _status == journeyStatusClosed;

    if (_busy && widget.isEdit && _nameController.text.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.isEdit)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: _StatusChip(status: _status),
                  ),
                TextFormField(
                  key: const Key('journey-name-field'),
                  controller: _nameController,
                  maxLength: 200,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? l10n.journeyNameRequired
                      : null,
                  decoration: InputDecoration(
                    labelText: l10n.journeyNameLabel,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: const Key('journey-main-activity-type-field'),
                  initialValue: _mainActivityType,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l10n.journeyMainActivityTypeLabel,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final type in knownActivityTypes)
                      DropdownMenuItem(
                        value: type,
                        child: Text(activityTypeLabel(l10n, type) ?? type),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _mainActivityType = value);
                    }
                  },
                ),
                const SizedBox(height: 16),
                ApiaryMultiSelectField(
                  selectedApiaryIds: _apiaryIds,
                  onChanged: (ids) => setState(() {
                    _apiaryIds = ids;
                    _apiaryIdsError = null;
                  }),
                ),
                if (_apiaryIdsError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(
                      _apiaryIdsError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 12,
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                PrimaryActionButton(
                  key: const Key('journey-save-button'),
                  label: l10n.saveButton,
                  busy: _busy,
                  onPressed: _save,
                ),
                if (widget.isEdit && !isClosed) ...[
                  const SizedBox(height: 12),
                  SecondaryActionButton(
                    key: const Key('journey-close-button'),
                    label: l10n.closeJourneyAction,
                    icon: Icons.lock_outline,
                    busy: _busy,
                    onPressed: _close,
                  ),
                ],
                if (widget.isEdit) ...[
                  const SizedBox(height: 12),
                  SecondaryActionButton(
                    key: const Key('journey-delete-button'),
                    label: l10n.deleteJourney,
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
}

/// D-21's status indicator on the edit form — closed reads as muted, not
/// alarming (mirrors journeys_list_screen.dart's own `_StatusBadge`
/// styling), with a semantics label so a screen-reader user hears the
/// journey's current lifecycle state up front.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final closed = status == journeyStatusClosed;
    final label = journeyStatusLabel(l10n, status) ?? status;
    return Semantics(
      label: l10n.journeyStatusSemanticLabel(label),
      child: Container(
        key: const Key('journey-form-status-chip'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: closed
              ? theme.colorScheme.surfaceContainerHighest
              : theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: ExcludeSemantics(
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: closed
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ),
      ),
    );
  }
}

/// Confirmation dialog shown before deleting a journey — mirrors
/// add_activity_screen.dart's [DeleteActivityConfirmDialog] exactly (same
/// field-first-checklist rationale: danger styling via the theme's error
/// color, 44px+ tap targets via [kMinTapTarget], cancel/dismiss is always a
/// no-op). Pulled out as its own public widget for the same testability
/// reason [DeleteActivityConfirmDialog] is.
class DeleteJourneyConfirmDialog extends StatelessWidget {
  const DeleteJourneyConfirmDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('journey-delete-confirm-dialog'),
      icon: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
      title: Text(l10n.deleteJourneyConfirmTitle),
      content: Text(l10n.deleteJourneyConfirmMessage),
      actions: [
        TextButton(
          key: const Key('journey-delete-confirm-cancel'),
          style: TextButton.styleFrom(
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.deleteJourneyCancelAction),
        ),
        TextButton(
          key: const Key('journey-delete-confirm-delete'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.deleteJourneyConfirmAction),
        ),
      ],
    );
  }
}
