import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

/// How many lines a confirmation toast may occupy, at any text scale.
///
/// Two is Material's own guidance for a snack bar, and the point at which a
/// toast stops being a glance and starts being a paragraph.
const int kToastMaxLines = 2;

/// Shows a confirmation toast whose height stays bounded at any text scale
/// (#790, FR-UX-2/FR-AX-1).
///
/// A bare `SnackBar(content: Text(message))` grows with the text scale without
/// limit. Measured on a 375x812 phone at the 200% scale D-18 commits to,
/// `syncSupersededNotice` rendered **268 logical pixels** — a third of the
/// window, sitting on the content it was reporting about. No bottom band a
/// scrollable reserves can clear that: `BrandDimens.scrollBottomInset` is 136.
///
/// So the message is capped at [kToastMaxLines] and, **only when that actually
/// truncates it**, the toast carries a "Details" affordance that opens the full
/// text in a scrollable dialog. Nothing is lost, and the reader who needs 200%
/// text still gets 200% text — clamping the toast's own text scale would have
/// been the easy fix and precisely the wrong one, since it withdraws the
/// accommodation from the person who asked for it.
///
/// Truncation is **measured, not guessed**: a [TextPainter] laid out against
/// the real constraints the `SnackBar` hands its content decides whether the
/// affordance appears. A length heuristic would show "Details" on a short
/// message in Portuguese and hide it on a long one in English.
void showAppToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(appToast(message));
}

/// The [SnackBar] [showAppToast] builds. Exposed for call sites that hand the
/// bar to a messenger they already hold, which is most of them: a save awaits
/// the API first, so it captures its messenger before the gap and must not
/// touch a [BuildContext] after it.
///
/// Deliberately takes no [BuildContext] for that reason. The content resolves
/// its own localizations from the context it is built in, inside the
/// `SnackBar` subtree, so no call site has to reach across an async gap.
SnackBar appToast(String message) =>
    SnackBar(content: _BoundedToastContent(message: message));

class _BoundedToastContent extends StatelessWidget {
  const _BoundedToastContent({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The content slot's own constraints, so the measurement matches what is
    // actually painted rather than an estimate of it.
    return LayoutBuilder(
      builder: (context, constraints) {
        final style = DefaultTextStyle.of(context).style;
        final painter = TextPainter(
          text: TextSpan(text: message, style: style),
          maxLines: kToastMaxLines,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        final truncated = painter.didExceedMaxLines;

        final text = Text(
          message,
          maxLines: kToastMaxLines,
          overflow: TextOverflow.ellipsis,
        );
        if (!truncated) return text;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            text,
            const SizedBox(height: 4),
            // Inside the content rather than as the SnackBar's `action`: the
            // action slot sits beside the text and steals width from it, which
            // makes a long message wrap sooner and truncate more. Below it, the
            // message keeps the full width it is being capped against.
            InkWell(
              key: const Key('toast-details-action'),
              onTap: () => _showFullMessage(context, message),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  l10n.toastDetailsAction,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
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
