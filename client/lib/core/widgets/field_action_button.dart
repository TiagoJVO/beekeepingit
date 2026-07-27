import 'dart:async';

import 'package:flutter/material.dart';

/// Shared field-first, gloves-friendly action buttons (FR-UX-1, FR-AX-1, #79,
/// #80). Every screen with a primary/secondary/destructive action
/// (login, apiary form, profile, organization, account, members) was
/// hand-rolling `FilledButton`/`OutlinedButton` with the same
/// `minimumSize: Size.fromHeight(56)` — a full-width, 56px-tall tap target,
/// comfortably over WCAG 2.2 AA's 24x24 minimum and this app's own 44x44
/// baseline (see the checklist below) — one screen (members invite) had
/// skipped it entirely, silently falling back to Material 3's 40px default,
/// under the 44x44 floor. Extracting it here means every new screen gets the
/// right tap-target size by construction instead of by copy-paste, and a
/// change to the field-first sizing only has one place to make it.
///
/// See the checklist this implements:
/// `docs/design/accessibility-field-ux-checklist.md`.
const double kFieldActionButtonHeight = 56;

/// The primary honey action on a screen (save, sign in, submit) —
/// [kFieldActionButtonHeight] tall, full width by default. Shows [busy] as an
/// inline spinner in place of the icon/label rather than disabling+hiding
/// it, so the button's position and size don't jump while a request is in
/// flight.
///
/// Self-guarding against multi-click (#380): while [onPressed] is running
/// (its returned [Future], if any, hasn't completed yet), the button
/// disables itself so a second tap can never invoke it again — a caller does
/// NOT need its own re-entrancy guard to prevent a double-tap from stacking
/// two calls. This disables the button but does NOT by itself show the busy
/// spinner: [onPressed] handlers that open a confirmation dialog and await
/// the user's choice (e.g. a delete flow) are legitimately "in flight" for
/// as long as the user takes to decide, and a spinner during that wait would
/// misleadingly suggest network activity where there is none (and, in a
/// widget test, an indeterminate `CircularProgressIndicator` never lets
/// `pumpAndSettle` converge). Pass [busy] explicitly for the sub-span that
/// really is async I/O (mirrors every existing call site's own pattern of
/// flipping a local `_busy`/`_saving` flag around the actual repository
/// call, e.g. after a confirm dialog resolves).
class PrimaryActionButton extends StatefulWidget {
  const PrimaryActionButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.fullWidth = true,
    this.semanticsLabel,
    super.key,
  });

  /// Visible label text.
  final String label;

  /// Optional leading icon — omitted while [busy].
  final IconData? icon;

  /// Null while disabled (e.g. mid-submit with [busy] already true). May
  /// return a [Future] — the button disables itself (re-entrancy guard, not
  /// necessarily the spinner — see the class doc) for its duration.
  final FutureOr<void> Function()? onPressed;

  /// Shows a small inline spinner instead of [icon]/[label] and disables the
  /// button, without changing its footprint (no tap-target-size regression
  /// while busy). Caller-driven — see the class doc for why this is kept
  /// separate from the button's own tap-in-flight tracking.
  final bool busy;

  /// Whether the button stretches to fill its parent's width (the common
  /// case: a form's own primary action). Set false for a button that shares
  /// a row with another control (e.g. the members screen's inline invite
  /// button next to its email field) — [kFieldActionButtonHeight] still
  /// applies either way.
  final bool fullWidth;

  /// Overrides the announced label — e.g. to include a "saving" state a
  /// screen-reader user can't see from the spinner alone. Defaults to
  /// [label].
  final String? semanticsLabel;

  @override
  State<PrimaryActionButton> createState() => _PrimaryActionButtonState();
}

class _PrimaryActionButtonState extends State<PrimaryActionButton> {
  bool _inFlight = false;

  Future<void> _handlePressed() async {
    if (_inFlight) return;
    setState(() => _inFlight = true);
    try {
      await widget.onPressed!();
    } finally {
      if (mounted) setState(() => _inFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null || widget.busy || _inFlight;
    final child = widget.busy
        ? const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(widget.label);

    final minimumSize = widget.fullWidth
        ? const Size.fromHeight(kFieldActionButtonHeight)
        : const Size(kFieldActionButtonHeight, kFieldActionButtonHeight);

    final onPressed = disabled ? null : _handlePressed;

    final button = widget.icon == null || widget.busy
        ? FilledButton(
            style: FilledButton.styleFrom(minimumSize: minimumSize),
            onPressed: onPressed,
            child: child,
          )
        : FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: minimumSize),
            onPressed: onPressed,
            icon: Icon(widget.icon),
            label: child,
          );

    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: widget.semanticsLabel ?? widget.label,
      child: ExcludeSemantics(child: button),
    );
  }
}

/// A secondary or destructive field action (delete, logout, revoke, sync
/// now, change password) — outlined, full width, [kFieldActionButtonHeight]
/// tall, matching [PrimaryActionButton]'s footprint so the two read as the
/// same tap-target family.
///
/// Self-guarding against multi-click the same way as [PrimaryActionButton]
/// — see its class doc for why disabling and the busy spinner are kept
/// independent.
class SecondaryActionButton extends StatefulWidget {
  const SecondaryActionButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.busy = false,
    this.destructive = false,
    this.semanticsLabel,
    super.key,
  });

  final String label;
  final IconData? icon;

  /// May return a [Future] — the button disables itself (re-entrancy guard)
  /// for its duration. See [PrimaryActionButton.onPressed]'s doc for why
  /// this doesn't by itself drive the busy spinner.
  final FutureOr<void> Function()? onPressed;

  /// Same busy-spinner behavior as [PrimaryActionButton.busy].
  final bool busy;

  /// Tints the button with the theme's error color (delete/logout/revoke).
  final bool destructive;

  final String? semanticsLabel;

  @override
  State<SecondaryActionButton> createState() => _SecondaryActionButtonState();
}

class _SecondaryActionButtonState extends State<SecondaryActionButton> {
  bool _inFlight = false;

  Future<void> _handlePressed() async {
    if (_inFlight) return;
    setState(() => _inFlight = true);
    try {
      await widget.onPressed!();
    } finally {
      if (mounted) setState(() => _inFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null || widget.busy || _inFlight;
    final errorColor = Theme.of(context).colorScheme.error;
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(kFieldActionButtonHeight),
      foregroundColor: widget.destructive ? errorColor : null,
      side: widget.destructive ? BorderSide(color: errorColor) : null,
    );

    final child = widget.busy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(widget.label);

    final onPressed = disabled ? null : _handlePressed;

    final button = widget.icon == null || widget.busy
        ? OutlinedButton(style: style, onPressed: onPressed, child: child)
        : OutlinedButton.icon(
            style: style,
            onPressed: onPressed,
            icon: Icon(widget.icon),
            label: child,
          );

    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: widget.semanticsLabel ?? widget.label,
      child: ExcludeSemantics(child: button),
    );
  }
}
