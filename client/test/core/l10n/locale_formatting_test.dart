import 'package:beekeepingit_client/core/l10n/locale_formatting.dart';
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

    test('formats a date using English month/day/year conventions', () {
      const formatting = LocaleFormatting.forLocale('en');
      expect(formatting.date(date), 'Jul 12, 2026');
    });

    test('formats a date using Portuguese day/month/year conventions', () {
      const formatting = LocaleFormatting.forLocale('pt');
      // Portuguese month names/order differ from English — this is the
      // "locale-specific date convention" NFR-I18N-1 asks for.
      final formatted = formatting.date(date);
      expect(formatted, isNot('Jul 12, 2026'));
      expect(formatted, contains('2026'));
      expect(formatted, contains('12'));
    });

    test('formats a decimal with English (.) grouping/decimal separators', () {
      const formatting = LocaleFormatting.forLocale('en');
      expect(formatting.decimal(1234.5), '1,234.5');
    });

    test(
      'formats a decimal with Portuguese (,) grouping/decimal separators',
      () {
        const formatting = LocaleFormatting.forLocale('pt');
        expect(formatting.decimal(1234.5), '1.234,5');
      },
    );

    test('dateTime appends a localized time (24h "Hm") to the date', () {
      const formatting = LocaleFormatting.forLocale('en');
      final formatted = formatting.dateTime(date);
      expect(formatted, startsWith('Jul 12, 2026'));
      expect(formatted, contains('15:04'));
    });
  });

  group('LocaleFormatting.of (BuildContext)', () {
    testWidgets(
      'reads the active locale from the widget tree, matching AppLocalizations',
      (tester) async {
        LocaleFormatting? formatting;
        AppLocalizations? l10n;

        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('pt'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                formatting = LocaleFormatting.of(context);
                l10n = AppLocalizations.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(l10n!.localeName, 'pt');
        expect(formatting!.decimal(1234.5), '1.234,5');
      },
    );
  });
}
