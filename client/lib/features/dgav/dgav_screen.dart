import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../l10n/gen/app_localizations.dart';
import '../apiaries/apiaries_repository.dart';
import '../organization/organization_repository.dart';
import 'dgav_registration.dart';
import 'dgav_rules.dart';
import 'stock_declarations_repository.dart';

/// The DGAV section (FR-AP-9 + FR-AP-10, #296/#298), reached from Account.
///
/// **Deliberately one quiet screen, not an app-wide presence.** Everything DGAV
/// is optional record-keeping: the September window and the interim threshold
/// are surfaced here and nowhere else — no notifications (D-24 scopes v1
/// notifications to todo reminders and sync events), no banners on the apiary
/// screens, nothing blocked anywhere. A beekeeper who never opens this screen is
/// never nagged, and the app files nothing with DGAV on their behalf (out of
/// scope per D-19's research note §7).
///
/// It holds two related things:
///
///  * the organization's **registration number** — the beekeeper number DGAV
///    issues and requires displayed at each apiary (an apiary may override it
///    from its own form, for an organization covering several beekeepers), and
///  * the **stock-declaration log**, grouped by registration number because a
///    declaration covers one beekeeper's whole holding.
class DgavScreen extends ConsumerWidget {
  const DgavScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final declarations = ref.watch(stockDeclarationsStreamProvider);
    final apiaries = ref.watch(apiariesStreamProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.dgavSectionTitle)),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(l10n.dgavIntro, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 24),
          const _OrganizationNumberField(),
          const SizedBox(height: 32),
          Text(
            l10n.dgavDeclarationsTitle,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          ...switch (declarations) {
            AsyncData(:final value) => _groups(
              context,
              ref,
              declarations: value,
              apiaries: apiaries.value ?? const [],
            ),
            AsyncError() => [Text(l10n.dgavDeclarationsEmpty)],
            _ => const [
              Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ],
          },
        ],
      ),
    );
  }

  /// One block per DGAV registration number.
  ///
  /// The set of numbers is the union of what the apiaries resolve to and what
  /// past declarations were filed under — so a beekeeper whose apiaries are all
  /// gone still sees their declaration history, and a newly-added beekeeper
  /// number shows up ready to declare against before any declaration exists.
  List<Widget> _groups(
    BuildContext context,
    WidgetRef ref, {
    required List<StockDeclaration> declarations,
    required List<Apiary> apiaries,
  }) {
    final orgDefault = ref
        .watch(organizationProvider)
        .value
        ?.dgavRegistrationNumber;

    final byNumber = <String, List<Apiary>>{};
    for (final apiary in apiaries) {
      final number =
          effectiveDgavRegistrationNumber(
            apiaryOverride: apiary.dgavRegistrationNumber,
            organizationDefault: orgDefault,
          ) ??
          '';
      byNumber.putIfAbsent(number, () => []).add(apiary);
    }
    for (final declaration in declarations) {
      byNumber.putIfAbsent(declaration.dgavRegistrationNumber, () => []);
    }
    if (byNumber.isEmpty) {
      return [Text(AppLocalizations.of(context).dgavDeclarationsEmpty)];
    }

    final numbers = byNumber.keys.toList()..sort();
    return [
      for (final number in numbers)
        _NumberGroup(
          key: Key('dgav-group-${number.isEmpty ? 'none' : number}'),
          number: number,
          apiaries: byNumber[number]!,
          declarations: declarations
              .where((d) => d.dgavRegistrationNumber == number)
              .toList(),
        ),
    ];
  }
}

/// The organization-wide registration-number field (FR-AP-9, #296).
///
/// Editing is a REST PATCH, so it needs connectivity — unlike everything else in
/// this screen, which is local-first. That is the accepted trade-off for a
/// reference number entered once (the value is still READ offline, from the
/// organization cache), and a failed save says so rather than pretending.
class _OrganizationNumberField extends ConsumerStatefulWidget {
  const _OrganizationNumberField();

  @override
  ConsumerState<_OrganizationNumberField> createState() =>
      _OrganizationNumberFieldState();
}

