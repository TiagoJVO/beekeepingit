import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_en.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations_pt.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../support/a11y_matchers.dart' show kDesktopViewport, useViewport;
import '../widget_test.dart' show FakeDeviceLocationService;

/// #638 (FR-UX-2, NFR-I18N-1) — **an unmatched location is a screen the app
/// wrote, not the framework's exception.**
///
/// The router declared no `errorBuilder` and no `onException`, so go_router's
/// own fallback rendered: the literal text
/// `GoException: no routes for location: /activities/new` above a single
/// "Home" link, in English whatever the user's language. And because that
/// fallback is built by the root navigator, the whole [AppShell] went with it
/// — no bottom navigation, no desktop rail, no sync pill, no account button.
/// A user arriving from a stale link (a bookmark, a shared URL, a route this
/// app used to have) was handed a stack trace fragment and one exit.
///
/// The fix routes the exception into a REAL route that lives inside the
/// shell's home branch, so the not-found screen is an ordinary page of the
/// app: every navigation affordance stays where it was, and the shell's own
/// back control pops it. The tests below pin all three halves of that —
/// the copy is the app's and is localized, the shell survives, and there is
/// more than one way out — plus the negative that started the issue: no
/// framework text reaches the user.
Profile _profileFixture({required String locale}) => Profile(
  id: 'u1',
  name: 'Ana',
  email: 'ana@example.com',
  locale: locale,
  profileComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

/// A fixed, COMPLETE profile so the router's onboarding gate lets the app
/// reach its landing screen without a real ApiClient/network call. The app's
/// UI locale is derived from the stored profile `locale` (`localeProvider`),
/// so this is also how the Portuguese run below drives the REAL wiring rather
/// than hand-building a `MaterialApp` that bypasses it (matches
/// `app_shell_test.dart`'s own `_PortugueseProfileController`).
class _FixedProfileController extends ProfileController {
  _FixedProfileController(this._locale);

  final String _locale;

  @override
  Future<Profile> build() async => _profileFixture(locale: _locale);
}

Organization _organizationFixture() => Organization(
  id: 'org-1',
  name: 'Dev Apiary Co.',
  address: '',
  registrationNumber: 'PT-111',
  createdBy: 'u1',
  role: 'admin',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

/// A fixed organization so the router's org-completion gate (#26) resolves and
/// stops redirecting to `/organization/new`.
class _FixedOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => _organizationFixture();
}

GoRouter _routerOf(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(Navigator).first));

String _locationOf(GoRouter router) =>
    router.routerDelegate.currentConfiguration.uri.toString();

