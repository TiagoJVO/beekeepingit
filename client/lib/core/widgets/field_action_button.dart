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
class PrimaryActionButton extends StatelessWidget {
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

  /// Null while disabled (e.g. mid-submit with [busy] already true).
  final VoidCallback? onPressed;

  /// Shows a small inline spinner instead of [icon]/[label] and disables the
  /// button, without changing its footprint (no tap-target-size regression
  /// while busy).
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
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label);

    final minimumSize = fullWidth
        ? const Size.fromHeight(kFieldActionButtonHeight)
        : const Size(kFieldActionButtonHeight, kFieldActionButtonHeight);

    final button = icon == null || busy
        ? FilledButton(
            style: FilledButton.styleFrom(minimumSize: minimumSize),
            onPressed: busy ? null : onPressed,
            child: child,
          )
        : FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: minimumSize),
            onPressed: onPressed,
            icon: Icon(icon),
            label: child,
          );

    return Semantics(
      button: true,
      enabled: onPressed != null,
      label: semanticsLabel ?? label,
      child: ExcludeSemantics(child: button),
    );
  }
}

/// A secondary or destructive field action (delete, logout, revoke, sync
/// now, change password) — outlined, full width, [kFieldActionButtonHeight]
/// tall, matching [PrimaryActionButton]'s footprint so the two read as the
/// same tap-target family.
class SecondaryActionButton extends StatelessWidget {
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
  final VoidCallback? onPressed;

  /// Same busy-spinner behavior as [PrimaryActionButton.busy].
  final bool busy;

  /// Tints the button with the theme's error color (delete/logout/revoke).
  final bool destructive;

  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final errorColor = Theme.of(context).colorScheme.error;
    final style = OutlinedButton.styleFrom(
      minimumSize: const Size.fromHeight(kFieldActionButtonHeight),
      foregroundColor: destructive ? errorColor : null,
      side: destructive ? BorderSide(color: errorColor) : null,
    );

    final child = busy
        ? const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(label);

    final button = icon == null || busy
        ? OutlinedButton(
            style: style,
            onPressed: busy ? null : onPressed,
            child: child,
          )
        : OutlinedButton.icon(
            style: style,
            onPressed: onPressed,
            icon: Icon(icon),
            label: child,
          );

    return Semantics(
      button: true,
      enabled: onPressed != null && !busy,
      label: semanticsLabel ?? label,
      child: ExcludeSemantics(child: button),
    );
  }
}
