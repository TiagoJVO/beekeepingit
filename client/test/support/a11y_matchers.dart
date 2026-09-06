import 'dart:async';

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

/// Asserts the semantics node a screen reader would land on for [finder] is
/// (or, with `isLiveRegion: false`, is not) a LIVE REGION — the flag that
/// makes an assistive technology speak the node when its content appears or
/// changes.
///
/// This is the checkable form of the checklist's "validation errors are
/// announced, not just painted" item (#750, FR-AX-1, D-18). Two shapes,
/// both needed:
///
///  * on an ERROR MESSAGE node, `isLiveRegion: true` — the message must be
///    spoken when it appears;
///  * on the FIELD node itself, `isLiveRegion: false` — a live region there
///    would make an assistive technology re-read the whole field (name,
///    value, error) on every keystroke.
///
/// Reads the real [SemanticsNode]'s flags rather than the [Semantics] widget
/// so a wrapper that swallows or duplicates the flag cannot pass.
void expectLiveRegion(
  WidgetTester tester,
  Finder finder, {
  bool isLiveRegion = true,
}) {
  expect(
    finder,
    findsOneWidget,
    reason: 'expectLiveRegion: $finder matched no single widget',
  );
  final node = tester.getSemantics(finder);
  expect(
    node.getSemanticsData().flagsCollection.isLiveRegion,
    isLiveRegion,
    reason: isLiveRegion
        ? 'the node labelled "${node.label}" must be a live region so a '
              'screen reader speaks it when it appears; it is not'
        : 'the node labelled "${node.label}" must NOT be a live region — a '
              'live region there re-announces the whole node on every change; '
              'it is',
  );
}

/// The reference handset viewport for layout guards — 375x812, the size
/// #630 measured the profile screen's dead vertical band at, and the same
/// 375 width the rest of this suite already treats as the narrowest phone
/// the app targets.
const Size kHandsetViewport = Size(375, 812);

/// The reference tablet-portrait viewport — 1024x1366, an iPad Pro 12.9" in
/// portrait, and the size #787 measured the four detail screens' dead
/// vertical band at (263 / 288.5 / 224px). Those screens show **no** band at
/// [kHandsetViewport]: their header card, sections and history block already
/// overflow a phone, so the scroll view fills the body and the vertical
/// alignment never gets to apply. A layout guard for them has to run here or
/// it asserts nothing.
const Size kTabletViewport = Size(1024, 1366);

/// Sizes the test view to [size] at a 1:1 device pixel ratio and restores it
/// afterwards, so a layout assertion reads in logical pixels that match the
/// viewport the issue/checklist talks about.
void useViewport(WidgetTester tester, {Size size = kHandsetViewport}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Which edge of the anchor [expectStartsAtContentTop] measures from.
///
/// The two call-site shapes in this app anchor differently, and getting it
/// wrong turns the assertion into a tautology rather than failing loudly —
/// which is why this is an explicit argument and not inferred.
enum ContentTopAnchor {
  /// Measure from the anchor's **bottom** edge: the anchor sits *above* the
  /// content area, e.g. a screen carrying its own [AppBar].
  below,

  /// Measure from the anchor's **top** edge: the anchor *is* the content
  /// area, e.g. a route embedded in the app shell, where the shell owns the
  /// header and hands the screen the region below it.
  inside,
}

/// Asserts the content matched by [content] starts at the very top of the
/// content area defined by [anchor] — the checkable form of the top-align
/// rule `docs/design/melargil-flutter-style.md` states and #630/#769/#787
/// applied: a scrollable column wraps in `Align(topCenter)` (today
/// `ContentColumn`), never a plain `Center`, which splits the leftover height
/// into equal bands and leaves a dead gap under the header.
///
/// Bounded at BOTH ends by [tolerance]: the upper bound catches the dead
/// band the issue is about, the lower bound catches content rendering up out
/// of its own content area (over the header).
///
/// The gap is reported in the failure message, so a red run names the real
/// measured offset rather than just "expected true".
void expectStartsAtContentTop(
  WidgetTester tester,
  Finder content, {
  required Finder anchor,
  required ContentTopAnchor from,
  String label = 'the content',
  double tolerance = 1.0,
}) {
  // Both finders are guarded BEFORE getRect so an ambiguous match fails on
  // this line, naming which finder was at fault, rather than with an opaque
  // "matched N widgets" from getRect.
  expect(
    content,
    findsOneWidget,
    reason: 'expectStartsAtContentTop: the content finder matched no '
        'single widget',
  );
  expect(
    anchor,
    findsOneWidget,
    reason:
        'expectStartsAtContentTop: the anchor finder matched no single widget',
  );
  final anchorRect = tester.getRect(anchor);
  final contentAreaTop = switch (from) {
    ContentTopAnchor.below => anchorRect.bottom,
    ContentTopAnchor.inside => anchorRect.top,
  };
  final gap = tester.getRect(content).top - contentAreaTop;
  expect(
    gap,
    inInclusiveRange(-tolerance, tolerance),
    reason:
        '$label must start at the top of its content area, like every other '
        'screen in the app; it started ${gap}px below it',
  );
}

/// A stream that never emits and never closes, holding a `StreamProvider`
/// (and so its screen) in the `loading` branch for as long as the test needs.
///
/// Deliberately not `Stream.empty()`, which closes immediately and resolves
/// the provider, and deliberately timer-free so a test can still pump fixed
/// frames. Pass the FUNCTION, not a call — a Riverpod family override runs
/// its closure once per key and per rebuild, and handing the same
/// single-subscription stream out twice fails with "Stream has already been
/// listened to".
Stream<T> pendingStream<T>() => Stream<T>.fromFuture(Completer<T>().future);

/// The current logical viewport — `physicalSize / devicePixelRatio`, the
/// coordinate space `tester.getRect` reports in.
///
/// READ from the test view rather than assumed, the rule
/// [expectWithinThumbReach] documents: a layout assertion that hardcodes
/// 812 silently measures against the wrong geometry the moment a caller
/// passes [useViewport] another size.
Size viewportOf(WidgetTester tester) =>
    tester.view.physicalSize / tester.view.devicePixelRatio;

/// Asserts the single widget matched by [finder] — a lone loading spinner or
/// error message — sits vertically centred inside [region], the other half of
/// the top-align change (#630/#769/#787).
///
/// This is the preservation guard: it fails if a screen's alignment wrapper
/// is ever hoisted ABOVE its `AsyncValue.when`, which would drag the
/// loading/error branches to the top along with the data branch. A lone
/// spinner does belong in the middle, which is why the `.when` sits outside
/// the wrapper rather than around it.
///
/// [region] is the body the branch is centred in, and it differs by screen
/// shape — header bottom to viewport bottom for a screen with its own
/// [AppBar], or the shell's own content rect for a route embedded in the app
/// shell (which reserves a bottom navigation bar the viewport height knows
/// nothing about). Passing it explicitly is what keeps the assertion honest
/// on both.
void expectVerticallyCentredIn(
  WidgetTester tester,
  Finder finder, {
  required Rect region,
  String label = 'a lone spinner',
  double tolerance = 1.0,
}) {
  expect(
    finder,
    findsOneWidget,
    reason: 'expectVerticallyCentredIn: finder matched no single widget',
  );
  final actual = tester.getCenter(finder).dy;
  expect(
    (actual - region.center.dy).abs(),
    lessThan(tolerance),
    reason:
        '$label must stay in the middle of the body; it rendered at $actual, '
        'body centre ${region.center.dy} (body $region)',
  );
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
