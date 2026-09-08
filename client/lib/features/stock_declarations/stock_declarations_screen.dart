import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/l10n/locale_formatting.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/widgets/content_column.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_widgets.dart';
import '../apiaries/apiaries_repository.dart';
import '../organization/organization_repository.dart';
import '../organization/registration_number.dart';
import 'stock_declarations_repository.dart';

/// The stock-declaration log (FR-AP-10, #298), reached from Account.
///
/// **Deliberately one quiet screen, not an app-wide presence.** Recording a
/// declaration is optional record-keeping: no notifications (D-24 scopes v1
/// notifications to todo reminders and sync events), no banners on the apiary
/// screens, nothing blocked anywhere. A beekeeper who never opens this screen
/// is never nagged, and the app files nothing with any authority on their
/// behalf (out of scope per D-19's research note §7).
///
/// The log is grouped by **registration number** because a declaration covers
/// one beekeeper's whole holding. The number itself is not edited here — it
/// belongs to the organization (and optionally to an apiary), and is edited on
/// the organization-details screen and the apiary form respectively.
class StockDeclarationsScreen extends ConsumerWidget {
  const StockDeclarationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final declarations = ref.watch(stockDeclarationsStreamProvider);
    final apiaries = ref.watch(apiariesStreamProvider);

    return Scaffold(
      appBar: AppBar(
        // The route is declared outside the app shell, so there is no bottom
        // navigation to leave by and — with the manifest's `"display":
        // "standalone"` — no browser back button either. Without this the
        // screen was a hard dead end (#639, FR-UX-2). Back to Account, the
        // screen that links here. The needs-fix list's "Fix" action is the
        // only other way in, and going back from here lands on Account rather
        // than on that list — which is where the needs-fix screen's OWN back
        // button goes too, so the two exits agree.
        leading: IconButton(
          key: const Key('stock-declarations-back-button'),
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => context.go('/account'),
        ),
        title: Text(l10n.stockDeclarationsTitle),
      ),
      // ContentColumn (#650): caps the log at BrandDimens.maxWidthList on a
      // wide desktop viewport rather than stretching it across the window.
      body: ContentColumn(
        child: ListView(
          // The bottom gutter is the chrome band, not a gutter (#773): the
          // "Declaration recorded" toast this screen raises used to land on
          // the registration-number card it had just been recorded against.
          // No FAB and no bottom navigation here — the route is declared
          // outside the shell — so the band is the toast's own height, which
          // out here includes the home-indicator inset the toast's bar
          // carries; `scrollBottomInsetOf` adds it.
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            BrandDimens.scrollBottomInsetOf(context),
          ),
          children: [
            Text(
              l10n.stockDeclarationsIntro,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            ...switch (declarations) {
              AsyncData(:final value) => _groups(
                context,
                ref,
                declarations: value,
                apiaries: apiaries.value ?? const [],
              ),
              AsyncError() => [Text(l10n.stockDeclarationsEmpty)],
              _ => const [
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ],
            },
          ],
        ),
      ),
    );
  }

  /// One block per registration number.
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
        ?.registrationNumber;

    final byNumber = <String, List<Apiary>>{};
    for (final apiary in apiaries) {
      final number =
          effectiveRegistrationNumber(
            apiaryOverride: apiary.registrationNumber,
            organizationDefault: orgDefault,
          ) ??
          '';
      byNumber.putIfAbsent(number, () => []).add(apiary);
    }
    for (final declaration in declarations) {
      byNumber.putIfAbsent(declaration.registrationNumber, () => []);
    }
    if (byNumber.isEmpty) {
      return [Text(AppLocalizations.of(context).stockDeclarationsEmpty)];
    }

    final numbers = byNumber.keys.toList()..sort();
    return [
      for (final number in numbers)
        _NumberGroup(
          key: Key(
            'stock-declarations-group-${number.isEmpty ? 'none' : number}',
          ),
          number: number,
          apiaries: byNumber[number]!,
          declarations: declarations
              .where((d) => d.registrationNumber == number)
              .toList(),
        ),
    ];
  }
}

