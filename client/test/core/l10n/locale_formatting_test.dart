import 'package:beekeepingit_client/core/l10n/locale_formatting.dart';
import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Locale-aware date/number formatting (NFR-I18N-1, #77 AC). No screen shows
/// a date or decimal number yet (see locale_formatting.dart's doc comment),
/// so these tests exercise the helper directly rather than through a widget
/// that doesn't exist — it's ready for the first feature that needs it.
void main() {
  // `LocaleFormatting.forLocale` calls straight into `intl`'s `DateFormat`
  // outside of a widget tree, so unlike `testWidgets` (where
  // `GlobalMaterialLocalizations` initializes date symbol data for every
  // supported locale automatically), plain `test()` blocks need it loaded
  // explicitly, or a non-English `DateFormat` throws `LocaleDataException`.
  setUpAll(() async {
    await initializeDateFormatting();
  });

  group('LocaleFormatting.forLocale (unit)', () {
    final date = DateTime(2026, 7, 12, 15, 4);

    test('formats a date using British day/month/year ordering (#656)', () {
      // British English puts the day first — American English is
      // `Jul 12, 2026`. Shipping generic `en` gave us the American form
      // (D-34).
      const formatting = LocaleFormatting.forLocale('en_GB');
      expect(formatting.date(date), '12 Jul 2026');
    });

    test('formats a date using European Portuguese month names (#656)', () {
      const formatting = LocaleFormatting.forLocale('pt_PT');
      // Note the trailing dot: CLDR's abbreviated pt-PT months are
      // `jan.`/`fev.`/…/`set.`/…/`dez.`, all abbreviated WITH a full stop.
      expect(formatting.date(date), '12 jul. 2026');
    });

    test('the month is NAMED, never numeric, in both locales — the pinned '
        'pattern overriding CLDR (D-34)', () {
      // CLDR's own medium date for pt-PT is numeric `d/MM/y` → `3/09/2026`.
      // The app pins `d MMM y` instead, because a numeric date is the one
      // form a field reader can genuinely misread (`3/09` vs `09/03`).
      // September is the sharp case: it is the month where en-GB's
      // abbreviation is four letters, and where a numeric `09` reads as
      // March under the other ordering.
      final september = DateTime(2026, 9, 3);
      expect(
        const LocaleFormatting.forLocale('pt_PT').date(september),
        '3 set. 2026',
      );
      expect(
        const LocaleFormatting.forLocale('en_GB').date(september),
        '3 Sept 2026',
      );
      // Every month renders as a name, not digits, in both locales.
      for (var month = 1; month <= 12; month++) {
        for (final locale in const ['pt_PT', 'en_GB']) {
          final formatted = LocaleFormatting.forLocale(
            locale,
          ).date(DateTime(2026, month, 15));
          expect(
            formatted,
            matches(RegExp(r'^15 \D')),
            reason: '$locale month $month must render a name, not a number',
          );
        }
      }
    });

    test('formats a decimal with English (.) grouping/decimal separators', () {
      const formatting = LocaleFormatting.forLocale('en_GB');
      expect(formatting.decimal(1234.5), '1,234.5');
    });

    test(
      'formats a decimal with European Portuguese separators — a NON-BREAKING '
      'SPACE for thousands, not the Brazilian full stop (#656)',
      () {
        const formatting = LocaleFormatting.forLocale('pt_PT');
        expect(formatting.decimal(1234.5), '1\u00A0234,5');
      },
    );

    // #624: the display half of NFR-I18N-1 — a stored number rendered with
    // `toString()` shows an English full stop and no grouping in every
    // locale. `number()` is the "as many decimals as the value has, grouped"
    // formatter the activity list/detail rows use.
    test('number: pt-PT renders a decimal with a comma, not a full stop', () {
      const formatting = LocaleFormatting.forLocale('pt_PT');
      expect(formatting.number(62.5), '62,5');
    });

    test('number: en-GB renders the same decimal with a full stop', () {
      const formatting = LocaleFormatting.forLocale('en_GB');
      expect(formatting.number(62.5), '62.5');
    });

    test('number: a whole number keeps no spurious decimals', () {
      expect(const LocaleFormatting.forLocale('pt_PT').number(4), '4');
      expect(const LocaleFormatting.forLocale('en_GB').number(4), '4');
    });

    test('number: large integers are grouped in both locales', () {
      // Grouping is the locale's own — pt-PT groups with a non-breaking
      // space, en-GB with `,`.
      expect(
        const LocaleFormatting.forLocale('pt_PT').number(999999999),
        '999\u00A0999\u00A0999',
      );
      expect(
        const LocaleFormatting.forLocale('en_GB').number(999999999),
        '999,999,999',
      );
    });

    test('dateTime appends a localized time (24h "Hm") to the date', () {
      const formatting = LocaleFormatting.forLocale('en_GB');
      final formatted = formatting.dateTime(date);
      expect(formatted, startsWith('12 Jul 2026'));
      expect(formatted, contains('15:04'));
    });

    test(
      'dateTime writes the month exactly as date() does, in both locales — a '
      'timestamp and a date never disagree (D-34)',
      () {
        for (final locale in const ['pt_PT', 'en_GB']) {
          final formatting = LocaleFormatting.forLocale(locale);
          expect(formatting.dateTime(date), startsWith(formatting.date(date)));
          expect(formatting.dateTime(date), contains('15:04'));
        }
        expect(
          const LocaleFormatting.forLocale('pt_PT').dateTime(date),
          '12 jul. 2026 15:04',
        );
        expect(
          const LocaleFormatting.forLocale('en_GB').dateTime(date),
          '12 Jul 2026 15:04',
        );
      },
    );
  });

  group('LocaleFormatting.of (BuildContext)', () {
    /// #656's first landmine: `LocaleFormatting.of` used to read
    /// `locale.languageCode`, throwing the country away — so every date and
    /// number in the app was formatted as generic `pt`/`en` (i.e. Brazilian
    /// and American) no matter which locale the tree had resolved to.
    Future<LocaleFormatting> formattingIn(
      WidgetTester tester,
      Locale locale,
    ) async {
      late LocaleFormatting formatting;
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
          home: Builder(
            builder: (context) {
              formatting = LocaleFormatting.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      return formatting;
    }

    testWidgets(
      'carries the COUNTRY of the resolved locale, not just its language',
      (tester) async {
        final pt = await formattingIn(tester, const Locale('pt', 'PT'));
        expect(pt.decimal(1234.5), '1\u00A0234,5');
        expect(pt.date(DateTime(2026, 9, 3)), '3 set. 2026');

        final en = await formattingIn(tester, const Locale('en', 'GB'));
        expect(en.date(DateTime(2026, 9, 3)), '3 Sept 2026');
      },
    );

    testWidgets(
      'a legacy generic locale still resolves to the supported country '
      'variant (#656 migration)',
      (tester) async {
        // An existing profile stores `pt`; Flutter resolves it against
        // supportedLocales to `pt_PT`, so the formatting must be European.
        final pt = await formattingIn(tester, const Locale('pt'));
        expect(pt.decimal(1234.5), '1\u00A0234,5');

        expect(pt.date(DateTime(2026, 9, 3)), '3 set. 2026');

        final en = await formattingIn(tester, const Locale('en'));
        expect(en.date(DateTime(2026, 9, 3)), '3 Sept 2026');
      },
    );
  });
}
