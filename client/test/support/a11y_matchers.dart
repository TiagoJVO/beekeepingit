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
/// of the current viewport, the zone a thumb covers comfortably on a
/// one-handed grip. This is the checkable form of #630's second acceptance
/// criterion, "the primary action sits within comfortable thumb reach on a
/// 375x812 viewport"; an action stranded in the top third of a tall phone is
/// reachable only by re-gripping.
///
/// The viewport is READ from the test view rather than passed in, so it can
/// never disagree with whatever [useViewport] (or the caller) actually set —
/// asserting reachability against 812px on a 568px view would silently pass
/// a control 240px below the fold.
void expectWithinThumbReach(
  WidgetTester tester,
  Finder finder, {
  String label = 'the primary action',
}) {
  expect(
    finder,
    findsOneWidget,
    reason: 'expectWithinThumbReach: finder matched no single widget',
  );
  final viewport = tester.view.physicalSize / tester.view.devicePixelRatio;
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

/// Asserts [finder]'s rendered rectangle sits entirely inside the viewport —
/// the concrete, checkable form of the checklist's "the primary action is
/// pinned, never scrolled to" item (`#341`, `#357`): a control the user can
/// see and hit right now, without first finding a drag some inner scrollable
/// will not swallow.
///
/// Compares against the LOGICAL viewport (`physicalSize / devicePixelRatio`),
/// which is the coordinate space `tester.getRect` reports in — so it is
/// correct whatever device pixel ratio the test sets.
void expectFullyOnScreen(
  WidgetTester tester,
  Finder finder, {
  required String reason,
}) {
  final rect = tester.getRect(finder);
  final viewport =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  expect(
    viewport.contains(rect.topLeft) &&
        viewport.contains(rect.bottomRight - const Offset(1, 1)),
    isTrue,
    reason: '$reason (rendered at $rect, viewport $viewport)',
  );
}

/// Asserts the control keyed [key] announces [name] as its accessible name —
/// what `InputDecoration.labelText` used to put on the field's own semantics
/// node, and what the `client/e2e` suite reaches for with `getByLabel(...)`.
///
/// Compares only the FIRST line of the node's label: a field whose label now
/// sits above it shows its `hintText` as visible placeholder text, and a
/// visible hint joins the same merged node on a line of its own (with the
/// label in the box border it was opacity-0, and so left out). A multi-line
/// field likewise contributes an empty trailing segment. The name is the
/// part that has to be exact.
void expectFieldAccessibleName(WidgetTester tester, Key key, String name) {
  final finder = find.byKey(key);
  expect(finder, findsOneWidget, reason: 'expectFieldAccessibleName: $key');
  expect(
    tester.getSemantics(finder).label.split('\n').first.trim(),
    name,
    reason:
        'the field keyed $key lost the accessible name its floating label '
        'used to give it — moving the label above the box must hand the '
        'name to the field, not just paint text near it',
  );
}

/// Asserts the form inside [scope] uses ONE field-label pattern — the
/// documented label-above `LabeledField` — by proving no field on it still
/// paints a floating Material label (`InputDecoration.labelText`), the
/// pattern `docs/design/melargil-flutter-style.md` rules out (#629, FR-UX-1).
///
/// Every decorated field (`TextField`, `TextFormField`,
/// `DropdownButtonFormField`, a bare `InputDecorator` wrapping a tappable
/// value) builds exactly one [InputDecorator], so sweeping those covers all
/// of them uniformly — including the ones a screen builds from a private
/// helper, which a key-by-key check would keep missing as fields are added.
///
/// [scope] keeps the sweep to the screen under test: list screens' compact
/// filter/search bars deliberately keep their own labels and may be mounted
/// elsewhere in the same pumped app.
void expectNoFloatingFieldLabels(WidgetTester tester, Finder scope) {
  final decorators = find.descendant(
    of: scope,
    matching: find.byType(InputDecorator),
  );
  expect(
    decorators,
    findsWidgets,
    reason: 'expectNoFloatingFieldLabels: no fields found inside the scope',
  );
  final floating = <String>[
    for (final element in decorators.evaluate())
      if ((element.widget as InputDecorator).decoration.labelText
          case final String label)
        label,
  ];
  expect(
    floating,
    isEmpty,
    reason:
        'these fields still animate their label into the box border instead '
        'of wearing it above via LabeledField: $floating',
  );
}
