import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

/// One action revealed by an [ActionsSpeedDial] (#347, FR-UX-2's contextual
/// quick-add). The list of these is the scope's available options — the caller
/// builds it from what's valid for the current screen, so the speed dial only
/// ever exposes the right actions for where the user is.
class SpeedDialAction {
  const SpeedDialAction({
    required this.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  /// A stable [Key] for this action's button so tests (and Flutter's own hero
  /// tagging, derived from it) can address each option distinctly.
  final Key key;

  /// The action's visible + screen-reader label (already localized by the
  /// caller — no hardcoded strings reach this widget).
  final String label;
  final IconData icon;
  final VoidCallback onPressed;
}

/// A single "Actions" control that consolidates a screen's quick actions into
/// one gloves-friendly button which expands, speed-dial style, to reveal only
/// the actions valid for the current scope (#347, FR-UX-1/FR-UX-2). Replaces
/// the previous pattern of stacking several [FloatingActionButton.extended]
/// widgets in a `Column`, which crowded the field UI.
///
/// Behavior:
///   - **One action** — rendered directly as the primary honey FAB; hiding a
///     lone action behind an extra tap would be worse for a gloved field user,
///     and consolidation only matters when actions would otherwise stack.
///   - **Two or more** — a collapsed primary "Actions" toggle. Tapping it
///     expands the options above it (each a tonal [FloatingActionButton
///     .extended]); tapping the toggle again, or picking an option, collapses
///     it cleanly. The toggle carries an `expanded`/`collapsed` semantics state
///     (announced to screen readers) plus the localized "Actions" name, and
///     every button meets the 44x44 gloves-friendly target (D-18) — FABs are
///     already ≥56px.
class ActionsSpeedDial extends StatefulWidget {
  const ActionsSpeedDial({required this.actions, super.key});

  /// The scope's available actions, top-to-bottom in reveal order. Must be
  /// non-empty — the caller decides whether to render the speed dial at all.
  final List<SpeedDialAction> actions;

  @override
  State<ActionsSpeedDial> createState() => _ActionsSpeedDialState();
}

class _ActionsSpeedDialState extends State<ActionsSpeedDial> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  void _runAction(SpeedDialAction action) {
    setState(() => _expanded = false);
    action.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    // Single action: render it directly as the primary honey FAB (no toggle).
    if (widget.actions.length == 1) {
      final action = widget.actions.single;
      return _ActionFab(
        action: action,
        onPressed: action.onPressed,
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // Options only exist in the tree while expanded, so a collapsed dial
        // exposes neither them nor their tap targets to touch or a screen
        // reader — the toggle's expanded/collapsed state is the single
        // affordance. AnimatedSize gives the reveal/collapse a clean height
        // transition rather than a jarring pop.
        AnimatedSize(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          alignment: Alignment.bottomRight,
          child: _expanded
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final action in widget.actions) ...[
                      _ActionFab(
                        action: action,
                        onPressed: () => _runAction(action),
                        backgroundColor: colorScheme.secondaryContainer,
                        foregroundColor: colorScheme.onSecondaryContainer,
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                )
              : const SizedBox.shrink(),
        ),
        _ActionsToggle(
          expanded: _expanded,
          label: l10n.actionsMenuLabel,
          onPressed: _toggle,
        ),
      ],
    );
  }
}

/// The collapsed/expanded "Actions" primary FAB. Its semantics carry a
/// `button` role, the localized "Actions" name and — crucially — the
/// `expanded` state, so a screen reader announces "Actions, collapsed/expanded"
/// and its own `onTap` routes activation. The inner FAB's semantics are
/// excluded so the two don't produce a duplicate/nested announcement.
class _ActionsToggle extends StatelessWidget {
  const _ActionsToggle({
    required this.expanded,
    required this.label,
    required this.onPressed,
  });

  final bool expanded;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      expanded: expanded,
      label: label,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: FloatingActionButton.extended(
          key: const Key('actions-speed-dial-toggle'),
          heroTag: 'actions-speed-dial-toggle',
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
          onPressed: onPressed,
          icon: Icon(expanded ? Icons.close : Icons.bolt),
          label: Text(label),
        ),
      ),
    );
  }
}

/// One revealed option (or the lone single action) as a
/// [FloatingActionButton.extended]. A distinct `heroTag` per action key avoids
/// Flutter's default-tag collision when several are visible at once.
class _ActionFab extends StatelessWidget {
  const _ActionFab({
    required this.action,
    required this.onPressed,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final SpeedDialAction action;
  final VoidCallback onPressed;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      key: action.key,
      heroTag: 'speed-dial-${action.key}',
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      onPressed: onPressed,
      icon: Icon(action.icon),
      label: Text(action.label),
    );
  }
}
