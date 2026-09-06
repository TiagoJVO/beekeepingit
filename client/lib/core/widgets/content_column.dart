import 'package:flutter/widgets.dart';

import '../../theming/brand_dimens.dart';

/// Caps a list/content screen's body at [maxWidth] (default
/// [BrandDimens.maxWidthList]) and centres it horizontally, so a screen still
/// reads as one column on the wide desktop viewports the app now has to
/// support (#650) instead of stretching a single row across the whole
/// window.
///
/// Two things about this wrapper are deliberate, not oversights:
///
/// 1. **[Alignment.topCenter], never [Alignment.center].** #630/PR #768 and
///    #769/PR #791 just finished removing vertical centring from five
///    screens so short content sits at the top instead of floating mid-
///    screen. A content wrapper that re-centred vertically would quietly
///    undo that work on every screen it wraps. If a future screen needs
///    vertical centring, it opts in explicitly at its own call site — this
///    widget never does it implicitly.
/// 2. **No [LayoutBuilder], no breakpoint.** Below [maxWidth] the incoming
///    constraint is looser than the content's own width, so
///    [ConstrainedBox] is a no-op and the child renders exactly as it would
///    unwrapped — full width, no conditional needed. The constraint value
///    *is* its own breakpoint: nothing below it changes, everything above it
///    clamps. Do not "improve" this into a conditional that only applies the
///    constraint above some screen width; that conditional already exists,
///    for free, as the constraint itself.
class ContentColumn extends StatelessWidget {
  const ContentColumn({
    super.key,
    required this.child,
    this.maxWidth = BrandDimens.maxWidthList,
  });

  /// The wrapped content.
  final Widget child;

  /// The width this column clamps to. Defaults to
  /// [BrandDimens.maxWidthList]; pass [BrandDimens.maxWidthContent] for a
  /// narrower single-column form/card screen.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
