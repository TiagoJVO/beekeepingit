import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/widgets/content_column.dart';
import '../core/widgets/field_action_button.dart';
import '../l10n/gen/app_localizations.dart';
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
/// Three deliberate choices here:
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
/// 3. **It composes [EmptyState], rather than restating it.** This is the
///    same shape Home's own `_FirstRunState` uses — one message, one action,
///    the whole page — and reusing it is what earns this screen `EmptyState`'s
///    bounded/unbounded layout fix (#797, FR-AX-1): at the 200% text scale
///    D-18 commits to, the message wraps to several times its height and a
///    hand-rolled `Center > Padding > Column` overflows inside the shell's
///    bounded body. `not_found_route_test.dart` pins that at 200% rather than
///    trusting this comment.
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    // Deliberately the same composition as `_FirstRunState` in
    // `home_screen.dart`: ContentColumn (#650) narrows the measure to
    // BrandDimens.maxWidthList on a wide viewport, and the inner Center still
    // centres vertically within that narrowed column. Two whole-page
    // "one message + one action" states reachable from the same branch should
    // not sit differently on the screen.
    return ContentColumn(
      child: Center(
        child: SingleChildScrollView(
          key: const Key('not-found-body'),
          padding: const EdgeInsets.symmetric(horizontal: BrandDimens.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // No in-body heading: the shell's own header already titles this
              // route (`app_shell.dart`'s `_titleFor`), and `AppBar.title`
              // carries header semantics, so adding a `SectionHeader` here
              // would announce the same heading twice in a row. The icon is
              // decorative and carries no `semanticLabel` for the same reason
              // (FR-AX-1).
              EmptyState(
                message: l10n.notFoundMessage,
                icon: Icons.explore_off_outlined,
              ),
              PrimaryActionButton(
                key: const Key('not-found-home-button'),
                label: l10n.notFoundHomeAction,
                icon: Icons.home_outlined,
                // `go`, not `pop`: the shell's Back is the pop, and this is
                // the exit for a user who never reads the header. It also has
                // to work when this screen is the only thing on the branch's
                // stack.
                onPressed: () => context.go('/home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
