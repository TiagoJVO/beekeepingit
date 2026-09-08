import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/content_column.dart';
import '../core/widgets/field_action_button.dart';
import '../l10n/gen/app_localizations.dart';
import '../theming/app_theme.dart';
import '../theming/brand_dimens.dart';
import '../theming/brand_widgets.dart';

/// What the app shows for a location no route matches (#638, FR-UX-2,
/// NFR-I18N-1).
///
/// Before this screen existed the router declared neither an `errorBuilder`
/// nor an `onException`, so go_router's own fallback answered instead:
/// `GoException: no routes for location: /activities/new` above a bare "Home"
/// link — the framework's own diagnostics, shown to a beekeeper, in English
/// whatever locale the app was running in.
///
/// Two deliberate choices here:
///
/// 1. **It is an ordinary page of the app, not a replacement for it.** The
///    route lives inside the shell's home branch (see `app_router.dart`), so
///    reaching it costs the user none of the navigation the shell provides —
///    bottom bar / desktop rail, sync pill, account. That is the substance of
///    the issue: a stale link stranded the user with one link and no way to
///    go anywhere else. The shell's back control pops back to Home, and the
///    action below is the second, in-body exit for a user who never reads the
///    header.
/// 2. **It says nothing about the failed location.** The attempted path is
///    the user's own URL, not information they can act on, and rendering it
///    would put arbitrary untranslated text back on the screen — the very
///    shape #638 reports. The router logs it instead (`app_router.dart`'s
///    `onException`), where diagnostics belong.
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    // ContentColumn (#650) caps this at BrandDimens.maxWidthList on a wide
    // desktop viewport; the scroll view is what keeps the column laying out
    // at the 200% text scale D-18 commits to, where the message wraps to
    // several times its normal height inside the shell's bounded body.
    return ContentColumn(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: BrandDimens.gutter,
          vertical: 32,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Purely decorative — it carries no `semanticLabel`, because the
            // heading right below already says what it would say (FR-AX-1).
            // `Align` because the column stretches (so the action button
            // spans it), and a stretched `Icon` would centre its glyph out
            // of line with the text beside it.
            Align(
              alignment: Alignment.centerLeft,
              child: Icon(
                Icons.explore_off_outlined,
                size: 40,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            // A real heading node, so a screen-reader user landing here from
            // a stale link hears what this page is before its body (#771).
            SectionHeader(l10n.notFoundTitle),
            const SizedBox(height: 8),
            Text(
              l10n.notFoundMessage,
              key: const Key('not-found-message'),
              style: TextStyle(
                fontFamily: AppTheme.bodyFontFamily,
                fontSize: 15,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            PrimaryActionButton(
              key: const Key('not-found-home-button'),
              label: l10n.notFoundHomeAction,
              icon: Icons.home_outlined,
              // `go`, not `pop`: this screen is also the first thing a cold
              // start on a stale deep link renders, and then there is no
              // history behind it to pop to.
              onPressed: () => context.go('/home'),
            ),
          ],
        ),
      ),
    );
  }
}
