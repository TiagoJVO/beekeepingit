import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import 'tap_target.dart';

/// How many lines a confirmation toast's message may occupy.
///
/// Two is Material's own guidance for a snack bar, and the point at which a
/// toast stops being a glance and starts being a paragraph.
const int kToastMaxLines = 2;

/// Shows [message] as the app's confirmation toast, **replacing** whatever
/// toast is currently up rather than queueing behind it (#640, FR-UX-1,
/// FR-ONB-3).
///
/// This is the single place the client raises a confirmation, and the reason
/// it exists is [ScaffoldMessengerState.showSnackBar]'s queueing: a bar stays
/// up for four seconds, and a second `showSnackBar` inside that window parks
/// its message behind the first instead of showing it. Two symptoms followed,
/// both reported in #640:
///
/// - **The toast read one action behind.** Revoking an invitation four seconds
///   after sending one left "Invitation sent." on screen — the confirmation
///   for the *previous* action, describing the opposite of what just happened.
/// - **A parked message outlived its screen.** `MaterialApp` installs one root
///   `ScaffoldMessenger` (see `app.dart`), so the queue spans every route: the
///   parked "Invitation sent." surfaced minutes later over the Todos tab,
///   reporting an action against unrelated content.
///
/// [ScaffoldMessengerState.clearSnackBars] fixes both at once, and it has to
/// be `clearSnackBars` rather than `hideCurrentSnackBar`: hiding the current
/// bar *promotes* the next queued one, so the new message would still land
/// behind a stale one. Cleared, the queue can never hold more than the bar on
/// screen, so there is nothing left to surface anywhere later.
///
/// A toast raised **just before** a navigation still travels with it, and must
/// — the save-then-go-back flow all over `client/lib` (e.g.
/// `apiary_form_screen.dart`) confirms the save and then pops to the list, and
/// the destination is where the user reads it. Only *queued* messages are
/// discarded, never the one the current action raised.
///
/// Takes a [ScaffoldMessengerState], not a [BuildContext]: every real call
/// site awaits an API first and captures its messenger before the gap, because
/// touching a context across an async gap is what
/// `use_build_context_synchronously` exists to catch. A synchronous call site
/// passes `ScaffoldMessenger.of(context)`.
void showAppToast(ScaffoldMessengerState messenger, String message) {
  messenger.clearSnackBars();
  messenger.showSnackBar(appToast(message));
}

/// A [SnackBar] whose message is capped at [kToastMaxLines] lines, with a
/// "Details" affordance when — and only when — that actually truncates it
/// (#790, FR-UX-2/FR-AX-1).
///
/// A bare `SnackBar(content: Text(message))` grows with the text scale without
/// limit. Measured on a 375x812 phone at the 200% scale D-18 commits to,
/// `syncSupersededNotice` rendered **268 logical pixels** — a third of the
/// window, over the content it was reporting on, and past anything
/// `BrandDimens.scrollBottomInset` (136) can reserve. Capped, the same message
/// measures ~108 and fits inside that band.
///
/// Three details are load-bearing:
///
/// - **Truncation is measured, not guessed.** A [TextPainter] laid out against
///   the real constraints the `SnackBar` hands its content decides whether the
///   affordance appears, so it does not show on a short Portuguese string or
///   hide on a long English one.
/// - **The affordance sits BESIDE the text, not under it.** A `Column` was the
///   obvious shape and the wrong one: it added ~48px, putting the toast back
///   at 156 and outside the band this exists to respect. In a `Row` it costs
///   width — which only matters for a message already being capped — and no
///   height.
/// - **No [BuildContext] parameter.** Every real call site awaits an API first
///   and captures its messenger before the gap; taking a context would mean
///   reaching across it, which `use_build_context_synchronously` catches.
///
/// Deliberately does NOT set `duration`. Flutter's default applies, the same
/// as every un-migrated call site — a longer one would hold short
/// confirmations on screen too, and the shell shows engine notifications in a
/// loop that `ScaffoldMessenger` queues serially, so a bumped duration
/// multiplies across a batch.
///
/// Raising the bar directly is the escape hatch for the one caller that
/// deliberately *wants* the queue — `shell/app_shell.dart`'s
/// engine-notification batch, which has several distinct messages to deliver
/// and no screen of its own to outlive. Everything a user action confirms goes
/// through [showAppToast] instead.
SnackBar appToast(String message) =>
    SnackBar(content: _BoundedToastContent(message: message));

class _BoundedToastContent extends StatelessWidget {
  const _BoundedToastContent({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final text = Text(
          message,
          maxLines: kToastMaxLines,
          overflow: TextOverflow.ellipsis,
        );
        if (!_isTruncated(context, constraints.maxWidth)) return text;

        // Resolved only on the branch that needs it, so a toast raised in a
        // harness without the localization delegates still works.
        final l10n = AppLocalizations.of(context);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: text),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: l10n.toastDetailsAction,
              child: InkWell(
                key: const Key('toast-details-action'),
                onTap: () => _showFullMessage(context, message),
                child: ConstrainedBox(
                  // The app's own floor (D-18), not WCAG 2.5.8's bare 24x24:
                  // unconstrained, this measured 24px tall at 1.0 text scale.
                  constraints: const BoxConstraints(
                    minHeight: kMinTapTarget,
                    minWidth: kMinTapTarget,
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      l10n.toastDetailsAction,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Whether [message] overflows [kToastMaxLines] at [maxWidth].
  ///
  /// The painter owns a `ui.Paragraph`, so it is disposed rather than left to
  /// the collector — this runs once per layout pass per toast.
  bool _isTruncated(BuildContext context, double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: message, style: DefaultTextStyle.of(context).style),
      maxLines: kToastMaxLines,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      locale: Localizations.localeOf(context),
    );
    try {
      // Leave room for the affordance the truncated branch will add, or the
      // measurement describes a layout that never gets rendered.
      painter.layout(
        maxWidth: (maxWidth - kMinTapTarget - 8).clamp(0, maxWidth),
      );
      return painter.didExceedMaxLines;
    } finally {
      painter.dispose();
    }
  }
}

/// The full message, scrollable so it cannot overflow at any scale.
void _showFullMessage(BuildContext context, String message) {
  final l10n = AppLocalizations.of(context);
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      key: const Key('toast-details-dialog'),
      content: SingleChildScrollView(child: Text(message)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.toastDetailsCloseAction),
        ),
      ],
    ),
  );
}
