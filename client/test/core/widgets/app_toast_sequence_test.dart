/// A confirmation toast reports the action the user *just* took (#640).
///
/// `ScaffoldMessenger.showSnackBar` queues: raising a second bar while the
/// first is still on screen (4s by default) leaves the first one showing and
/// parks the second behind it. Every toast call site in `client/lib` raises
/// one that way, so a second action taken inside that 4s window shows the
/// *previous* action's message — the toast reads one action behind — and the
/// parked message surfaces later, on whatever screen the user has reached by
/// then.
///
/// This pins the contract once, on the shared helper, rather than at the ~56
/// call sites (where the 57th would reintroduce it).
library;

import 'package:beekeepingit_client/core/widgets/app_toast.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stand-in messages. This helper's contract is about *sequencing*, not copy,
/// so the strings only have to be distinguishable from one another; the
/// real-copy assertions live in members_screen_test.dart.
const _first = 'first message';
const _second = 'second message';
const _third = 'third message';

void main() {
  final messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// The messenger a call site would capture before its async gap — the same
  /// object [showAppToast] is meant to take.
  ScaffoldMessengerState messenger() {
    final state = messengerKey.currentState;
    if (state == null) {
      fail('host() must be pumped before a toast is raised');
    }
    return state;
  }

  // The toast's content resolves `AppLocalizations.of` on its truncated
  // branch, so the delegates stay part of the harness rather than optional
  // dressing — a longer message here must not blow up on a missing delegate.
  Widget host() => MaterialApp(
    scaffoldMessengerKey: messengerKey,
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(body: SizedBox.expand()),
  );

  /// Advances past a replacement's exit + enter animation.
  ///
  /// Deliberately timed pumps rather than `pumpAndSettle`: settling runs the
  /// bar's dismiss timers to exhaustion, which would drain a *queued* message
  /// too and hide the very defect under test.
  Future<void> pumpToastSwap(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Raises [message] and leaves it on screen, mid-life — the state a second
  /// action arrives in.
  Future<void> raiseAndHold(WidgetTester tester, String message) async {
    showAppToast(messenger(), message);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a second toast replaces the first instead of queueing behind '
      'it', (tester) async {
    await tester.pumpWidget(host());

    await raiseAndHold(tester, _first);
    expect(
      find.text(_first),
      findsOneWidget,
      reason: 'precondition: the first toast is still on screen',
    );

    showAppToast(messenger(), _second);
    await pumpToastSwap(tester);

    expect(
      find.text(_second),
      findsOneWidget,
      reason:
          'the toast reports the action the user just took, not the one '
          'before it',
    );
    expect(
      find.text(_first),
      findsNothing,
      reason: 'the superseded message is gone, not still occupying the bar',
    );
  });

  testWidgets('neither message lingers once the replacement has run its '
      'course (nothing was queued)', (tester) async {
    await tester.pumpWidget(host());

    await raiseAndHold(tester, _first);
    showAppToast(messenger(), _second);
    await pumpToastSwap(tester);

    // ~1.8s elapsed: the replacement is on screen with its own 4s life
    // running. Advance past that life, but stay short of the window a
    // *queued* first-then-second pair would still occupy (~9s), so the
    // assertion can tell "one bar, expired" from "two bars, in sequence".
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text(_first),
      findsNothing,
      reason: 'the replaced message was discarded, not parked behind',
    );
    expect(
      find.text(_second),
      findsNothing,
      reason:
          'exactly one bar was shown for the pair; a second one surfacing '
          'here is the message that outlives the action that raised it',
    );
  });

  testWidgets('a burst of actions shows only the last one', (tester) async {
    await tester.pumpWidget(host());

    showAppToast(messenger(), _first);
    showAppToast(messenger(), _second);
    showAppToast(messenger(), _third);
    await pumpToastSwap(tester);

    expect(find.text(_third), findsOneWidget);
    expect(find.text(_first), findsNothing);
    expect(find.text(_second), findsNothing);
  });
}
