import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/gen/app_localizations.dart';
import 'tap_target.dart';

/// Shared unsaved-changes guard for edit/create screens (#345, FR-UX-1,
/// FR-UX-2, FR-AX-1, D-18).
///
/// A non-read-only screen must not let the user navigate away and silently
/// lose pending edits. There are two distinct navigation paths to intercept,
/// and they need two different mechanisms:
///
/// - **Pops** — the OS/browser back gesture and the app shell's own back
///   button ([AppShell] routes the latter through the branch navigator's
///   `maybePop`). These are caught by the [PopScope] that
///   [UnsavedChangesMixin.buildUnsavedChangesGuard] wraps the form body in.
/// - **`context.go`-style route changes** — switching bottom-nav tabs and the
///   header's account/sync buttons. A [PopScope] never sees these (they
///   replace the location rather than popping), so the shell consults
///   [unsavedChangesProvider] instead and prompts before navigating.
///
/// Read-only screens don't mix in [UnsavedChangesMixin], so they never touch
/// the provider and navigate freely (state stays `false`).
class UnsavedChangesController extends Notifier<bool> {
  @override
  bool build() => false;

  void markDirty() {
    if (!state) state = true;
  }

  void markClean() {
    if (state) state = false;
  }
}

/// Whether the foreground edit/create screen currently has unsaved edits.
/// Watched by the app shell to decide whether a tab-switch / header navigation
/// needs a confirm-discard prompt first.
final unsavedChangesProvider = NotifierProvider<UnsavedChangesController, bool>(
  UnsavedChangesController.new,
);

/// The confirm-discard dialog (#345). Field-first (D-18): 44x44 tap targets,
/// localized EN/PT, `Keep editing` reads as the safe default and `Discard` is
/// tinted with the theme error color so a gloved user isn't nudged into losing
/// work. Returns `true` when the user confirms discarding, `false`/`null`
/// (treated as `false` by callers) on cancel or barrier dismiss.
class DiscardChangesDialog extends StatelessWidget {
  const DiscardChangesDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('discard-changes-dialog'),
      icon: Icon(Icons.warning_amber_rounded, color: theme.colorScheme.error),
      title: Text(l10n.discardChangesTitle),
      content: Text(l10n.discardChangesMessage),
      actions: [
        TextButton(
          key: const Key('discard-changes-cancel'),
          style: TextButton.styleFrom(
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.discardChangesCancelAction),
        ),
        TextButton(
          key: const Key('discard-changes-confirm'),
          style: TextButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
            minimumSize: const Size(kMinTapTarget, kMinTapTarget),
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.discardChangesConfirmAction),
        ),
      ],
    );
  }
}

/// Shows [DiscardChangesDialog] and resolves to whether the user chose to
/// discard (a barrier dismiss counts as "keep editing", i.e. `false`).
Future<bool> showDiscardChangesDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (_) => const DiscardChangesDialog(),
  );
  return result ?? false;
}

/// Mixin for an edit/create screen's [ConsumerState] that wires up the
/// unsaved-changes guard (#345).
///
/// Usage:
/// - Call [markUnsavedChanges] whenever the user edits something. The simplest
///   wiring is `Form(onChanged: markUnsavedChanges, ...)`, which fires for
///   every [FormField] descendant; add explicit calls for edits that live
///   outside the [Form]'s field tree (a map pin, a multi-select, a date
///   picker).
/// - Wrap loading pre-existing data (edit mode) in [loadWithoutMarkingDirty]
///   so pre-filling fields isn't mistaken for a user edit.
/// - Call [clearUnsavedChanges] just before an intentional save-driven
///   `context.go`, so leaving isn't blocked.
/// - Wrap the screen body in [buildUnsavedChangesGuard] to intercept pops.
mixin UnsavedChangesMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  bool _dirty = false;
  bool _suppressDirty = false;

  // Captured in initState so [dispose] can reset the shared flag without
  // touching `ref` — Riverpod forbids `ref` use once the element is
  // unmounting ("save the provider state in a field of your State class").
  UnsavedChangesController? _guardController;

  bool get hasUnsavedChanges => _dirty;

  @override
  void initState() {
    super.initState();
    _guardController = ref.read(unsavedChangesProvider.notifier);
  }

  /// Runs [body] (an edit-mode initial load) without letting the field changes
  /// it makes mark the form dirty.
  Future<void> loadWithoutMarkingDirty(Future<void> Function() body) async {
    _suppressDirty = true;
    try {
      await body();
    } finally {
      _suppressDirty = false;
    }
  }

  void markUnsavedChanges() {
    if (_suppressDirty || _dirty) return;
    _dirty = true;
    _guardController?.markDirty();
    if (mounted) setState(() {});
  }

  void clearUnsavedChanges() {
    _dirty = false;
    _guardController?.markClean();
  }

  @override
  void dispose() {
    // Reset the shared flag when the form leaves the tree, so a later
    // unrelated navigation isn't blocked by a stale dirty state.
    _guardController?.markClean();
    super.dispose();
  }

  /// Wraps [child] so a pop (OS/browser back, or the shell back button via
  /// `maybePop`) is intercepted while there are unsaved changes: it prompts
  /// [DiscardChangesDialog] and only completes the pop if the user confirms.
  Widget buildUnsavedChangesGuard({required Widget child}) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final shouldDiscard = await showDiscardChangesDialog(context);
        if (shouldDiscard && mounted) {
          clearUnsavedChanges();
          navigator.pop(result);
        }
      },
      child: child,
    );
  }
}