class _OrganizationNumberFieldState
    extends ConsumerState<_OrganizationNumberField> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _loadedFor;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final organization = ref.watch(organizationProvider).value;

    // Seed the controller once per organization rather than on every rebuild,
    // so a rebuild mid-edit (any provider this screen watches emitting) cannot
    // clobber what the user is typing.
    if (organization != null && _loadedFor != organization.id) {
      _loadedFor = organization.id;
      _controller.text = organization.dgavRegistrationNumber;
    }

    final isAdmin = organization?.role == 'admin';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('dgav-org-number-field'),
          controller: _controller,
          enabled: isAdmin && !_busy,
          maxLength: 50,
          decoration: InputDecoration(
            labelText: l10n.dgavOrgNumberLabel,
            helperText: isAdmin
                ? l10n.dgavOrgNumberHint
                : l10n.dgavOrgNumberAdminOnly,
          ),
        ),
        if (isAdmin)
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const Key('dgav-org-number-save'),
              onPressed: _busy ? null : _save,
              child: Text(MaterialLocalizations.of(context).saveButtonLabel),
            ),
          ),
      ],
    );
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      await ref
          .read(organizationProvider.notifier)
          .saveDgavRegistrationNumber(_controller.text);
      messenger.showSnackBar(SnackBar(content: Text(l10n.dgavOrgNumberSaved)));
    } on Exception {
      // Offline, a 403 for a non-admin, or a 422 for an over-long value — all
      // surface the same way rather than leaving the button spinning. The
      // specific cause is not actionable to the beekeeper beyond "try again".
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.dgavOrgNumberSaveFailed)),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// One registration number's block: its advisory status, its live hive total,
/// the action to record a declaration, and its declaration log.
class _NumberGroup extends ConsumerWidget {
  const _NumberGroup({
    super.key,
    required this.number,
    required this.apiaries,
    required this.declarations,
  });

  final String number;
  final List<Apiary> apiaries;
  final List<StockDeclaration> declarations;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final currentHives = apiaries.fold<int>(0, (sum, a) => sum + a.hiveCount);
    final status = _statusLine(l10n, currentHives);

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              number.isEmpty ? l10n.dgavNoRegistrationNumber : number,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.dgavCurrentHiveCount(currentHives),
              style: theme.textTheme.bodySmall,
            ),
            if (status != null) ...[
              const SizedBox(height: 8),
              // liveRegion so a screen reader announces the advisory status
              // when it changes, rather than leaving it to be discovered by
              // sweeping the screen (NFR-A11Y, WCAG 2.2 AA).
              Semantics(
                liveRegion: true,
                child: Text(
                  status,
                  key: Key('dgav-status-${number.isEmpty ? 'none' : number}'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                key: Key('dgav-record-${number.isEmpty ? 'none' : number}'),
                onPressed: () => _record(context, ref, currentHives),
                child: Text(l10n.dgavRecordDeclarationAction),
              ),
            ),
            const SizedBox(height: 8),
            if (declarations.isEmpty)
              Text(l10n.dgavDeclarationsEmpty)
            else
              for (final declaration in declarations)
                _DeclarationRow(declaration: declaration),
          ],
        ),
      ),
    );
  }

  /// The advisory line, or null when there is nothing worth saying.
  ///
  /// The interim trigger takes precedence over the window notice: if the stock
  /// has moved materially, that is the more urgent of the two and stacking both
  /// would just be noise.
  String? _statusLine(AppLocalizations l10n, int currentHives) {
    final today = DateTime.now();
    final last = declarations.isEmpty ? null : declarations.first;

    if (last != null &&
        isInterimTriggerMet(
          lastDeclaredCount: last.totalHiveCount,
          currentCount: currentHives,
        )) {
      return l10n.dgavInterimTriggerMet(
        currentHives - last.totalHiveCount,
        last.totalHiveCount,
        currentHives,
      );
    }

    if (!isAnnualWindowOpen(today)) return null;
    final declaredThisYear = hasDeclaredInAnnualWindow(
      declarationDates: declarations.map((d) => d.declaredOn),
      today: today,
    );
    return declaredThisYear ? l10n.dgavWindowOpenDeclared : l10n.dgavWindowOpen;
  }

  /// Records a declaration for this registration number, snapshotting the
  /// current per-apiary hive counts.
  ///
  /// The snapshot is taken here rather than derived later on purpose: a
  /// declaration must keep saying what it said even after the apiaries are
  /// renamed, re-counted, or deleted (FR-AP-10).
  Future<void> _record(
    BuildContext context,
    WidgetRef ref,
    int currentHives,
  ) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);

    // Ask for the date and an optional note rather than writing
    // immediately. Two reasons: a beekeeper files with DGAV first and logs
    // it here afterwards, so "today" is often the WRONG date and there must
    // be a way to say so (FR-AP-10 captures the declaration date, not the
    // record-keeping date); and a regulatory record appearing from a single
    // unconfirmed tap is abrupt for something that is only correctable by
    // deleting it.
    final result = await showDialog<_DeclarationDraft>(
      context: context,
      builder: (context) => _RecordDeclarationDialog(totalHives: currentHives),
    );
    if (result == null) return;

    final repo = await ref.read(stockDeclarationsRepositoryProvider.future);
    await repo.create(
      dgavRegistrationNumber: number,
      declaredOn: result.declaredOn,
      totalHiveCount: currentHives,
      // The snapshot is taken NOW, from the live counters, even when the
      // declaration is back-dated: it records what this app knows the
      // holding to be, which is the only per-apiary breakdown it can
      // honestly produce. Reconstructing counts as they stood on an earlier
      // date would need per-apiary history this screen does not read.
      breakdown: [
        for (final apiary in apiaries)
          StockDeclarationApiary(
            apiaryId: apiary.id,
            name: apiary.name,
            hiveCount: apiary.hiveCount,
          ),
      ],
      notes: result.notes,
    );
    messenger.showSnackBar(SnackBar(content: Text(l10n.dgavDeclarationSaved)));
  }
}

