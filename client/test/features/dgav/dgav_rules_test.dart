import 'package:beekeepingit_client/features/dgav/dgav_rules.dart';
import 'package:flutter_test/flutter_test.dart';

/// FR-AP-10 (#298): the two advisory signals the DGAV section shows — is the
/// annual 1–30 September window open, and has the interim-declaration threshold
/// been crossed since the last declaration.
///
/// These are pure date/arithmetic rules with no I/O, deliberately: the exact
/// comparators are the one thing in this feature that is easy to get subtly
/// wrong and impossible to notice afterwards. DGAV's own wording is
/// "alterações significativas **superiores a 20 %** ... sendo estas alterações
/// **iguais ou superiores a 20 colónias**" — a strict `>` on the percentage, a
/// non-strict `>=` on the colony count, joined by AND. The issue's original
/// "≥20% or ≥20" reading was wrong on all three counts, which is why every
/// boundary below is asserted explicitly.
void main() {
  group('isAnnualWindowOpen', () {
    test('is open throughout September', () {
      expect(isAnnualWindowOpen(DateTime(2026, 9, 1)), isTrue);
      expect(isAnnualWindowOpen(DateTime(2026, 9, 15)), isTrue);
      expect(isAnnualWindowOpen(DateTime(2026, 9, 30)), isTrue);
    });

    test('is closed on the days either side of it', () {
      expect(isAnnualWindowOpen(DateTime(2026, 8, 31)), isFalse);
      expect(isAnnualWindowOpen(DateTime(2026, 10, 1)), isFalse);
    });

    test('is closed for the rest of the year', () {
      for (final month in [1, 2, 3, 4, 5, 6, 7, 11, 12]) {
        expect(
          isAnnualWindowOpen(DateTime(2026, month, 10)),
          isFalse,
          reason: 'month $month must not be inside the window',
        );
      }
    });
  });

  group('annualWindowCloseDate', () {
    test("is 30 September of the reference date's own year", () {
      expect(
        annualWindowCloseDate(DateTime(2026, 9, 4)),
        DateTime(2026, 9, 30),
      );
    });

    test('is this year\'s close before September, and next year\'s after it — '
        'the deadline a beekeeper is actually looking at', () {
      expect(
        annualWindowCloseDate(DateTime(2026, 3, 4)),
        DateTime(2026, 9, 30),
      );
      expect(
        annualWindowCloseDate(DateTime(2026, 11, 4)),
        DateTime(2027, 9, 30),
      );
    });
  });

  group('hasDeclaredInAnnualWindow', () {
    test('is true when a declaration falls inside this year\'s window', () {
      expect(
        hasDeclaredInAnnualWindow(
          declarationDates: [DateTime(2026, 9, 12)],
          today: DateTime(2026, 9, 20),
        ),
        isTrue,
      );
    });

    test('is false when the only declaration is from a previous year — the '
        'obligation is annual, so last September does not cover this one', () {
      expect(
        hasDeclaredInAnnualWindow(
          declarationDates: [DateTime(2025, 9, 12)],
          today: DateTime(2026, 9, 20),
        ),
        isFalse,
      );
    });

    test('is false for a declaration outside the window in the same year', () {
      expect(
        hasDeclaredInAnnualWindow(
          declarationDates: [DateTime(2026, 6, 2)],
          today: DateTime(2026, 9, 20),
        ),
        isFalse,
      );
    });

    test('is false with no declarations at all', () {
      expect(
        hasDeclaredInAnnualWindow(
          declarationDates: const [],
          today: DateTime(2026, 9, 20),
        ),
        isFalse,
      );
    });
  });

  group('isInterimTriggerMet', () {
    test('fires when BOTH halves are crossed: >20% and >=20 colonies', () {
      // 100 -> 125: +25% (> 20) and +25 colonies (>= 20).
      expect(
        isInterimTriggerMet(lastDeclaredCount: 100, currentCount: 125),
        isTrue,
      );
    });

    test('does not fire on a large percentage with too few colonies — the '
        'small-holding case the AND exists for', () {
      // 3 -> 4: +33% but only +1 colony. Under an OR reading this would fire,
      // which is exactly the bug the corrected rule avoids.
      expect(
        isInterimTriggerMet(lastDeclaredCount: 3, currentCount: 4),
        isFalse,
      );
    });

    test('does not fire on many colonies at too small a percentage', () {
      // 1000 -> 1030: +30 colonies but only +3%.
      expect(
        isInterimTriggerMet(lastDeclaredCount: 1000, currentCount: 1030),
        isFalse,
      );
    });

    test('treats the percentage as STRICTLY greater than 20 (DGAV: '
        '"superiores a 20 %")', () {
      // 100 -> 120 is exactly +20%, which is NOT "superior a 20%".
      expect(
        isInterimTriggerMet(lastDeclaredCount: 100, currentCount: 120),
        isFalse,
      );
      // 100 -> 121 clears it.
      expect(
        isInterimTriggerMet(lastDeclaredCount: 100, currentCount: 121),
        isTrue,
      );
    });

    test('treats the colony count as AT LEAST 20 (DGAV: "iguais ou superiores '
        'a 20 colónias")', () {
      // 50 -> 70 is +40% and exactly +20 colonies: both halves satisfied.
      expect(
        isInterimTriggerMet(lastDeclaredCount: 50, currentCount: 70),
        isTrue,
      );
      // 50 -> 69 is +38% but only +19 colonies.
      expect(
        isInterimTriggerMet(lastDeclaredCount: 50, currentCount: 69),
        isFalse,
      );
    });

    test('fires on a DECREASE too — the rule is about change, not growth', () {
      // 100 -> 70: -30% and -30 colonies.
      expect(
        isInterimTriggerMet(lastDeclaredCount: 100, currentCount: 70),
        isTrue,
      );
    });

    test('never fires on no change', () {
      expect(
        isInterimTriggerMet(lastDeclaredCount: 100, currentCount: 100),
        isFalse,
      );
      expect(
        isInterimTriggerMet(lastDeclaredCount: 0, currentCount: 0),
        isFalse,
      );
    });

    test('handles a zero baseline without dividing by zero: any change of at '
        'least 20 colonies from nothing counts as material', () {
      expect(
        isInterimTriggerMet(lastDeclaredCount: 0, currentCount: 20),
        isTrue,
      );
      expect(
        isInterimTriggerMet(lastDeclaredCount: 0, currentCount: 19),
        isFalse,
      );
    });
  });

  group('interimDeclarationDeadline', () {
    test('is 10 days after the change', () {
      expect(
        interimDeclarationDeadline(DateTime(2026, 3, 4)),
        DateTime(2026, 3, 14),
      );
    });

    test('crosses a month boundary correctly', () {
      expect(
        interimDeclarationDeadline(DateTime(2026, 3, 27)),
        DateTime(2026, 4, 6),
      );
    });
  });
}
