import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../l10n/gen/app_localizations.dart';
import 'apiaries_repository.dart';

/// Create (when [apiaryId] is null) or edit an apiary. Writes go local-first
/// through the repository; there is no direct REST write (walking-skeleton.md
/// §4.4).
class ApiaryFormScreen extends ConsumerStatefulWidget {
  const ApiaryFormScreen({this.apiaryId, super.key});

  final String? apiaryId;
  bool get isEdit => apiaryId != null;

  @override
  ConsumerState<ApiaryFormScreen> createState() => _ApiaryFormScreenState();
}

class _ApiaryFormScreenState extends ConsumerState<ApiaryFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _hiveController = TextEditingController(text: '0');
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.isEdit) _loadExisting();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hiveController.dispose();
    super.dispose();
  }

  Future<void> _loadExisting() async {
    setState(() => _busy = true);
    final repo = await ref.read(apiariesRepositoryProvider.future);
    final existing = await repo.getById(widget.apiaryId!);
    if (!mounted) return;
    if (existing != null) {
      _nameController.text = existing.name;
      _hiveController.text = existing.hiveCount.toString();
    }
    setState(() => _busy = false);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final repo = await ref.read(apiariesRepositoryProvider.future);
    final name = _nameController.text.trim();
    final hives = int.tryParse(_hiveController.text.trim()) ?? 0;
    if (widget.isEdit) {
      await repo.update(widget.apiaryId!, name: name, hiveCount: hives);
    } else {
      await repo.create(name: name, hiveCount: hives);
    }
    if (mounted) context.go('/apiaries');
  }

  Future<void> _delete() async {
    setState(() => _busy = true);
    final repo = await ref.read(apiariesRepositoryProvider.future);
    await repo.delete(widget.apiaryId!);
    if (mounted) context.go('/apiaries');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/apiaries'),
        ),
        title: Text(widget.isEdit ? l10n.editApiaryTitle : l10n.newApiaryTitle),
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        TextFormField(
                          key: const Key('apiary-name-field'),
                          controller: _nameController,
                          autofocus: !widget.isEdit,
                          decoration: InputDecoration(
                            labelText: l10n.apiaryNameLabel,
                            border: const OutlineInputBorder(),
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? l10n.apiaryNameRequired
                              : null,
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          key: const Key('apiary-hive-field'),
                          controller: _hiveController,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: InputDecoration(
                            labelText: l10n.hiveCountLabel,
                            border: const OutlineInputBorder(),
                          ),
                          validator: (v) {
                            final n = int.tryParse((v ?? '').trim());
                            return (n == null || n < 0)
                                ? l10n.hiveCountInvalid
                                : null;
                          },
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          key: const Key('apiary-save-button'),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(56),
                          ),
                          onPressed: _save,
                          child: Text(l10n.saveButton),
                        ),
                        if (widget.isEdit) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            key: const Key('apiary-delete-button'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(56),
                              foregroundColor:
                                  Theme.of(context).colorScheme.error,
                            ),
                            onPressed: _delete,
                            icon: const Icon(Icons.delete_outline),
                            label: Text(l10n.deleteApiary),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
