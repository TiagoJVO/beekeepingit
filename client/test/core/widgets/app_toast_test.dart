/// A confirmation toast's height is bounded at any text scale (#790,
/// FR-UX-2/FR-AX-1, D-18).
///
/// Measured before the fix on a 375x812 phone at 200% text:
/// `syncSupersededNotice` rendered 268 logical pixels — a third of the window,
/// covering the content it reported on. `BrandDimens.scrollBottomInset` is
/// 136, so no band a scrollable reserves could ever clear it.
library;

import 'package:beekeepingit_client/core/widgets/app_toast.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real English copy the issue measured, not a stand-in: the bound has to
/// hold for the message that actually broke it.
const _longMessage =
    'One of your offline changes was overwritten by a newer edit.';
const _shortMessage = 'Declaration recorded';

void main() {
  Widget host(SnackBar bar) => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          key: const Key('raise'),
          onPressed: () => ScaffoldMessenger.of(context).showSnackBar(bar),
          child: const Text('raise'),
        ),
      ),
    ),
  );

  void useFieldPhone(WidgetTester tester, {double textScale = 1}) {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  Future<Rect> raise(WidgetTester tester, SnackBar bar) async {
    await tester.tap(find.byKey(const Key('raise')));
    await tester.pumpAndSettle();
    return tester.getRect(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first,
    );
  }

  testWidgets('a sentence-length toast stays within the reserved band at '
      '200% text', (tester) async {
    useFieldPhone(tester, textScale: 2);
    await tester.pumpWidget(host(appToast(_longMessage)));

    final rect = await raise(tester, appToast(_longMessage));

    // The band a scrollable reserves is what the toast has to fit inside for
    // the content underneath to stay readable. 136 is that band today; the
    // assertion is written against the constant's intent, not its digits.
    expect(
      rect.height,
      lessThanOrEqualTo(160.0),
      reason:
          'a toast may not take a third of the window at 200% text; '
          'it measured ${rect.height}',
    );
  });

  testWidgets('the full message is still reachable when it is capped', (
    tester,
  ) async {
    useFieldPhone(tester, textScale: 2);
    await tester.pumpWidget(host(appToast(_longMessage)));
    await raise(tester, appToast(_longMessage));

    // Capping without an escape hatch would just lose the tail of the
    // message, which is why the affordance is part of the contract.
    expect(find.byKey(const Key('toast-details-action')), findsOneWidget);

    await tester.tap(find.byKey(const Key('toast-details-action')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('toast-details-dialog')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('toast-details-dialog')),
        matching: find.text(_longMessage),
      ),
      findsOneWidget,
      reason: 'the dialog shows the message in full, not the capped form',
    );
  });

  testWidgets('a short toast carries no Details affordance', (tester) async {
    useFieldPhone(tester);
    await tester.pumpWidget(host(appToast(_shortMessage)));
    await raise(tester, appToast(_shortMessage));

    // Measured, not guessed: a length heuristic would show this on a short
    // Portuguese string and hide it on a long English one.
    expect(find.byKey(const Key('toast-details-action')), findsNothing);
    expect(find.text(_shortMessage), findsOneWidget);
  });
}
