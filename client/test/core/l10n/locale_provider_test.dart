import 'package:beekeepingit_client/core/l10n/locale_provider.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression coverage for #340 (NFR-I18N-1, FR-ST-1): choosing a preferred
/// language on the Account screen must actually re-localize the running app —
/// the stored profile `locale` has to drive `MaterialApp.locale` via
/// [localeProvider], not just sit in a preferences store.

Profile _profile({String locale = 'en'}) => Profile(
  id: 'u1',
  name: 'Ana',
  email: 'ana@example.com',
  locale: locale,
  profileComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

class _FakeProfileController extends ProfileController {
  _FakeProfileController(this._initial);

  final Profile _initial;

  @override
  Future<Profile> build() async => _initial;

  @override
  Future<void> submit({String? name, String? email, String? locale}) async {
    state = AsyncData(
      Profile(
        id: _initial.id,
        name: name ?? _initial.name,
        email: email ?? _initial.email,
        locale: locale ?? _initial.locale,
        profileComplete: _initial.profileComplete,
        createdAt: _initial.createdAt,
        updatedAt: _initial.updatedAt,
      ),
    );
  }
}

/// A minimal app that mirrors `app.dart`'s wiring: it feeds [localeProvider]
/// into `MaterialApp.locale` and renders a localized string so the test can
/// observe which locale the tree resolved to.
class _LocaleProbeApp extends ConsumerWidget {
  const _LocaleProbeApp();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp(
      locale: ref.watch(localeProvider),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Text(AppLocalizations.of(context).accountTitle),
      ),
    );
  }
}

void main() {
  testWidgets(
    'switching the stored profile locale re-localizes the running tree',
    (tester) async {
      final controller = _FakeProfileController(_profile(locale: 'en'));
      final container = ProviderContainer(
        overrides: [profileProvider.overrideWith(() => controller)],
      );
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const _LocaleProbeApp(),
        ),
      );
      await tester.pumpAndSettle();

      // English initially (the stored preference).
      expect(find.text('Account settings'), findsOneWidget);
      expect(find.text('Definições da conta'), findsNothing);

      // Change the preferred language — no restart, no re-pumpWidget.
      await container.read(profileProvider.notifier).submit(locale: 'pt');
      await tester.pumpAndSettle();

      // The tree is now Portuguese.
      expect(find.text('Definições da conta'), findsOneWidget);
      expect(find.text('Account settings'), findsNothing);
    },
  );

  test(
    'resolves a supported code to a Locale, else null (system fallback)',
    () async {
      Future<Locale?> resolve(String code) async {
        final container = ProviderContainer(
          overrides: [
            profileProvider.overrideWith(
              () => _FakeProfileController(_profile(locale: code)),
            ),
          ],
        );
        addTearDown(container.dispose);
        // Let the async profile build settle before reading the derived locale.
        await container.read(profileProvider.future);
        return container.read(localeProvider);
      }

      expect(await resolve('pt'), const Locale('pt'));
      expect(await resolve('en'), const Locale('en'));
      // Unset or unsupported → null so MaterialApp uses the device locale.
      expect(await resolve(''), isNull);
      expect(await resolve('xx'), isNull);
    },
  );
}
