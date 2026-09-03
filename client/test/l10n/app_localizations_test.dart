import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_en.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_pt.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// i18n framework coverage (NFR-I18N-1, #77 AC):
///  - both EN and PT load and render a representative sample of keys,
///    including an ICU plural (already used by `hiveCountValue` etc.);
///  - a missing/unsupported locale falls back to English predictably,
///    rather than showing a lookup key or a blank string.
///
/// This intentionally exercises `AppLocalizations` end to end (delegate
/// lookup + generated per-locale classes), not just the two `AppLocalizationsEn`/
/// `AppLocalizationsPt` classes in isolation, since #77's AC is about the
/// framework as wired into the app (`MaterialApp.localizationsDelegates` +
/// `supportedLocales`), not just the ARB content (that's covered by #78's
/// CI gate — see taskfiles/dart.yml's `l10n-check` task).
void main() {
  group('AppLocalizations — direct per-locale instances', () {
    test('English renders plain keys and the ICU plural for every case', () {
      final en = AppLocalizationsEnGb();
      expect(en.appTitle, 'BeekeepingIT');
      expect(en.loginButton, 'Sign in');
      // #363 — the federated action's label is externalized, not a literal.
      expect(en.loginWithGoogleButton, 'Continue with Google');
      expect(en.saveButton, 'Save');
      expect(en.hiveCountValue(0), 'No hives');
      expect(en.hiveCountValue(1), '1 hive');
      expect(en.hiveCountValue(5), '5 hives');
      expect(en.apiariesError('timeout'), 'Could not load apiaries: timeout');
    });

    test('Portuguese renders plain keys and the ICU plural for every case', () {
      final pt = AppLocalizationsPtPt();
      expect(pt.appTitle, 'BeekeepingIT');
      expect(pt.loginButton, 'Iniciar sessão');
      expect(pt.loginWithGoogleButton, 'Continuar com a Google');
      expect(pt.saveButton, 'Guardar');
      expect(pt.hiveCountValue(0), 'Sem colmeias');
      expect(pt.hiveCountValue(1), '1 colmeia');
      expect(pt.hiveCountValue(5), '5 colmeias');
      expect(
        pt.apiariesError('timeout'),
        'Não foi possível carregar os apiários: timeout',
      );
    });

    // #624 (NFR-I18N-1, C-2): a counter plural embeds a number, and that
    // number was interpolated raw — `999999999 colmeias`, unreadable and
    // identical in both languages. The ARB placeholders now carry
    // `"format": "decimalPattern"`, so `intl` groups them for the active
    // locale.
    test('counter plurals group their number for the locale (#624)', () {
      final en = AppLocalizationsEnGb();
      final pt = AppLocalizationsPtPt();
      // #656/D-34: the region classes carry `localeName = 'en_GB'`/`'pt_PT'`,
      // which is exactly what `intl` reads for these ICU `decimalPattern`
      // placeholders — so European Portuguese groups with a NON-BREAKING
      // SPACE here, matching `LocaleFormatting.number`, instead of the
      // Brazilian full stop the generic `pt` class produced.
      expect(en.hiveCountValue(999999999), '999,999,999 hives');
      expect(pt.hiveCountValue(999999999), '999\u00A0999\u00A0999 colmeias');
      expect(pt.superCountValue(1234), contains('1\u00A0234'));
      expect(pt.emptyHiveCountValue(1234), contains('1\u00A0234'));
      expect(pt.swarmCountValue(1234), contains('1\u00A0234'));
      // Small counts keep reading exactly as before — no stray separator.
      expect(pt.hiveCountValue(5), '5 colmeias');
    });

    test(
      'the offline sync-error banner drops the "PowerSync" technical term in '
      'both locales (#426)',
      () {
        final en = AppLocalizationsEnGb();
        final pt = AppLocalizationsPtPt();
        expect(en.offlineBannerErrorMessage, isNot(contains('PowerSync')));
        expect(pt.offlineBannerErrorMessage, isNot(contains('PowerSync')));
        // Still a non-empty, human message (not blanked out).
        expect(en.offlineBannerErrorMessage, isNotEmpty);
        expect(pt.offlineBannerErrorMessage, isNotEmpty);
      },
    );

    test('lookupAppLocalizations resolves the shipped locales to the REGION '
        'class, which is what carries the pt_PT/en_GB formatting (#656)', () {
      for (final locale in kSupportedLocales) {
        expect(
          lookupAppLocalizations(locale).localeName,
          locale.toString(),
          reason: '$locale must not fall back to its base language',
        );
      }
      expect(
        lookupAppLocalizations(const Locale('en', 'GB')),
        isA<AppLocalizationsEnGb>(),
      );
      expect(
        lookupAppLocalizations(const Locale('pt', 'PT')),
        isA<AppLocalizationsPtPt>(),
      );
    });
  });

  group('AppLocalizations — supportedLocales/delegate wiring', () {
    test('the app offers exactly British English and European Portuguese, and '
        'no generic locale (D-34, #656)', () {
      expect(kSupportedLocales, [
        const Locale('en', 'GB'),
        const Locale('pt', 'PT'),
      ]);
      expect(kDefaultLocale, kSupportedLocales.first);
      expect(kDefaultLocaleTag, kDefaultLocale.toLanguageTag());
      expect(kPortugueseLocaleTag, const Locale('pt', 'PT').toLanguageTag());
    });

    test(
      'the GENERATED list is a superset — the base-language ARBs gen-l10n '
      'requires behind each region variant are loadable but never offered',
      () {
        // Documents, rather than hides, why app.dart passes kSupportedLocales
        // to MaterialApp instead of this list: offering `Locale('en')`/
        // `Locale('pt')` would let a pt-BR device resolve to Brazilian
        // conventions, which is exactly what #656 removes.
        expect(AppLocalizations.supportedLocales, [
          const Locale('en'),
          const Locale('en', 'GB'),
          const Locale('pt'),
          const Locale('pt', 'PT'),
        ]);
        for (final offered in kSupportedLocales) {
          expect(AppLocalizations.supportedLocales, contains(offered));
        }
      },
    );

    testWidgets(
      'the widget tree resolves each offered locale through Localizations.of, '
      'keeping its COUNTRY',
      (tester) async {
        for (final locale in kSupportedLocales) {
          AppLocalizations? resolved;
          await tester.pumpWidget(
            MaterialApp(
              locale: locale,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: kSupportedLocales,
              home: Builder(
                builder: (context) {
                  resolved = AppLocalizations.of(context);
                  return Text(resolved!.appTitle);
                },
              ),
            ),
          );
          await tester.pumpAndSettle();

          // `en_GB`/`pt_PT`, not `en`/`pt` — the localeName the generated
          // class hands to `intl` for its ICU number formats (#656).
          expect(resolved!.localeName, locale.toString());
          expect(find.text('BeekeepingIT'), findsOneWidget);
        }
      },
    );

    testWidgets(
      'a legacy generic locale still resolves to the country variant we ship '
      '(#656 migration)',
      (tester) async {
        for (final legacy in const [Locale('en'), Locale('pt')]) {
          AppLocalizations? resolved;
          await tester.pumpWidget(
            MaterialApp(
              locale: legacy,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: kSupportedLocales,
              home: Builder(
                builder: (context) {
                  resolved = AppLocalizations.of(context);
                  return Text(resolved!.appTitle);
                },
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(
            resolved!.localeName,
            legacy.languageCode == 'pt' ? 'pt_PT' : 'en_GB',
            reason:
                'a profile stored before #656 holds "$legacy" and must not '
                'land on Brazilian/American conventions',
          );
        }
      },
    );

    testWidgets(
      'a plural string renders correctly for the =0, =1 and other ICU cases in both locales',
      (tester) async {
        Widget hostFor(Locale locale, int count) => MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: kSupportedLocales,
          home: Builder(
            builder: (context) =>
                Text(AppLocalizations.of(context).hiveCountValue(count)),
          ),
        );

        await tester.pumpWidget(hostFor(const Locale('en'), 0));
        await tester.pumpAndSettle();
        expect(find.text('No hives'), findsOneWidget);

        await tester.pumpWidget(hostFor(const Locale('en'), 1));
        await tester.pumpAndSettle();
        expect(find.text('1 hive'), findsOneWidget);

        await tester.pumpWidget(hostFor(const Locale('en'), 3));
        await tester.pumpAndSettle();
        expect(find.text('3 hives'), findsOneWidget);

        await tester.pumpWidget(hostFor(const Locale('pt'), 0));
        await tester.pumpAndSettle();
        expect(find.text('Sem colmeias'), findsOneWidget);

        await tester.pumpWidget(hostFor(const Locale('pt'), 1));
        await tester.pumpAndSettle();
        expect(find.text('1 colmeia'), findsOneWidget);

        await tester.pumpWidget(hostFor(const Locale('pt'), 3));
        await tester.pumpAndSettle();
        expect(find.text('3 colmeias'), findsOneWidget);
      },
    );

    testWidgets(
      'an unsupported requested locale falls back to English (#77 AC: predictable EN fallback, not a key or blank)',
      (tester) async {
        AppLocalizations? resolved;

        await tester.pumpWidget(
          MaterialApp(
            // French isn't in supportedLocales — Flutter's default locale
            // resolution (no localeResolutionCallback override) falls back
            // to the first entry of supportedLocales, which is English.
            locale: const Locale('fr'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: kSupportedLocales,
            home: Builder(
              builder: (context) {
                resolved = AppLocalizations.of(context);
                return Column(
                  children: [
                    Text(resolved!.appTitle),
                    Text(resolved!.loginButton),
                    Text(resolved!.hiveCountValue(2)),
                  ],
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(resolved!.localeName, 'en_GB');
        expect(find.text('BeekeepingIT'), findsOneWidget);
        expect(find.text('Sign in'), findsOneWidget);
        expect(find.text('2 hives'), findsOneWidget);
        // Never a raw ICU/lookup key or blank text for a missing locale.
        expect(find.text('hiveCountValue'), findsNothing);
        expect(find.text(''), findsNothing);
      },
    );
  });
}
