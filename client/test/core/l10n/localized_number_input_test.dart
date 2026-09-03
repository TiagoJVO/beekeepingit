import 'package:beekeepingit_client/core/l10n/localized_number_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The INPUT half of NFR-I18N-1 (#623): a numeric field must accept the
/// active locale's decimal separator, and must never silently turn one
/// number into another. Portugal is the only in-scope locale (C-2), where
/// the comma is the only decimal separator on a phone keypad — so `40,5`
/// meaning 40.5 kg is the DEFAULT path here, not an edge case.
///
/// The rule these tests pin down: digits, the locale's decimal separator and
/// the locale's grouping separator (in valid 3-digit groups) parse; anything
/// else returns null so the caller can reject it VISIBLY. Notably `40.5`
/// typed in Portuguese is *not* silently read as 405 — it is rejected,
/// because `.` is pt's grouping separator and `5` is not a valid group.
void main() {
  const pt = LocalizedNumberInput.forLocale('pt');
  const en = LocalizedNumberInput.forLocale('en');

  group('separators', () {
    test('Portuguese uses a comma decimal separator', () {
      expect(pt.decimalSeparator, ',');
    });

    test('English uses a full-stop decimal separator', () {
      expect(en.decimalSeparator, '.');
    });

    test('the grouping separator is the other one in each locale', () {
      expect(pt.groupingSeparator, isNot(pt.decimalSeparator));
      expect(en.groupingSeparator, ',');
    });
  });

  group('parseDouble — the #623 regression', () {
    test('pt: "40,5" is 40.5, NOT 405', () {
      expect(pt.parseDouble('40,5'), 40.5);
    });

    test('en: "40.5" still parses to 40.5', () {
      expect(en.parseDouble('40.5'), 40.5);
    });

    test('pt: the foreign separator is rejected, never read as 405', () {
      // `.` is pt's GROUPING separator, and `5` is not a 3-digit group, so
      // this is unparseable — the caller shows an error instead of storing
      // a value 10x the intended one.
      expect(pt.parseDouble('40.5'), isNull);
    });

    test('en: a comma that is not valid grouping is rejected', () {
      expect(en.parseDouble('40,5'), isNull);
    });

    test('pt: grouped thousands parse (1.234,5 → 1234.5)', () {
      expect(pt.parseDouble('1.234,5'), 1234.5);
    });

    test('en: grouped thousands parse (1,234.5 → 1234.5)', () {
      expect(en.parseDouble('1,234.5'), 1234.5);
    });

    test('a plain integer parses in both locales', () {
      expect(pt.parseDouble('40'), 40.0);
      expect(en.parseDouble('40'), 40.0);
    });

    test('surrounding whitespace is tolerated', () {
      expect(pt.parseDouble('  40,5 '), 40.5);
    });

    test('a trailing separator is the integer value (no mid-typing error)', () {
      expect(pt.parseDouble('40,'), 40.0);
    });

    test('a leading separator is a fraction', () {
      expect(pt.parseDouble(',5'), 0.5);
    });

    test('empty, blank and separator-only input is null', () {
      expect(pt.parseDouble(''), isNull);
      expect(pt.parseDouble('   '), isNull);
      expect(pt.parseDouble(','), isNull);
    });

    test('letters and symbols are null, never a partial number', () {
      expect(pt.parseDouble('40kg'), isNull);
      expect(pt.parseDouble('abc'), isNull);
      expect(pt.parseDouble('-40'), isNull);
    });

    test('two decimal separators are null', () {
      expect(pt.parseDouble('40,5,5'), isNull);
    });

    test('malformed grouping is null, not silently joined', () {
      expect(pt.parseDouble('1.23'), isNull);
      expect(pt.parseDouble('1.2345'), isNull);
      expect(en.parseDouble('1,23'), isNull);
    });
  });

  group('parseInt', () {
    test('pt: a whole number parses', () {
      expect(pt.parseInt('12'), 12);
    });

    test('pt: "12,5" is rejected rather than truncated to 125 or 12', () {
      // The pre-#623 `digitsOnly` formatter turned this into "125".
      expect(pt.parseInt('12,5'), isNull);
    });

    test('en: "12.5" is rejected rather than truncated', () {
      expect(en.parseInt('12.5'), isNull);
    });

    test('a zero fraction is still a whole number', () {
      expect(pt.parseInt('12,0'), 12);
    });

    test('grouped thousands parse to an int', () {
      expect(pt.parseInt('999.999.999'), 999999999);
      expect(en.parseInt('999,999,999'), 999999999);
    });

    test('empty and unparseable input is null', () {
      expect(pt.parseInt(''), isNull);
      expect(pt.parseInt('abc'), isNull);
    });
  });

  group('format (prefilling a text field for editing)', () {
    test('pt: a fractional value uses the comma the field accepts', () {
      // The edit form must round-trip: what `format` writes into the field
      // is exactly what `parseDouble` reads back out.
      expect(pt.format(40.5), '40,5');
      expect(pt.parseDouble(pt.format(40.5)), 40.5);
    });

    test('en: a fractional value uses the full stop', () {
      expect(en.format(40.5), '40.5');
    });

    test('a whole double has no trailing ".0" in either locale', () {
      expect(pt.format(40.0), '40');
      expect(en.format(40.0), '40');
    });

    test('an int formats as plain digits, ungrouped (it is editable text)', () {
      expect(pt.format(999999999), '999999999');
      expect(pt.parseInt(pt.format(999999999)), 999999999);
    });
  });

  group('formatters (what the keyboard is allowed to enter)', () {
    TextEditingValue typed(String text) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );

    String filter(LocalizedNumberInput input, String text) {
      var value = const TextEditingValue();
      for (final formatter in input.formatters) {
        value = formatter.formatEditUpdate(value, typed(text));
      }
      return value.text;
    }

    test('pt: the comma survives the input filter (the #623 root cause)', () {
      expect(filter(pt, '40,5'), '40,5');
    });

    test('en: the full stop survives the input filter', () {
      expect(filter(en, '40.5'), '40.5');
    });

    test('the foreign separator is kept, so the parser can reject it visibly '
        'instead of the filter dropping it silently', () {
      expect(filter(pt, '40.5'), '40.5');
      expect(filter(en, '40,5'), '40,5');
    });

    test('letters and signs are still filtered out', () {
      expect(filter(pt, '4a0,5kg'), '40,5');
      expect(filter(pt, '-40'), '40');
    });
  });
}
