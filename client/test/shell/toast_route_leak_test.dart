/// A toast does not outlive the screen that raised it (#640).
///
/// `MaterialApp` installs a single root `ScaffoldMessenger`, and `app.dart`
/// uses `MaterialApp.router` without a `scaffoldMessengerKey`, so that one
/// messenger — and its queue — spans every route. A message parked behind a
/// still-visible bar therefore surfaces after the user has already left the
/// screen that raised it, reporting an action against unrelated content.
///
/// Two routes and a `Navigator` are all this needs; toast_placement_test.dart
/// boots the real shell because *placement* depends on the shell's chrome,
/// and lifetime does not.
library;

import 'package:beekeepingit_client/core/widgets/app_toast.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _saved = 'Apiary saved';
const _deleted = 'Apiary deleted';
const _secondScreenTitle = 'Screen two';

/// The origin screen: it raises toasts through the shared helper and can
/// navigate away, which is the save-then-go-back shape used all over
/// `client/lib` (e.g. apiary_form_screen.dart).
class _OriginScreen extends StatelessWidget {
  const _OriginScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              key: const Key('raise-two'),
              onPressed: () {
                final messenger = ScaffoldMessenger.of(context);
                showAppToast(messenger, _saved);
                showAppToast(messenger, _deleted);
              },
              child: const Text('raise two'),
            ),
            ElevatedButton(
              key: const Key('raise-one-and-go'),
              onPressed: () {
                showAppToast(ScaffoldMessenger.of(context), _saved);
                Navigator.of(context).pushNamed('/second');
              },
              child: const Text('raise one and go'),
            ),
            ElevatedButton(
              key: const Key('go'),
              onPressed: () => Navigator.of(context).pushNamed('/second'),
              child: const Text('go'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecondScreen extends StatelessWidget {
  const _SecondScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: Text(_secondScreenTitle)));
}

void main() {
  Widget host() => MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    initialRoute: '/',
    routes: {
      '/': (_) => const _OriginScreen(),
      '/second': (_) => const _SecondScreen(),
    },
  );

  /// One route transition, in timed pumps — `pumpAndSettle` would also run
  /// the bar's dismiss timers to exhaustion and drain a queued message,
  /// which is exactly what these tests are looking for.
  Future<void> pumpRouteTransition(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a message raised on one screen never surfaces on the next', (
    tester,
  ) async {
    await tester.pumpWidget(host());

    await tester.tap(find.byKey(const Key('raise-two')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('go')));
    await pumpRouteTransition(tester);

    expect(
      find.text(_secondScreenTitle),
      findsOneWidget,
      reason: 'precondition: the user has left the screen that raised them',
    );

    // Past the first bar's whole life (~4.5s), and inside the window a
    // *queued* second bar would occupy (~4.5s-9s) — so this instant tells
    // "one bar, expired" apart from "a second bar, still to come".
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text(_deleted),
      findsNothing,
      reason:
          'a message queued on the previous route must not surface over an '
          'unrelated screen',
    );
    expect(find.text(_saved), findsNothing);
  });

  // The guard against over-fixing: almost every save in this client confirms
  // and *then* navigates (apiary_form_screen.dart pops back to the list on
  // success). Clearing too eagerly, or scoping the messenger per route, would
  // take that confirmation away from the destination it was meant to be read
  // on. This case must pass both before and after the #640 fix.
  testWidgets('a confirmation raised just before navigating is still visible '
      'on the destination', (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(find.byKey(const Key('raise-one-and-go')));
    await pumpRouteTransition(tester);

    expect(find.text(_secondScreenTitle), findsOneWidget);
    expect(
      find.text(_saved),
      findsOneWidget,
      reason:
          'the confirmation has to survive the navigation the save itself '
          'triggered, or the user never sees it',
    );
  });
}
