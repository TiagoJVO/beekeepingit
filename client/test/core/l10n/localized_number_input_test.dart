import 'package:beekeepingit_client/core/l10n/localized_number_input.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The INPUT half of NFR-I18N-1 (#623, #657): a numeric field must accept the
/// active locale's decimal separator, and must never silently turn one number
/// into another. Portugal is the in-scope market (C-2), where the comma is the
/// only decimal separator on a phone keypad — so `40,5` meaning 40.5 kg is the
/// DEFAULT path here, not an edge case.
///
/// The rule these tests pin down (#657): a grouping separator is ALWAYS
/// followed by exactly three digits, a decimal separator by any number. So a
/// lone separator that is not followed by exactly three digits cannot mean
/// thousands, whichever character it is, and is read as the decimal point.
/// Where the input genuinely could mean thousands the ACTIVE LOCALE decides,
/// and where the locale has no reading for the character at all the input is
/// still rejected — never guessed at.
///
/// The two shipped locales (D-34, #656) are `pt-PT` and `en-GB`. European
/// Portuguese groups thousands with a NON-BREAKING SPACE, not a dot — which is
/// why every rule below is expressed against the locale's own separators
/// rather than against `.` and `,`.
void main() {
  const pt = LocalizedNumberInput.forLocale('pt-PT');
  const en = LocalizedNumberInput.forLocale('en-GB');

  /// European Portuguese's grouping separator.
  const nbsp = ' ';

  group('separators', () {
    test('European Portuguese uses a comma decimal separator', () {
      expect(pt.decimalSeparator, ',');
    });

    test('British English uses a full-stop decimal separator', () {
      expect(en.decimalSeparator, '.');
    });

    test('pt-PT groups thousands with a non-breaking space, NOT a dot', () {
      // The whole reason #657's table had to be re-derived: after #656 a dot
      // is not a Portuguese grouping character at all.
      expect(pt.groupingSeparator, nbsp);
      expect(en.groupingSeparator, ',');
    });
  });

  group('parseDouble — the #623 regression stays fixed', () {
    test('pt: "40,5" is 40.5, NOT 405', () {
      expect(pt.parseDouble('40,5'), 40.5);
    });

    test('en: "40.5" still parses to 40.5', () {
      expect(en.parseDouble('40.5'), 40.5);
    });

    test('pt: grouped thousands parse (1 234,5 → 1234.5)', () {
      expect(pt.parseDouble('1${nbsp}234,5'), 1234.5);
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
      expect(en.parseDouble('40.'), 40.0);
    });

    test('a leading separator is a fraction', () {
      expect(pt.parseDouble(',5'), 0.5);
      expect(en.parseDouble('.5'), 0.5);
    });

    test('empty, blank and separator-only input is null', () {
      expect(pt.parseDouble(''), isNull);
      expect(pt.parseDouble('   '), isNull);
      expect(pt.parseDouble(','), isNull);
      expect(en.parseDouble('.'), isNull);
    });

    test('letters and symbols are null, never a partial number', () {
      expect(pt.parseDouble('40kg'), isNull);
      expect(pt.parseDouble('abc'), isNull);
      expect(pt.parseDouble('-40'), isNull);
      expect(en.parseDouble('40kg'), isNull);
      expect(en.parseDouble('-40'), isNull);
    });

    test('two decimal separators are null', () {
      expect(pt.parseDouble('40,5,5'), isNull);
      expect(en.parseDouble('40.5.5'), isNull);
    });
  });

  // --- #657: the other locale's decimal separator, where it cannot mean
  // thousands ---
  //
  // One row of the issue's table per test, in BOTH shipped locales. The table
  // is re-derived for `pt-PT`, whose grouping separator is a non-breaking
  // space: a dot is no longer a Portuguese grouping character, so the rows
  // that read `1.234` as 1234 in Portuguese no longer describe this app.
  group('parseDouble — #657 digit-count disambiguation', () {
    test('1 digit after the foreign separator: it is the decimal point', () {
      // pt-PT: a dot can never introduce thousands here, and `5` is not a
      // group of three under any locale — so `40.5` is 40.5, full stop.
      expect(pt.parseDouble('40.5'), 40.5);
      // en-GB: a comma IS this locale's grouping separator, but grouping
      // takes exactly three digits, so `40,5` cannot be 405 either.
      expect(en.parseDouble('40,5'), 40.5);
    });

    test('2 digits after the foreign separator: still the decimal point', () {
      expect(pt.parseDouble('1.23'), 1.23);
      expect(en.parseDouble('1,23'), 1.23);
    });

    test('4+ digits after the foreign separator: still the decimal point', () {
      // Not a valid grouping (groups are exactly three), so the only
      // coherent reading left is a decimal one.
      expect(pt.parseDouble('1.2345'), 1.2345);
      expect(en.parseDouble('1,2345'), 1.2345);
    });

    test('exactly 3 digits: the ACTIVE LOCALE decides, never a guess', () {
      // en-GB: the comma is this locale's grouping separator and the input
      // is grouping-shaped, so the locale reads thousands.
      expect(en.parseDouble('1,234'), 1234.0);
      // pt-PT: the dot is neither this locale's decimal separator nor its
      // grouping separator, and the input IS grouping-shaped — genuinely
      // ambiguous with no locale rule to break the tie. Rejected visibly
      // rather than read as either 1234 or 1.234.
      expect(pt.parseDouble('1.234'), isNull);
    });

    test('an integer part too long to be a group is a decimal reading', () {
      // `1234` cannot be a leading thousands group, so the separator here
      // cannot be grouping whichever character it is.
      expect(en.parseDouble('1234,567'), 1234.567);
      expect(pt.parseDouble('1234.567'), 1234.567);
    });

    test(
      'a foreign separator repeated is grouping-shaped, so not a decimal',
      () {
        // Two dots cannot both be decimal points; in pt-PT they cannot be
        // grouping either. Rejected, not read as 1234.567.
        expect(pt.parseDouble('1.234.567'), isNull);
        expect(pt.parseDouble('1.234.5'), isNull);
        // In en-GB the same shape IS the locale's own grouping.
        expect(en.parseDouble('1,234,567'), 1234567.0);
      },
    );

    test('a foreign separator plus the locale decimal: the foreign one '
        'groups', () {
      // The comma is unambiguously pt-PT's decimal separator, so the dot has
      // no role left but grouping — and it is followed by exactly three
      // digits, so it is well-formed grouping.
      expect(pt.parseDouble('1.234,5'), 1234.5);
      // en-GB's own pair, for the mirror image.
      expect(en.parseDouble('1,234.5'), 1234.5);
      // The boundary of "the other locale's DECIMAL separator": a character
      // no shipped locale uses as a decimal point stays foreign, so en-GB
      // does not quietly learn pt-PT's grouping space.
      expect(en.parseDouble('1${nbsp}234.5'), isNull);
    });

    test('malformed grouping alongside the locale decimal is still null', () {
      expect(pt.parseDouble('1.23,5'), isNull);
      expect(pt.parseDouble('1.2345,6'), isNull);
      expect(en.parseDouble('1,23.5'), isNull);
    });

    test('a grouping separator inside the fraction is still null', () {
      expect(pt.parseDouble('1,234.5'), isNull);
      expect(en.parseDouble('1.234,5'), isNull);
    });

    test('the grouping separator alone is never read as a decimal point', () {
      // No locale uses a space as a decimal separator, so a non-breaking
      // space that is not valid grouping has no reading at all.
      expect(pt.parseDouble('1${nbsp}2345'), isNull);
      expect(pt.parseDouble('1${nbsp}23'), isNull);
      expect(pt.parseDouble('40${nbsp}5'), isNull);
    });

    test('the rule follows the locale, not hard-coded characters', () {
      // Generic `pt` is BRAZILIAN: its grouping separator IS the dot. The
      // same input therefore reads differently there — proof the rule is
      // computed from the active locale's symbols. (#656 moved the app off
      // this locale; it stands in here for any dot-grouping locale, e.g.
      // `de-DE`, that might be added later.)
      const ptBr = LocalizedNumberInput.forLocale('pt');
      expect(ptBr.groupingSeparator, '.');
      // Grouping-shaped AND the dot is this locale's grouping separator →
      // the locale wins, exactly as #657's original table said.
      expect(ptBr.parseDouble('1.234'), 1234.0);
      // ...but a lone dot that cannot be grouping is still a decimal point.
      expect(ptBr.parseDouble('40.5'), 40.5);
      expect(ptBr.parseDouble('1.2345'), 1.2345);
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

    test('#657: the foreign separator is read, then still rejected as '
        'fractional — never truncated and never 125', () {
      expect(pt.parseInt('12.5'), isNull);
      expect(en.parseInt('12,5'), isNull);
    });

    test('a zero fraction is still a whole number', () {
      expect(pt.parseInt('12,0'), 12);
      expect(pt.parseInt('12.0'), 12);
    });

    test('grouped thousands parse to an int', () {
      expect(pt.parseInt('999${nbsp}999${nbsp}999'), 999999999);
      expect(en.parseInt('999,999,999'), 999999999);
    });

    test('empty and unparseable input is null', () {
      expect(pt.parseInt(''), isNull);
      expect(pt.parseInt('abc'), isNull);
      expect(pt.parseInt('1.234'), isNull);
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

    test('the other locale\'s decimal separator survives the filter, so the '
        'parser can read it (#657) or reject it visibly', () {
      expect(filter(pt, '40.5'), '40.5');
      expect(filter(en, '40,5'), '40,5');
    });

    test('the locale grouping separator survives the filter', () {
      expect(filter(pt, '1${nbsp}234'), '1${nbsp}234');
      expect(filter(en, '1,234'), '1,234');
    });

    test('letters and signs are still filtered out', () {
      expect(filter(pt, '4a0,5kg'), '40,5');
      expect(filter(pt, '-40'), '40');
    });
  });
}
