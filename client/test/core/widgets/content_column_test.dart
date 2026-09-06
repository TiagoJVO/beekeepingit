import 'package:beekeepingit_client/core/widgets/content_column.dart';
import 'package:beekeepingit_client/theming/brand_dimens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit coverage for the shared list/content width cap (#650).
///
/// Three behaviors matter here, each guarding a specific regression this
/// widget must never reintroduce:
///
///  - below [BrandDimens.maxWidthList] the wrapper is a no-op — the
///    constraint IS its own breakpoint (see the widget's own doc comment),
///    so there is nothing to assert here beyond "the child still gets full
///    width";
///  - at/above it the child clamps to exactly [BrandDimens.maxWidthList] and
///    sits horizontally centred;
///  - the child is TOP-aligned, never vertically centred — the #630/#769
///    guard this widget must not undo.
///
/// A fourth case is an arithmetic invariant, not a widget-behavior test:
/// that [BrandDimens.maxWidthList] still leaves an activity row
/// ([_kCompactRowBelowWidth]'s 600px threshold, `activity_list_widgets
/// .dart`, #632) comfortably wide even under the worst-case bound — the
/// widest gutter any list screen applies, subtracted from each side — so a
/// future narrowing of the constant fails HERE rather than silently
/// flipping every desktop activity row into its compact phone layout. That
/// bound is conservative, not a measurement of the activity list itself:
/// the screens that actually embed the row apply no horizontal padding
/// around it at all, so their real margin over 600px is wider still.
void main() {
  Widget harness(Widget child, {double? maxWidth}) => MaterialApp(
    home: Scaffold(
      body: maxWidth == null
          ? ContentColumn(child: child)
          : ContentColumn(maxWidth: maxWidth, child: child),
    ),
  );

  void useViewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('ContentColumn (#650)', () {
    testWidgets('is a no-op below the cap — the child still spans the '
        'narrow viewport', (tester) async {
      useViewport(tester, const Size(375, 812));
      const key = Key('content-column-child');
      await tester.pumpWidget(harness(Container(key: key, color: Colors.red)));
      await tester.pumpAndSettle();

      // 375 is well under maxWidthList (720), so the ConstrainedBox never
      // binds and the child renders at the full available width.
      expect(tester.getSize(find.byKey(key)).width, 375);
    });

    testWidgets(
      'clamps to exactly maxWidth and centres horizontally above the cap',
      (tester) async {
        useViewport(tester, const Size(1280, 800));
        const key = Key('content-column-child');
        await tester.pumpWidget(
          harness(Container(key: key, color: Colors.red)),
        );
        await tester.pumpAndSettle();

        final rect = tester.getRect(find.byKey(key));
        expect(rect.width, BrandDimens.maxWidthList);
        // Horizontally centred in the 1280-wide viewport.
        expect(rect.left, closeTo((1280 - BrandDimens.maxWidthList) / 2, 0.5));
        expect(
          rect.right,
          closeTo(1280 - (1280 - BrandDimens.maxWidthList) / 2, 0.5),
        );
      },
    );

    testWidgets(
      'top-aligns rather than vertically centring the child (#630 guard)',
      (tester) async {
        useViewport(tester, const Size(1280, 800));
        const key = Key('content-column-child');
        // A child much shorter than the viewport, so a vertical-centring
        // regression would visibly move it away from the top.
        await tester.pumpWidget(
          harness(SizedBox(key: key, height: 40, child: Container())),
        );
        await tester.pumpAndSettle();

        expect(tester.getRect(find.byKey(key)).top, 0);
      },
    );

    test('maxWidthList leaves an activity row above the compact-row breakpoint '
        '(#632) even after the widest list gutter is subtracted from each '
        'side', () {
      const widestListGutter = BrandDimens.gutter;
      final rowWidthAtWorstCase =
          BrandDimens.maxWidthList - 2 * widestListGutter;
      expect(
        rowWidthAtWorstCase,
        greaterThanOrEqualTo(600),
        reason:
            'a narrower maxWidthList would silently flip every desktop '
            'activity row into its compact three-line phone layout '
            '(_kCompactRowBelowWidth in activity_list_widgets.dart, #632) '
            '— re-derive both numbers together if this ever needs to '
            'change',
      );
    });
  });
}
