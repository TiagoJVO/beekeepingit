import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// D-34 (#656, NFR-I18N-1, C-2): the app ships European Portuguese and
/// British English only, and this file is the single place a stored locale
/// code is turned into one of them.
///
/// The behaviour worth pinning is the MIGRATION: every profile written before
/// #656 stores the bare `pt`/`en`, and those users must keep the language
/// they chose while gaining the right conventions — never silently left on a
/// value the app cannot render, and never coerced when the language itself is
/// one we do not ship.
void main() {
  group('kSupportedLocales', () {
    test(
      'is exactly British English and European Portuguese, in that order',
      () {
        expect(kSupportedLocales, const [
          Locale('en', 'GB'),
          Locale('pt', 'PT'),
        ]);
        // Order is load-bearing: Flutter falls back to the FIRST supported
        // locale for an unmatched device locale.
        expect(kDefaultLocale, kSupportedLocales.first);
      },
    );

    test('every offered locale carries a country code', () {
      for (final locale in kSupportedLocales) {
        expect(
          locale.countryCode,
          isNotNull,
          reason:
              '$locale would resolve to CLDR\'s default region for its '
              'language — Brazilian for pt, American for en',
        );
      }
    });

    test('the tag constants match their Locale', () {
      expect(kDefaultLocaleTag, kDefaultLocale.toLanguageTag());
      expect(kPortugueseLocaleTag, const Locale('pt', 'PT').toLanguageTag());
    });
  });

  group('canonicalLocaleTag', () {
    test('passes a canonical tag through', () {
      expect(canonicalLocaleTag('en-GB'), 'en-GB');
      expect(canonicalLocaleTag('pt-PT'), 'pt-PT');
    });

    test('maps the legacy generic codes onto the shipped region', () {
      expect(canonicalLocaleTag('pt'), 'pt-PT');
      expect(canonicalLocaleTag('en'), 'en-GB');
    });

    test('tolerates separator, case and surrounding whitespace', () {
      expect(canonicalLocaleTag('pt_PT'), 'pt-PT');
      expect(canonicalLocaleTag('EN-gb'), 'en-GB');
      expect(canonicalLocaleTag('  pt  '), 'pt-PT');
    });

    test('maps another region of a supported language to the one we ship', () {
      expect(canonicalLocaleTag('pt-BR'), 'pt-PT');
      expect(canonicalLocaleTag('en-US'), 'en-GB');
    });

    test('is null for a language we do not ship, and for nothing at all', () {
      expect(canonicalLocaleTag('fr'), isNull);
      expect(canonicalLocaleTag('fr-FR'), isNull);
      expect(canonicalLocaleTag('xx'), isNull);
      expect(canonicalLocaleTag(''), isNull);
      expect(canonicalLocaleTag('   '), isNull);
      expect(canonicalLocaleTag(null), isNull);
    });
  });

  group('supportedLocaleFor', () {
    test('resolves to the Locale MaterialApp should run in', () {
      expect(supportedLocaleFor('pt'), const Locale('pt', 'PT'));
      expect(supportedLocaleFor('en-GB'), const Locale('en', 'GB'));
    });

    test('is null for an unshippable value, so the device locale wins', () {
      expect(supportedLocaleFor('fr'), isNull);
      expect(supportedLocaleFor(null), isNull);
    });
  });

  group('readProfileLocale', () {
    test('canonicalizes a legacy stored value at the app boundary', () {
      expect(readProfileLocale('pt'), 'pt-PT');
      expect(readProfileLocale('en'), 'en-GB');
    });

    test('defaults a missing or blank value', () {
      expect(readProfileLocale(null), kDefaultLocaleTag);
      expect(readProfileLocale(''), kDefaultLocaleTag);
      expect(readProfileLocale('   '), kDefaultLocaleTag);
    });

    test(
      'passes an unrecognised value through UNCHANGED rather than coercing it',
      () {
        // Deliberate: coercing `fr` to English here would hide the fact that
        // the app has no French. Left alone, localeProvider resolves it to
        // null and MaterialApp follows the device locale instead.
        expect(readProfileLocale('fr-FR'), 'fr-FR');
      },
    );
  });
}
