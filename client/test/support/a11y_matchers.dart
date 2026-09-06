import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shared a11y/field-first test helpers (#79, #80) — generalizes the
/// tap-target check `apiaries_list_screen_test.dart` introduced
/// (`each toggle segment meets the 44x44 minimum tap target size`) so every
/// screen's own test file can run the same sweep instead of re-deriving it.
/// See the checklist this backs:
/// `docs/design/accessibility-field-ux-checklist.md`.
const double kExpectedMinTapTarget = 44;

/// Asserts every widget found by [finder] renders at least
/// [kExpectedMinTapTarget] in both dimensions. Pass one finder per
/// interactive element under test (e.g. `find.byKey(const Key('...'))`) or a
/// finder that matches several (e.g. `find.byType(IconButton)`) — every
/// match is checked individually, and the failure message names the widget
/// at fault.
void expectMinTapTarget(
  WidgetTester tester,
  Finder finder, {
  double minSize = kExpectedMinTapTarget,
}) {
  final elements = finder.evaluate().toList();
  expect(
    elements,
    isNotEmpty,
    reason: 'expectMinTapTarget: finder matched no widgets',
  );
  for (final element in elements) {
    final size = tester.getSize(find.byWidget(element.widget));
    expect(
      size.width,
      greaterThanOrEqualTo(minSize),
      reason:
          'width of ${element.widget.runtimeType} '
          '(key: ${element.widget.key}) is ${size.width}, '
          'expected >= $minSize',
    );
    expect(
      size.height,
      greaterThanOrEqualTo(minSize),
      reason:
          'height of ${element.widget.runtimeType} '
          '(key: ${element.widget.key}) is ${size.height}, '
          'expected >= $minSize',
    );
  }
}

/// The reference handset viewport for layout guards — 375x812, the size
/// #630 measured the profile screen's dead vertical band at, and the same
/// 375 width the rest of this suite already treats as the narrowest phone
/// the app targets.
const Size kHandsetViewport = Size(375, 812);

/// Sizes the test view to [size] at a 1:1 device pixel ratio and restores it
/// afterwards, so a layout assertion reads in logical pixels that match the
/// viewport the issue/checklist talks about.
void useViewport(WidgetTester tester, {Size size = kHandsetViewport}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Asserts the single widget matched by [finder] — a screen's primary action
/// — is fully on screen without scrolling AND sits in the lower two thirds
/// of the viewport, the zone a thumb covers comfortably on a one-handed grip
/// (#630 AC 2). An action stranded in the top third of a tall phone is
/// reachable only by re-gripping, which is exactly what the field-use pass in
/// `docs/design/accessibility-field-ux-checklist.md` is trying to avoid.
void expectWithinThumbReach(
  WidgetTester tester,
  Finder finder, {
  Size viewport = kHandsetViewport,
  String label = 'the primary action',
}) {
  expect(
    finder,
    findsOneWidget,
    reason: 'expectWithinThumbReach: finder matched no single widget',
  );
  final rect = tester.getRect(finder);
  expect(
    rect.bottom,
    lessThanOrEqualTo(viewport.height),
    reason:
        '$label must be reachable without scrolling on a '
        '${viewport.width.toInt()}x${viewport.height.toInt()} viewport; '
        'it rendered at $rect',
  );
  expect(
    rect.center.dy,
    greaterThanOrEqualTo(viewport.height / 3),
    reason:
        '$label must sit in the lower two thirds of a '
        '${viewport.width.toInt()}x${viewport.height.toInt()} viewport '
        '(thumb reach); its centre was at ${rect.center.dy}',
  );
}

/// Asserts [key] resolves to exactly one widget with a non-empty semantics
/// label — either its own `Semantics.label`, or one merged up from a
/// descendant (e.g. a `Text` child), matching how a screen reader would
/// announce it. Fails with a clear message if the node has no label at all,
/// which is the concrete, checkable form of the checklist's "semantics
/// labels on every interactive element" item.
void expectHasSemanticsLabel(WidgetTester tester, Key key) {
  final finder = find.byKey(key);
  expect(
    finder,
    findsOneWidget,
    reason: 'expectHasSemanticsLabel: key $key not found',
  );
  final semantics = tester.getSemantics(finder);
  expect(
    semantics.label.trim(),
    isNotEmpty,
    reason: 'expectHasSemanticsLabel: no semantics label for $key',
  );
}