Widget _buildApp({String locale = 'en'}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      deviceLocationServiceProvider.overrideWithValue(
        const FakeDeviceLocationService(),
      ),
      // Home is the landing screen (#658, D-35) and composes all four
      // org-scoped streams; the not-found screen lives in Home's own branch,
      // so Home renders under it either way. All four are stubbed to keep the
      // render hermetic.
      apiariesStreamProvider.overrideWith((ref) => Stream.value(const [])),
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      journeysStreamProvider.overrideWith(
        (ref) => Stream.value(const <Journey>[]),
      ),
      activitiesStreamProvider.overrideWith(
        (ref) => Stream.value(const <Activity>[]),
      ),
      profileProvider.overrideWith(() => _FixedProfileController(locale)),
      organizationProvider.overrideWith(_FixedOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

/// A location no route in `app_router.dart` matches. Deliberately NOT
/// `/activities/new` (the issue's own example) — #634 has since given that
/// path a real route, and a "not found" test that silently starts asserting
/// against a route that exists would pin nothing.
const _unmatchedLocation = '/definitely-not-a-route';

/// Fragments of go_router's own fallback screen. None of them may ever reach
/// the user (AC 1): they name the framework, leak the internal route table's
/// vocabulary, and are untranslated.
const _frameworkTextFragments = <String>[
  'GoException',
  'no routes for location',
  'Page Not Found',
];

/// Drives the app to [_unmatchedLocation] and returns the live router.
Future<GoRouter> _goToUnmatched(WidgetTester tester) async {
  final router = _routerOf(tester);
  router.go(_unmatchedLocation);
  await tester.pumpAndSettle();
  return router;
}

/// Records the `replace` flag of every `routeInformationUpdated` the framework
/// sends down [SystemChannels.navigation] from the moment it is installed.
///
/// That platform call IS the browser-history write on web (#841, D-10): the
/// engine's history manager pushes a new entry when `replace` is false and
/// overwrites the current one when it is true. Asserting on it is the only
/// way a VM widget test can pin history behaviour at all — there is no
/// `window.history` here to read, and the alternative (assert something else
/// and call it proven) would pin nothing.
List<bool> _recordHistoryWrites(WidgetTester tester) {
  final replaces = <bool>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.navigation, (call) async {
    if (call.method == 'routeInformationUpdated') {
      final arguments = call.arguments as Map<Object?, Object?>;
      replaces.add(arguments['replace']! as bool);
    }
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.navigation, null),
  );
  return replaces;
}

void main() {
  testWidgets('an unmatched location shows the app\'s own message, with no '
      'framework or exception text', (tester) async {
    await tester.pumpWidget(_buildApp());
    await tester.pumpAndSettle();

    await _goToUnmatched(tester);

    expect(
      find.text(AppLocalizationsEnGb().notFoundMessage),
      findsOneWidget,
      reason:
          'an unmatched location must render the app\'s own explanation '
          '(#638, FR-UX-2)',
    );

    for (final fragment in _frameworkTextFragments) {
      expect(
        find.textContaining(fragment),
        findsNothing,
        reason:
            'go_router\'s fallback text ("$fragment") is the framework '
            'talking to itself; the user must never see it (#638)',
      );
    }
  });

  // The screen's own doc comment claims composing EmptyState is what keeps it
  // laying out at the 200% text scale D-18 commits to. That claim is only
  // worth the test under it: the first draft of this screen hand-rolled
  // EmptyState's icon+message instead of composing it, which silently opted
  // out of #797's bounded/unbounded fix — and a RenderFlex overflow is a hard
  // error, so the assertion is simply that nothing threw while laying out.
  //
  // Runs at BOTH scales, and on a SHORT viewport: at 1.0 on a tall surface
  // the message fits with room to spare, so the case would pass without ever
  // exercising the overflow path it exists to pin.
  for (final textScale in const [1.0, 2.0]) {
    testWidgets('lays out inside the shell at ${textScale}x text, without '
        'overflowing (D-18, FR-AX-1, #797)', (tester) async {
      useViewport(tester, size: const Size(375, 500));
      tester.platformDispatcher.textScaleFactorTestValue = textScale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      await _goToUnmatched(tester);

      expect(
        tester.takeException(),
        isNull,
        reason:
            'the not-found screen overflowed at ${textScale}x inside the '
            'shell\'s bounded body — the failure #797 fixed for every other '
            'EmptyState',
      );
      // The shell is the point of the fix, so it must still be there at 200%
      // rather than the screen having escaped its bounded parent.
      expect(find.byKey(const Key('shell-bottom-nav')), findsOneWidget);
      expect(find.byKey(const Key('not-found-body')), findsOneWidget);
    });
  }

  group('the message is localized, not one hard-coded English string', () {
    // Both halves of NFR-I18N-1, split because only together do they mean
    // anything: the widget tests prove the screen reads its copy from the
    // ARB-generated lookup for the ACTIVE locale (a literal in the widget
    // would pass neither), and the last one proves the two locales are
    // genuinely different strings (a PT entry copy-pasted from EN would pass
    // both widget tests — and would be exactly the "reads the same in
    // Portuguese" defect #638 reports).
    for (final (locale, expected) in [
      ('en', AppLocalizationsEnGb()),
      ('pt', AppLocalizationsPtPt()),
    ]) {
      testWidgets('the app running in $locale renders the $locale copy', (
        tester,
      ) async {
        await tester.pumpWidget(_buildApp(locale: locale));
        await tester.pumpAndSettle();

        await _goToUnmatched(tester);

        expect(find.text(expected.notFoundMessage), findsOneWidget);
      });
    }

    test('the two locales do not share one string', () {
      expect(
        AppLocalizationsPtPt().notFoundMessage,
        isNot(AppLocalizationsEnGb().notFoundMessage),
        reason:
            'reading identically in both languages is exactly the '
            'untranslated framework string #638 reported (NFR-I18N-1)',
      );
      expect(
        AppLocalizationsPtPt().notFoundTitle,
        isNot(AppLocalizationsEnGb().notFoundTitle),
      );
      expect(
        AppLocalizationsPtPt().notFoundHomeAction,
        isNot(AppLocalizationsEnGb().notFoundHomeAction),
      );
    });
  });

  group('the app shell is retained', () {
    testWidgets('the bottom navigation stays on screen', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      await _goToUnmatched(tester);

      expect(
        find.byKey(const Key('shell-bottom-nav')),
        findsOneWidget,
        reason:
            'the user arrived from a stale link and must keep every primary '
            'area within one tap (#638 AC 2, FR-UX-2, D-35)',
      );
    });

    testWidgets('the desktop rail stays on screen at expanded widths', (
      tester,
    ) async {
      useViewport(tester, size: kDesktopViewport);
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      await _goToUnmatched(tester);

      expect(
        find.byKey(const Key('shell-nav-rail')),
        findsOneWidget,
        reason: 'the shell swaps chrome above 840 (#650) — both must survive',
      );
    });

    testWidgets('the sync pill and the account button stay on screen', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      await _goToUnmatched(tester);

      expect(find.byKey(const Key('shell-sync-pill')), findsOneWidget);
      expect(find.byKey(const Key('shell-account-button')), findsOneWidget);
    });
  });

  group('there is a way out', () {
    testWidgets('the shell\'s own back control returns to Home', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      final router = await _goToUnmatched(tester);

      final back = find.byKey(const Key('shell-back-button'));
      expect(
        back,
        findsOneWidget,
        reason:
            'the not-found page is pushed inside Home\'s branch, so the '
            'shell back control must be offered — and must actually pop '
            '(#639\'s rule: an affordance that does nothing is still a dead '
            'end)',
      );

      await tester.tap(back);
      await tester.pumpAndSettle();

      expect(_locationOf(router), '/home');
    });

    testWidgets('the screen\'s own action goes Home', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      final router = await _goToUnmatched(tester);

      await tester.tap(find.byKey(const Key('not-found-home-button')));
      await tester.pumpAndSettle();

      expect(
        _locationOf(router),
        '/home',
        reason:
            'the in-body action is the exit a user who never learned the '
            'header back control still finds (FR-UX-1, D-18)',
      );
    });
  });

  // #841 (FR-UX-2, D-10) — **the one exit that misbehaved.**
  //
  // #638 gave the unmatched location a real screen inside the shell, but
  // reached it with a plain `go()`, whose new configuration is reported to the
  // engine with push semantics. On web that stacks the not-found screen ON TOP
  // of the failed URL's own history entry, so browser (or Android system) Back
  // returns to the URL that failed, which re-fires `onException` and pushes
  // forward again — the user cannot step back past it to whatever referred
  // them.
  group('the failed URL is not left behind in browser history', () {
    testWidgets('landing on the not-found screen REPLACES the current history '
        'entry rather than pushing over it', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      // Installed only once the app has settled, so the writes recorded are
      // the ones the unmatched location itself causes.
      final historyWrites = _recordHistoryWrites(tester);

      final router = await _goToUnmatched(tester);

      expect(
        _locationOf(router),
        '/home/not-found',
        reason: 'the precondition: the unmatched location reached the screen',
      );
      expect(
        historyWrites,
        isNotEmpty,
        reason:
            'reaching the not-found screen must reach the engine at all — an '
            'empty list means this test has stopped observing the thing it '
            'exists to pin',
      );
      expect(
        historyWrites,
        everyElement(isTrue),
        reason:
            'every history write on the way to the not-found screen must '
            'replace, never push: a pushed entry leaves the URL that failed '
            'sitting behind it, and browser Back walks straight back into it '
            '(#841, FR-UX-2)',
      );
    });

    testWidgets('an ordinary navigation still PUSHES — the replace is scoped '
        'to the failure', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      final historyWrites = _recordHistoryWrites(tester);

      _routerOf(tester).go('/apiaries');
      await tester.pumpAndSettle();

      expect(historyWrites, isNotEmpty, reason: 'the same precondition');
      expect(
        historyWrites,
        everyElement(isFalse),
        reason:
            'the fix must not collapse the whole app into a single history '
            'entry — only the not-found hop replaces, or every ordinary Back '
            'in the app breaks instead (#841)',
      );
    });

    testWidgets('the shell back control still returns to Home after the '
        'replace', (tester) async {
      await tester.pumpWidget(_buildApp());
      await tester.pumpAndSettle();

      final router = await _goToUnmatched(tester);

      await tester.tap(find.byKey(const Key('shell-back-button')));
      await tester.pumpAndSettle();

      expect(
        _locationOf(router),
        '/home',
        reason:
            'replacing the HISTORY entry must not flatten the PAGE stack — '
            '#638 nested this route under /home precisely so Back pops '
            'somewhere real',
      );
    });
  });
}
