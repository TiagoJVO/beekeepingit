/// Shared helpers for the "a toast must not cover the last row" contract
/// (#773, FR-UX-2/FR-AX-1).
///
/// `#631` pinned that contract once, on the app shell, in
/// `test/shell/toast_placement_test.dart` — where the toast lands. These
/// helpers are the other half of it: the per-screen check that the screen
/// reserves a band tall enough for whatever the `Scaffold` puts there. Kept
/// here rather than re-derived per file because the four screens `#773`
/// covers live in four different suites with four different harnesses, and a
/// clearance assertion that measures a slightly different rect in each one is
/// worth nothing.
library;

import 'package:beekeepingit_client/theming/brand_dimens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A field phone with an iOS-style home-indicator inset (375x812 + 34).
///
/// The inset is not decoration: on a screen with no bottom navigation a fixed
/// `SnackBar` carries the safe-area padding *inside* its own [Material], so
/// the opaque bar reaches the window bottom and covers 34 more logical pixels
/// of body than the same toast does inside the shell. A clearance measured on
/// a phone with no inset would miss that entirely.
///
/// [textScale] drives the FR-AX-1 case that makes this bite: at 200% the
/// toast's message wraps and the band it needs roughly doubles.
void useFieldPhone(WidgetTester tester, {double textScale = 1}) {
  tester.view.physicalSize = const Size(375, 812);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(bottom: 34);
  tester.view.viewPadding = const FakeViewPadding(bottom: 34);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// Scrolls [scrollable] all the way to its end — the resting state the bug
/// shows up in, where the last row sits as close to the bottom chrome as it
/// can get.
///
/// Drags repeatedly rather than once: a sliver list only learns its true
/// extent as rows are built, so at 200% text a single large drag lands short
/// of the end because `maxScrollExtent` grows underneath it. Asserts it
/// actually arrived, so a clearance test can never pass by simply failing to
/// scroll.
Future<void> scrollToEnd(WidgetTester tester, Finder scrollable) async {
  ScrollPosition position() => tester
      .state<ScrollableState>(
        find
            .descendant(of: scrollable, matching: find.byType(Scrollable))
            .first,
      )
      .position;

  for (var attempt = 0; attempt < 12; attempt++) {
    final scroll = position();
    if (scroll.pixels >= scroll.maxScrollExtent) break;
    await tester.drag(scrollable, const Offset(0, -2000));
    await tester.pumpAndSettle();
  }

  final scroll = position();
  expect(
    scroll.pixels,
    closeTo(scroll.maxScrollExtent, 0.5),
    reason: 'the list did not reach its end, so nothing was really tested',
  );
}

/// The toast's *visible* bar — the opaque [Material], not the [SnackBar]
/// element that may wrap it in positioning padding.
///
/// A `ScaffoldMessenger` presents a bar in the **root** `Scaffold` of a
/// nested set only (`ScaffoldMessengerState._isRoot`), so this always matches
/// exactly one bar even on a screen that nests its own `Scaffold` inside the
/// shell's — the history screen does.
Rect toastRect(WidgetTester tester) => tester.getRect(
  find
      .descendant(of: find.byType(SnackBar), matching: find.byType(Material))
      .first,
);

/// Raises a toast the way every call site does — hand it to the messenger
/// from whatever screen is up and let the enclosing `Scaffold` place it.
///
/// [message] has no default on purpose. The band a screen reserves is sized
/// against the toasts *that screen* raises, and toast height is all message
/// length: pass the screen's own ARB copy, not a placeholder, or the
/// assertion measures a message the user will never see.
Future<void> showToast(WidgetTester tester, {required String message}) async {
  ScaffoldMessenger.of(tester.element(find.byType(Scaffold).first))
      .showSnackBar(SnackBar(content: Text(message)));
  await tester.pumpAndSettle();
}

/// Asserts [scrollable] leaves a full [BrandDimens.scrollBottomInsetOf] band
/// below [lastRow] once it is scrolled to its end.
///
/// The structural form of the same contract [expectToastClearsLastRow]
/// checks behaviourally, for the two screens `#773` covers that raise no
/// toast of their own — the history timeline and the needs-fix list. A toast
/// still reaches them (`ScaffoldMessenger` re-presents its queue in whatever
/// `Scaffold` is up, so one raised on the screen you came from is still there
/// when this one replaces it — `ScaffoldMessengerState._register`), but there
/// is no message *of theirs* to measure, and probing with an arbitrary one
/// measures the message rather than the screen.
void expectReservesBottomBand(
  WidgetTester tester, {
  required Finder lastRow,
  required Finder scrollable,
  required String reason,
}) {
  final viewport = tester.getRect(scrollable);
  final row = tester.getRect(lastRow);
  final band = BrandDimens.scrollBottomInsetOf(tester.element(scrollable));
  expect(
    viewport.bottom - row.bottom,
    greaterThanOrEqualTo(band),
    reason:
        '$reason\nviewport: $viewport\nlast row: $row\n'
        'reserved: ${viewport.bottom - row.bottom} of a required $band',
  );
}

/// Asserts the toast lands clear of [lastRow] — the bottom-most content the
/// screen renders once it is scrolled to its end.
void expectToastClearsLastRow(
  WidgetTester tester,
  Finder lastRow, {
  required String reason,
}) {
  final toast = toastRect(tester);
  final row = tester.getRect(lastRow);
  expect(
    toast.overlaps(row),
    isFalse,
    reason:
        '$reason\ntoast: $toast\nlast row: $row\n'
        'overlap: ${row.bottom - toast.top} logical pixels',
  );
}
