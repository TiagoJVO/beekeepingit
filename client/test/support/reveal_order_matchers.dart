import 'package:flutter_test/flutter_test.dart';

/// Asserts a conditionally-revealed field renders directly below the
/// dropdown that reveals it, and above every field named in [notBetween] —
/// the concrete, checkable form of "the revealed field sits directly under
/// its trigger" (#637).
///
/// This checks GEOMETRY, not presence. A plain `find.byKey(...)` /
/// `findsOneWidget` assertion only proves the revealed field exists
/// SOMEWHERE in the tree — it passes just as happily whether the field
/// renders right after its trigger or three fields further down, which is
/// exactly the shape of #637's bug: `activity-disease-field` was present,
/// `findsOneWidget` was green, and the field still rendered below
/// `activity-treatment-type-field` instead of directly below the context
/// dropdown that reveals it. Only comparing the rendered `top` of each
/// field's rect — not just its existence — catches the ordering.
///
/// [revealed] must be the finder for the conditionally-shown field,
/// [trigger] the finder for the dropdown whose selection reveals it, and
/// [notBetween] every OTHER field on the form that must not end up sitting
/// between the trigger and the revealed field.
void expectRevealedDirectlyBelow(
  WidgetTester tester, {
  required Finder revealed,
  required Finder trigger,
  required Iterable<Finder> notBetween,
  required String reason,
}) {
  expect(
    revealed,
    findsOneWidget,
    reason: 'expectRevealedDirectlyBelow: revealed finder ($reason)',
  );
  expect(
    trigger,
    findsOneWidget,
    reason: 'expectRevealedDirectlyBelow: trigger finder ($reason)',
  );

  final revealedTop = tester.getRect(revealed).top;
  final triggerTop = tester.getRect(trigger).top;

  expect(
    revealedTop,
    greaterThan(triggerTop),
    reason: '$reason (revealed field must render below its trigger)',
  );

  for (final other in notBetween) {
    expect(
      other,
      findsOneWidget,
      reason: 'expectRevealedDirectlyBelow: a notBetween finder ($reason)',
    );
    final otherTop = tester.getRect(other).top;
    expect(
      revealedTop,
      lessThan(otherTop),
      reason:
          '$reason (revealed field must render above every other field on '
          'the form, not just below its trigger — otherwise it could sit '
          'anywhere after the trigger and still pass)',
    );
  }
}