/// One recorded declaration, with the action to remove a mis-entered one.
class _DeclarationRow extends ConsumerWidget {
  const _DeclarationRow({required this.declaration});

  final StockDeclaration declaration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      key: Key('dgav-declaration-${declaration.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text(
        l10n.dgavDeclarationSummary(
          // Localized (LocaleFormatting → intl DateFormat.yMMMd), matching every
          // other date in the app. The raw YYYY-MM-DD form is the STORAGE
          // shape — right for the column and the wire, wrong to show a
          // beekeeper, and inconsistent with the activity/todo screens.
          LocaleFormatting.of(context).date(declaration.declaredOn),
          declaration.totalHiveCount,
        ),
      ),
      subtitle: Text(
        l10n.dgavDeclarationApiaryCount(declaration.breakdown.length),
      ),
      trailing: IconButton(
        key: Key('dgav-declaration-delete-${declaration.id}'),
        tooltip: l10n.dgavDeclarationDeleteAction,
        icon: const Icon(Icons.delete_outline),
        onPressed: () async {
          final repo = await ref.read(
            stockDeclarationsRepositoryProvider.future,
          );
          await repo.delete(declaration.id);
        },
      ),
    );
  }
}

/// What the record-declaration dialog returns: the date the declaration was
/// filed, and an optional note. Null from the dialog means cancelled.
class _DeclarationDraft {
  const _DeclarationDraft({required this.declaredOn, this.notes});

  final DateTime declaredOn;
  final String? notes;
}

/// Collects the declaration date and an optional note before a declaration is
/// written (FR-AP-10, #298).
///
/// The date defaults to today but is editable, and cannot be in the future — a
/// declaration records something that has been filed, not something planned.
/// The declared hive total is shown read-only: it comes from the live counters
/// at record time and is what makes this a snapshot rather than a form.
class _RecordDeclarationDialog extends StatefulWidget {
  const _RecordDeclarationDialog({required this.totalHives});

  final int totalHives;

  @override
  State<_RecordDeclarationDialog> createState() =>
      _RecordDeclarationDialogState();
}

class _RecordDeclarationDialogState extends State<_RecordDeclarationDialog> {
  late DateTime _declaredOn = DateTime.now();
  final _notesController = TextEditingController();

  @override
  void dispose() {
    _notesController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final formatting = LocaleFormatting.of(context);

    return AlertDialog(
      title: Text(l10n.dgavRecordDialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.dgavDeclarationHiveTotal(widget.totalHives)),
          const SizedBox(height: 16),
          // A tappable row rather than a bare text button so the target
          // comfortably clears the 44x44 gloves-friendly minimum (D-18).
          InkWell(
            key: const Key('dgav-declaration-date-field'),
            onTap: _pickDate,
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: l10n.dgavDeclarationDateLabel,
                suffixIcon: const Icon(Icons.calendar_today_outlined),
              ),
              child: Text(formatting.date(_declaredOn)),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('dgav-declaration-notes-field'),
            controller: _notesController,
            maxLength: 2000,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: l10n.dgavDeclarationNotesLabel,
              hintText: l10n.dgavDeclarationNotesHint,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const Key('dgav-record-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.dgavRecordDialogCancelAction),
        ),
        FilledButton(
          key: const Key('dgav-record-confirm'),
          onPressed: () {
            final notes = _notesController.text.trim();
            Navigator.of(context).pop(
              _DeclarationDraft(
                declaredOn: _declaredOn,
                notes: notes.isEmpty ? null : notes,
              ),
            );
          },
          child: Text(l10n.dgavRecordDialogConfirmAction),
        ),
      ],
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _declaredOn,
      // A declaration is filed, then logged — so earlier dates are the point,
      // and future ones are meaningless. Five years back comfortably covers
      // back-filling a history of annual declarations.
      firstDate: DateTime(now.year - 5),
      lastDate: now,
    );
    if (picked != null) setState(() => _declaredOn = picked);
  }
}
