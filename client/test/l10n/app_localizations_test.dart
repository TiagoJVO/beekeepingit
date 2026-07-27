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
      final en = AppLocalizationsEn();
      expect(en.appTitle, 'BeekeepingIT');
      expect(en.loginButton, 'Sign in');
      expect(en.saveButton, 'Save');
      expect(en.hiveCountValue(0), 'No hives');
      expect(en.hiveCountValue(1), '1 hive');
      expect(en.hiveCountValue(5), '5 hives');
      expect(en.apiariesError('timeout'), 'Could not load apiaries: timeout');
    });

    test('Portuguese renders plain keys and the ICU plural for every case', () {
      final pt = AppLocalizationsPt();
      expect(pt.appTitle, 'BeekeepingIT');
      expect(pt.loginButton, 'Iniciar sessão');
      expect(pt.saveButton, 'Guardar');
      expect(pt.hiveCountValue(0), 'Sem colmeias');
      expect(pt.hiveCountValue(1), '1 colmeia');
      expect(pt.hiveCountValue(5), '5 colmeias');
      expect(
        pt.apiariesError('timeout'),
        'Não foi possível carregar os apiários: timeout',
      );
    });

    test(
      'the offline sync-error banner drops the "PowerSync" technical term in '
      'both locales (#426)',
      () {
        final en = AppLocalizationsEn();
        final pt = AppLocalizationsPt();
        expect(en.offlineBannerErrorMessage, isNot(contains('PowerSync')));
        expect(pt.offlineBannerErrorMessage, isNot(contains('PowerSync')));
        // Still a non-empty, human message (not blanked out).
        expect(en.offlineBannerErrorMessage, isNotEmpty);
        expect(pt.offlineBannerErrorMessage, isNotEmpty);
      },
    );

    test('lookupAppLocalizations resolves en and pt to the matching class', () {
      expect(
        lookupAppLocalizations(const Locale('en')),
        isA<AppLocalizationsEn>(),
      );
      expect(
        lookupAppLocalizations(const Locale('pt')),
        isA<AppLocalizationsPt>(),
      );
    });
  });

  group('AppLocalizations — supportedLocales/delegate wiring', () {
    test('supportedLocales lists exactly English and Portuguese', () {
      expect(AppLocalizations.supportedLocales, [
        const Locale('en'),
        const Locale('pt'),
      ]);
    });

    testWidgets('the widget tree resolves en and pt through Localizations.of', (
      tester,
    ) async {
      for (final locale in AppLocalizations.supportedLocales) {
        AppLocalizations? resolved;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) {
                resolved = AppLocalizations.of(context);
                return Text(resolved!.appTitle);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(resolved!.localeName, locale.languageCode);
        expect(find.text('BeekeepingIT'), findsOneWidget);
      }
    });

    testWidgets(
      'a plural string renders correctly for the =0, =1 and other ICU cases in both locales',
      (tester) async {
        Widget hostFor(Locale locale, int count) => MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
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
            supportedLocales: AppLocalizations.supportedLocales,
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

        expect(resolved!.localeName, 'en');
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
