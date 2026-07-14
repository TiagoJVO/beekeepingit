import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_form_screen.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/a11y_matchers.dart';

/// A no-op [LocalStoreEngine] — the superclass constructor requires one, but
/// [_FakeApiariesRepository] overrides every method the form touches, so it's
/// never actually called.
class _NoopLocalStore implements LocalStoreEngine {
  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) => const Stream.empty();
  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async => null;
  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}
  @override
  Future<void> clear() async {}
}

/// Records `create()` calls so the form's save-with-no-location path can be
/// asserted without a real PowerSync backend (the seam the suite's other
/// create tests can't reach). Overrides only what the form calls.
class _FakeApiariesRepository extends ApiariesRepository {
  _FakeApiariesRepository() : super(_NoopLocalStore());

  final List<Apiary> created = [];

  @override
  Future<String> create({
    required String name,
    required int hiveCount,
    String? notes,
    String? placeLabel,
    double? locationLon,
    double? locationLat,
  }) async {
    created.add(
      Apiary(
        id: 'fake-${created.length}',
        name: name,
        hiveCount: hiveCount,
        notes: notes,
        placeLabel: placeLabel,
        locationLon: locationLon,
        locationLat: locationLat,
      ),
    );
    return 'fake-${created.length - 1}';
  }
}

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
Widget _buildApp({
  required List<Apiary> apiaries,
  ApiariesRepository? repositoryOverride,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      // Only the "save with no location" test passes a fake here so the
      // create path can complete without a real PowerSync backend; every
      // other test leaves it un-overridden (matching the suite's existing
      // "the field exists / navigation succeeds" scope).
      if (repositoryOverride != null)
        apiariesRepositoryProvider.overrideWith(
          (ref) async => repositoryOverride,
        ),
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
    'the create form has a place label field; the map picker is collapsed by '
    'default with a "set on map" toggle (#252)',
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

      // The map picker is COLLAPSED by default, and so are its controls — the
      // always-on 220px map + buttons used to push the Save action off-screen
      // and collide with it in a constrained viewport (the regression the
      // walking-skeleton e2e caught). Only the compact "set on map" toggle +
      // the status text show until the user opts in; the map, "use current
      // location", and "clear" all appear on expand.
      expect(find.byKey(const Key('apiary-location-picker')), findsNothing);
      expect(find.byKey(const Key('apiary-toggle-map-button')), findsOneWidget);
      expect(find.byKey(const Key('apiary-location-status')), findsOneWidget);
      expect(
        find.byKey(const Key('apiary-use-current-location-button')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('apiary-clear-location-button')),
        findsNothing,
      );

      // Tapping "set on map" expands the embedded map picker (#252 AC:
      // "placing/dragging a pin on an embedded map picker") and reveals its
      // controls including "use current location".
      await tester.tap(find.byKey(const Key('apiary-toggle-map-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apiary-location-picker')), findsOneWidget);
      expect(
        find.byKey(const Key('apiary-use-current-location-button')),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a create form with only name + hives (no location) saves successfully — '
    'the exact seam the walking-skeleton e2e exercises (#252)',
    (tester) async {
      // Regression guard for the e2e failure: an always-embedded map picker
      // pushed Save below the fold / collided with the location controls, so
      // the create-with-only-name+hives flow (which never touches location)
      // broke. Drives the real save path with NO location set via a fake
      // repository (so it completes without a PowerSync backend — the seam
      // this suite's other create tests can't reach) and asserts create() was
      // called and the form navigated away.
      //
      // A tall viewport so the whole form fits without scrolling — this test
      // isolates the SAVE LOGIC (create-with-no-location succeeds), not the
      // layout/reachability of Save (which the collapse-by-default change and
      // the live e2e cover). With everything on-screen, tapping Save can't
      // miss.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeApiariesRepository();
      await tester.pumpWidget(
        _buildApp(apiaries: const [], repositoryOverride: repo),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('apiary-name-field')),
        'Encosta Nova',
      );
      // Hives already defaults to "0"; leave it. Never touch location.
      expect(
        find.byKey(const Key('apiary-location-picker')),
        findsNothing,
        reason: 'map picker must be collapsed by default so Save is reachable',
      );

      // Save by key — the primary action must work with no location set.
      // Bounded pumps (not pumpAndSettle): saving navigates to the list and
      // shows a SnackBar (a 4s timer), so the frame scheduler may not fully
      // idle promptly; the create call completes within these frames.
      await tester.tap(find.byKey(const Key('apiary-save-button')));
      await tester.pump(); // let _save() start (setState busy)
      await tester.pump(const Duration(milliseconds: 100)); // await create()
      await tester.pump(const Duration(milliseconds: 100)); // navigation frame

      // The repository was asked to create exactly one apiary with the typed
      // name, no location — the core guarantee this regression guard exists
      // for (create-with-only-name+hives must succeed).
      expect(repo.created, hasLength(1));
      expect(repo.created.single.name, 'Encosta Nova');
      expect(repo.created.single.locationLon, isNull);
      expect(repo.created.single.locationLat, isNull);
      // And it navigated away from the form (its Name field is gone).
      expect(find.byKey(const Key('apiary-name-field')), findsNothing);
    },
  );

  testWidgets(
    'expanding the map and tapping it sets a location, then it becomes '
    'clearable (#252 AC: editable and clearable)',
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

      // Expand the map first (collapsed by default now).
      await tester.tap(find.byKey(const Key('apiary-toggle-map-button')));
      await tester.pumpAndSettle();
      final picker = find.byKey(const Key('apiary-location-picker'));
      expect(picker, findsOneWidget);
      // Scroll the newly-expanded map fully into view before tapping — it
      // appears mid-form, so its center can sit below the test viewport's
      // fold, which would make tapAt(getCenter(...)) land off the map.
      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();

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
      await tester.tapAt(tester.getCenter(picker));
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
      // appearing shifted the form's layout, which can leave its previous
      // cached position outside the scroll view's visible bounds.
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