/// One registration number's block: its live hive total, the action to record a
/// declaration, and its declaration log.
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
    final slug = number.isEmpty ? 'none' : number;

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              number.isEmpty
                  ? l10n.stockDeclarationsNoRegistrationNumber
                  : number,
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(
              l10n.stockDeclarationsCurrentHiveCount(currentHives),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.tonal(
                key: Key('stock-declarations-record-$slug'),
                onPressed: () => _record(context, ref, currentHives),
                child: Text(l10n.stockDeclarationRecordAction),
              ),
            ),
            const SizedBox(height: 8),
            if (declarations.isEmpty)
              Text(l10n.stockDeclarationsEmpty)
            else
              for (final declaration in declarations)
                _DeclarationRow(declaration: declaration),
          ],
        ),
      ),
    );
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
    // immediately. Two reasons: a beekeeper files with the authority first
    // and logs it here afterwards, so "today" is often the WRONG date and
    // there must be a way to say so (FR-AP-10 captures the declaration date,
    // not the record-keeping date); and a regulatory record appearing from a
    // single unconfirmed tap is abrupt for something that is only correctable
    // by deleting it.
    final result = await showDialog<_DeclarationDraft>(
      context: context,
      builder: (context) => _RecordDeclarationDialog(totalHives: currentHives),
    );
    if (result == null) return;

    final repo = await ref.read(stockDeclarationsRepositoryProvider.future);
    await repo.create(
      registrationNumber: number,
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
    showAppToast(messenger, l10n.stockDeclarationSaved);
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
      key: Key('stock-declaration-${declaration.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text(
        l10n.stockDeclarationSummary(
          // Localized (LocaleFormatting → intl DateFormat.yMMMd), matching every
          // other date in the app. The raw YYYY-MM-DD form is the STORAGE
          // shape — right for the column and the wire, wrong to show a
          // beekeeper, and inconsistent with the activity/todo screens.
          LocaleFormatting.of(context).date(declaration.declaredOn),
          declaration.totalHiveCount,
        ),
      ),
      subtitle: Text(
        l10n.stockDeclarationApiaryCount(declaration.breakdown.length),
      ),
      trailing: IconButton(
        key: Key('stock-declaration-delete-${declaration.id}'),
        tooltip: l10n.stockDeclarationDeleteAction,
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
      title: Text(l10n.stockDeclarationRecordDialogTitle),
      // Scrollable content: the dialog's body has a hard height budget on a
      // short viewport, and it was already over it at a large OS text scale
      // (a bare Column overflowed by 30px at 360x640 / 1.5x before #629, and
      // the two labels this issue moves above their fields cost it more).
      // A RenderFlex overflow does not just look wrong — the clipped part is
      // unreachable, which here is the Note field (FR-AX-1, D-18).
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.stockDeclarationHiveTotal(widget.totalHives)),
            const SizedBox(height: 16),
            // One label pattern app-wide (#629, FR-UX-1): both labels sit ABOVE
            // their field, never animated into the box border.
            LabeledField(
              label: l10n.stockDeclarationDateLabel,
              // A tappable row rather than a bare text button so the target
              // comfortably clears the 44x44 gloves-friendly minimum (D-18).
              child: InkWell(
                key: const Key('stock-declaration-date-field'),
                onTap: _pickDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    suffixIcon: Icon(Icons.calendar_today_outlined),
                  ),
                  child: Text(formatting.date(_declaredOn)),
                ),
              ),
            ),
            const SizedBox(height: 16),
            LabeledField(
              label: l10n.stockDeclarationNotesLabel,
              child: TextField(
                key: const Key('stock-declaration-notes-field'),
                controller: _notesController,
                maxLength: 2000,
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: l10n.stockDeclarationNotesHint,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('stock-declaration-record-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.stockDeclarationRecordDialogCancelAction),
        ),
        FilledButton(
          key: const Key('stock-declaration-record-confirm'),
          onPressed: () {
            final notes = _notesController.text.trim();
            Navigator.of(context).pop(
              _DeclarationDraft(
                declaredOn: _declaredOn,
                notes: notes.isEmpty ? null : notes,
              ),
            );
          },
          child: Text(l10n.stockDeclarationRecordDialogConfirmAction),
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
