import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_form_screen.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/a11y_matchers.dart';

/// Fixtures mirroring widget_test.dart's/app_shell_test.dart's own — kept
/// local rather than imported since those files' fixtures are file-private.
class _CompleteProfileController extends ProfileController {
  @override
  Future<Profile> build() async => Profile(
    id: 'test-user',
    name: 'Test User',
    email: 'test@example.com',
    locale: 'en',
    profileComplete: true,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _ExistingOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => Organization(
    id: 'test-org',
    name: 'Test Apiary Co.',
    address: '',
    createdBy: 'test-user',
    role: 'admin',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

/// Builds the full app (real router/shell included) as an authenticated,
/// onboarded user with a fixed local apiaries list. apiariesRepositoryProvider
/// itself (the one that actually reads/writes — powered by a real,
/// connecting PowerSync instance) is intentionally left un-overridden here,
/// matching every other widget test in this suite (app_shell_test.dart's FAB
/// test included): none of them drive the form's save/delete actions or
/// edit-mode pre-fill through to completion, because that provider chain
/// needs a real platform channel + network this test environment doesn't
/// have. These tests stop at "the field exists and accepts input" (create
/// mode) or "navigation succeeds" (edit mode) — the actual persistence of
/// `notes` is covered by apiaries_repository.dart's create/update methods (a
/// plain parameterized SQL statement, reviewed directly) and by the
/// server-side round-trip tests (services/apiaries/main_test.go's
/// TestApiariesRest_Notes_CreateAndUpdateRoundTrip /
/// TestApiariesSlice_Notes_SyncApplyRoundTrip).
Widget _buildApp({required List<Apiary> apiaries}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

void main() {
  testWidgets(
    'the create form has a notes field that accepts free text (FR-AP-8, #196)',
    (tester) async {
      await tester.pumpWidget(_buildApp(apiaries: const []));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('apiary-notes-field')), findsOneWidget);
      expect(find.text('Notes'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('apiary-name-field')),
        'Quinta das Flores',
      );
      await tester.enterText(
        find.byKey(const Key('apiary-notes-field')),
        'Flora, acessos, observações…',
      );
      await tester.pump();

      expect(find.text('Flora, acessos, observações…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the create form has a place label field and an embedded map-pin picker '
    '(#252)',
    (tester) async {
      await tester.pumpWidget(_buildApp(apiaries: const []));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      // Place label field accepts free text (#252 AC: optional free-text
      // place label).
      expect(find.byKey(const Key('apiary-place-label-field')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('apiary-place-label-field')),
        'Montargil',
      );
      await tester.pump();
      expect(find.text('Montargil'), findsOneWidget);

      // The embedded map-pin picker (#252 AC: "placing/dragging a pin on an
      // embedded map picker") renders, and the "use current location" /
      // status text affordances are present (#252 AC: use-current-location,
      // editable/clearable).
      expect(find.byKey(const Key('apiary-location-picker')), findsOneWidget);
      expect(
        find.byKey(const Key('apiary-use-current-location-button')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('apiary-location-status')), findsOneWidget);
      // No location set yet — the "clear location" action isn't shown (it
      // only appears once a location exists, mirroring the map screen's own
      // "only show what's actionable" convention).
      expect(
        find.byKey(const Key('apiary-clear-location-button')),
        findsNothing,
      );

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tapping the map-pin picker sets a location, and it becomes clearable '
    '(#252 AC: editable and clearable)',
    (tester) async {
      await tester.pumpWidget(_buildApp(apiaries: const []));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      // No location set initially.
      expect(
        find.byKey(const Key('apiary-clear-location-button')),
        findsNothing,
      );
      expect(
        find.text('No location set — tap the map to place a pin'),
        findsOneWidget,
      );

      // Tap the map to place a pin. flutter_map's internal tap gesture
      // recognizer debounces a plain tap behind a short internal timer (to
      // disambiguate it from the start of a double-tap-to-zoom) before
      // invoking MapOptions.onTap — a single pump() right after the tap
      // observes the pre-debounce state, so this waits past that window
      // (confirmed against flutter_map 8.3.1's
      // MapInteractiveViewerState._handleOnTapUp, whose FakeTimer fires at
      // ~250ms) rather than asserting immediately. This widget test doesn't
      // assert on the exact lon/lat the tap resolves to (that depends on
      // flutter_map's screen-to-geographic projection, which isn't this
      // screen's own logic to verify) — only that a location becomes set as
      // a result, which the repository/backend round-trip tests
      // (apiaries_repository_test.dart, main_test.go) cover precisely.
      await tester.tapAt(
        tester.getCenter(find.byKey(const Key('apiary-location-picker'))),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // The clear action now appears (a location exists to clear), and the
      // status text no longer reads "not set".
      expect(
        find.byKey(const Key('apiary-clear-location-button')),
        findsOneWidget,
      );
      expect(
        find.text('No location set — tap the map to place a pin'),
        findsNothing,
      );

      // Clearing removes it again. Scrolled into view first: the button
      // appearing shifted the form's layout (the row it's in only renders
      // once a location exists), which can leave its previous cached
      // position outside the scroll view's visible bounds.
      final clearButton = find.byKey(const Key('apiary-clear-location-button'));
      await tester.ensureVisible(clearButton);
      await tester.pumpAndSettle();
      await tester.tap(clearButton);
      await tester.pump();
      expect(
        find.byKey(const Key('apiary-clear-location-button')),
        findsNothing,
      );
      expect(
        find.text('No location set — tap the map to place a pin'),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'navigating to the edit form from the detail screen works without error',
    (tester) async {
      // apiary_form_screen.dart's edit mode (isEdit) always re-fetches the
      // apiary via the real apiariesRepositoryProvider in initState
      // (_loadExisting) rather than accepting the value the caller already
      // has — that provider is backed by a connecting PowerSyncDatabase this
      // widget-test environment can't stand up (no native sqlite extension,
      // no network), so this test — like every other edit-mode test in this
      // suite — stops at "navigation succeeds and the form is left in its
      // (indefinite) loading state without throwing", not asserting on
      // pre-filled field content. The actual pre-fill logic
      // (existing.notes ?? '' -> _notesController.text) is a two-line,
      // directly-reviewed assignment in apiary_form_screen.dart's
      // _loadExisting; the notes persistence it reads from is covered
      // server-side (main_test.go's
      // TestApiariesRest_Notes_CreateAndUpdateRoundTrip).
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [
            Apiary(
              id: 'a1',
              name: 'Monte Alto',
              hiveCount: 4,
              notes: 'Montado de sobro.',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apiary-detail-edit-button')));
      // Pump past the page-transition animation with a bounded duration
      // (not pumpAndSettle, which would wait forever on the busy spinner's
      // implicit animation below).
      await tester.pump(const Duration(milliseconds: 400));

      // findsWidgets, not findsOneWidget: "Edit apiary" is shared by the
      // shell header title and the outgoing detail screen's own FAB label
      // (apiary_detail_screen_test.dart has the full explanation, which also
      // covers this same navigation more thoroughly — including the
      // shell-back-button/apiary-name-field route-key assertions). This test
      // only additionally confirms the transition into edit-mode's
      // (indefinite, PowerSync-less) loading state doesn't throw.
      expect(find.text('Edit apiary'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  group('DeleteApiaryConfirmDialog (#255)', () {
    // Pumps just the dialog (via showDialog, matching how the real edit form
    // opens it) behind a minimal MaterialApp/l10n host — no repository/
    // PowerSync dependency, unlike the full ApiaryFormScreen's edit mode
    // (see this file's own doc comments above on why edit-mode tests can't
    // drive the form to completion). This is exactly what #255's AC asks to
    // be covered: "Widget tests cover both confirm and cancel paths" — the
    // dialog's own behavior, independent of the screen that opens it.
    Widget hostApp() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) =>
                      const DeleteApiaryConfirmDialog(apiaryName: 'Monte Alto'),
                );
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('result: $confirmed')));
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    testWidgets('names the apiary in the confirmation message (#255 AC)', (
      tester,
    ) async {
      await tester.pumpWidget(hostApp());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('apiary-delete-confirm-dialog')),
        findsOneWidget,
      );
      expect(find.text('Delete apiary?'), findsOneWidget);
      expect(
        find.text(
          'This permanently deletes “Monte Alto”. This cannot be undone.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('confirm pops true and dismisses the dialog', (tester) async {
      await tester.pumpWidget(hostApp());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-delete-confirm-delete')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('apiary-delete-confirm-dialog')),
        findsNothing,
      );
      expect(find.text('result: true'), findsOneWidget);
    });

    testWidgets(
      'cancel pops false, dismisses the dialog, and is a no-op (#255 AC)',
      (tester) async {
        await tester.pumpWidget(hostApp());
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-delete-confirm-cancel')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('apiary-delete-confirm-dialog')),
          findsNothing,
        );
        expect(find.text('result: false'), findsOneWidget);
      },
    );

    testWidgets(
      'dismissing via the barrier (tap outside) is treated the same as cancel',
      (tester) async {
        await tester.pumpWidget(hostApp());
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        // Tap the scrim well outside the dialog's content — a barrier
        // dismiss, not a button tap.
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('apiary-delete-confirm-dialog')),
          findsNothing,
        );
        expect(find.text('result: null'), findsOneWidget);
      },
    );

    testWidgets(
      'both actions meet the 44x44 minimum tap target size (D-18, gloves-friendly)',
      (tester) async {
        await tester.pumpWidget(hostApp());
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        expectMinTapTarget(
          tester,
          find.byKey(const Key('apiary-delete-confirm-cancel')),
        );
        expectMinTapTarget(
          tester,
          find.byKey(const Key('apiary-delete-confirm-delete')),
        );
      },
    );

    testWidgets('both actions have non-empty semantics labels (D-18)', (
      tester,
    ) async {
      await tester.pumpWidget(hostApp());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expectHasSemanticsLabel(
        tester,
        const Key('apiary-delete-confirm-cancel'),
      );
      expectHasSemanticsLabel(
        tester,
        const Key('apiary-delete-confirm-delete'),
      );
    });

    testWidgets('renders correctly in Portuguese (NFR-I18N-1)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('pt'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    builder: (_) => const DeleteApiaryConfirmDialog(
                      apiaryName: 'Monte Alto',
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Eliminar apiário?'), findsOneWidget);
      expect(
        find.text(
          'Isto elimina permanentemente “Monte Alto”. Esta ação não pode ser desfeita.',
        ),
        findsOneWidget,
      );
      expect(find.text('Cancelar'), findsOneWidget);
      expect(find.text('Eliminar'), findsOneWidget);
    });
  });
}
