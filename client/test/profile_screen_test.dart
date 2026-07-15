import 'dart:async';

import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_screen.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Profile _profile({
  String name = '',
  String email = '',
  String locale = 'en',
  bool complete = false,
}) {
  return Profile(
    id: 'u1',
    name: name,
    email: email,
    locale: locale,
    profileComplete: complete,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

/// A fake controller so tests drive [ProfileScreen] without a real
/// [ApiClient]/network call, matching widget_test.dart's
/// override-providers-not-network convention.
class _FakeProfileController extends ProfileController {
  _FakeProfileController(this._initial, {this.onUpdate});

  final Profile _initial;
  final Future<void> Function({String? name, String? email, String? locale})?
  onUpdate;

  @override
  Future<Profile> build() async => _initial;

  @override
  Future<void> submit({String? name, String? email, String? locale}) async {
    if (onUpdate != null) {
      await onUpdate!(name: name, email: email, locale: locale);
      return;
    }
    state = AsyncData(
      _profile(
        name: name ?? _initial.name,
        email: email ?? _initial.email,
        locale: locale ?? _initial.locale,
        complete:
            (name ?? _initial.name).isNotEmpty &&
            (email ?? _initial.email).isNotEmpty,
      ),
    );
  }
}

/// A controller whose [build] never resolves, so [ProfileScreen] is stuck on
/// `profileAsync`'s `loading` branch — used to verify the spinner actually
/// renders (previously unverified by any test, HIGH #3).
class _PendingProfileController extends ProfileController {
  @override
  Future<Profile> build() => Completer<Profile>().future;
}

/// A controller whose [build] throws, so [ProfileScreen] resolves to
/// `profileAsync`'s `error` branch — used to verify that branch surfaces a
/// fixed, localized message rather than the raw exception text (HIGH #2,
/// HIGH #3).
class _ErrorProfileController extends ProfileController {
  @override
  Future<Profile> build() async {
    throw StateError("type 'Null' is not a subtype of type 'String'");
  }
}

Widget _buildScreen(ProfileController controller) {
  return ProviderScope(
    overrides: [profileProvider.overrideWith(() => controller)],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ProfileScreen(),
    ),
  );
}

void main() {
  testWidgets('renders name/email fields with current profile state', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeProfileController(
          _profile(name: 'Ana', email: 'ana@example.com', complete: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('profile-name-field')), findsOneWidget);
    expect(find.byKey(const Key('profile-email-field')), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
    expect(find.text('ana@example.com'), findsOneWidget);
  });

  testWidgets('shows onboarding intro when profile is incomplete', (
    tester,
  ) async {
    await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
    await tester.pumpAndSettle();

    expect(
      find.text('Tell us a bit about yourself to get started.'),
      findsOneWidget,
    );
  });

  testWidgets('validates empty name and email client-side', (tester) async {
    await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('profile-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter your name.'), findsOneWidget);
    expect(find.text('Enter your email.'), findsOneWidget);
  });

  testWidgets('submits valid name+email and shows success', (tester) async {
    await tester.pumpWidget(_buildScreen(_FakeProfileController(_profile())));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('profile-name-field')),
      'Beatriz',
    );
    await tester.enterText(
      find.byKey(const Key('profile-email-field')),
      'bea@example.com',
    );
    await tester.tap(find.byKey(const Key('profile-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('Profile saved.'), findsOneWidget);
  });

  testWidgets('surfaces a mocked 422 field error from the server', (
    tester,
  ) async {
    final controller = _FakeProfileController(
      _profile(),
      onUpdate: ({name, email, locale}) async {
        throw const ApiException(
          statusCode: 422,
          code: 'validation.failed',
          detail: 'one or more fields are invalid',
          fieldErrors: [
            ApiFieldError(
              field: 'email',
              code: 'invalid',
              message: 'email must be a valid email address',
            ),
          ],
        );
      },
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('profile-name-field')),
      'Carlos',
    );
    await tester.enterText(
      find.byKey(const Key('profile-email-field')),
      'carlos@example.com',
    );
    await tester.tap(find.byKey(const Key('profile-save-button')));
    await tester.pumpAndSettle();

    expect(find.text('email must be a valid email address'), findsOneWidget);
  });

  testWidgets(
    'shows the loading spinner while the profile is still loading (HIGH #3)',
    (tester) async {
      await tester.pumpWidget(_buildScreen(_PendingProfileController()));
      // A single pump, not pumpAndSettle: the indeterminate spinner's
      // implicit animation never finishes, so pumpAndSettle would hang
      // forever (matches apiary_detail_screen_test.dart's own convention for
      // an intentionally-indefinite loading state).
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const Key('profile-name-field')), findsNothing);
    },
  );

  testWidgets('shows a fixed generic error, never the raw exception, when the '
      'profile fails to load (HIGH #2, HIGH #3)', (tester) async {
    await tester.pumpWidget(_buildScreen(_ErrorProfileController()));
    await tester.pumpAndSettle();

    expect(
      find.text('Something went wrong. Please try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('is not a subtype'), findsNothing);
    expect(find.textContaining('StateError'), findsNothing);
  });

  testWidgets(
    'shows a fixed generic error, never the raw exception, when save fails '
    'with something other than an ApiException (HIGH #2)',
    (tester) async {
      final controller = _FakeProfileController(
        _profile(),
        onUpdate: ({name, email, locale}) async {
          // A bug-shaped failure (e.g. a null-check/type error), not a
          // structured ApiException — the overly-broad `catch (e)` this
          // guards against would previously interpolate this verbatim into
          // the user-visible snackbar.
          throw Exception("type 'Null' is not a subtype of type 'String'");
        },
      );
      await tester.pumpWidget(_buildScreen(controller));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('profile-name-field')),
        'Carlos',
      );
      await tester.enterText(
        find.byKey(const Key('profile-email-field')),
        'carlos@example.com',
      );
      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pumpAndSettle();

      expect(
        find.text('Something went wrong. Please try again.'),
        findsOneWidget,
      );
      expect(find.textContaining('is not a subtype'), findsNothing);
    },
  );

  testWidgets(
    'surfaces both a rendered (name) and an unrendered (locale) field error '
    'from a single 422 (HIGH #1, HIGH #3)',
    (tester) async {
      final controller = _FakeProfileController(
        _profile(),
        onUpdate: ({name, email, locale}) async {
          throw const ApiException(
            statusCode: 422,
            code: 'validation.failed',
            detail: 'one or more fields are invalid',
            fieldErrors: [
              ApiFieldError(
                field: 'name',
                code: 'invalid',
                message: 'name must not be empty',
              ),
              ApiFieldError(
                field: 'locale',
                code: 'unsupported',
                message: 'locale must be "en" or "pt"',
              ),
            ],
          );
        },
      );
      await tester.pumpWidget(_buildScreen(controller));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('profile-name-field')),
        'Carlos',
      );
      await tester.enterText(
        find.byKey(const Key('profile-email-field')),
        'carlos@example.com',
      );
      await tester.tap(find.byKey(const Key('profile-save-button')));
      await tester.pumpAndSettle();

      // 'name' has a dedicated field, so its error renders as that field's
      // errorText.
      expect(find.text('name must not be empty'), findsOneWidget);
      // 'locale' has no dedicated errorText wiring on the dropdown — before
      // the fix this error was silently dropped entirely (the generic
      // snackbar was suppressed because `_fieldErrors` was non-empty). It
      // must still be visibly surfaced, via the snackbar.
      expect(
        find.text('Could not save your profile: locale must be "en" or "pt"'),
        findsOneWidget,
      );
    },
  );
}
