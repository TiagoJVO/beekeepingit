import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_form_screen.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/a11y_matchers.dart';

/// A deterministic fake for [DeviceLocationService] (CRITICAL finding — the
/// form's "use current location" button now goes through
/// `deviceLocationServiceProvider`, core/geo/device_location.dart, instead
/// of its own raw Geolocator calls), mirroring
/// apiaries_list_screen_test.dart's/apiary_map_screen_test.dart's own fakes.
class _FakeDeviceLocationService implements DeviceLocationService {
  const _FakeDeviceLocationService(this.result);
  final DeviceLocation result;

  @override
  Future<DeviceLocation> current() async => result;
}

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
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => const [];
  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}
  @override
  Future<void> clear() async {}
}

/// Records `create()` calls so the form's save-with-no-location path can be
/// asserted without a real PowerSync backend (the seam the suite's other
/// create tests can't reach). Overrides only what the form calls.
///
/// The `throwOn*` flags (HIGH finding) let a test drive a failing
/// create/update/delete/getById without a real backend — proving the form
/// now catches the error, resets `_busy`, and surfaces a toast instead of
/// hanging on an indefinite spinner or crashing with an unhandled exception.
class _FakeApiariesRepository extends ApiariesRepository {
  _FakeApiariesRepository({
    this.throwOnCreate = false,
    this.throwOnUpdate = false,
    this.throwOnDelete = false,
    this.throwOnGetById = false,
    this.existing,
  }) : super(_NoopLocalStore());

  final bool throwOnCreate;
  final bool throwOnUpdate;
  final bool throwOnDelete;
  final bool throwOnGetById;
  final Apiary? existing;

  final List<Apiary> created = [];
  bool updateCalled = false;
  bool deleteCalled = false;

  @override
  Future<Apiary?> getById(String id) async {
    if (throwOnGetById) throw Exception('boom-load');
    return existing;
  }

  @override
  Future<String> create({
    required String name,
    int? hiveCount,
    String? notes,
    String? placeLabel,
    double? locationLon,
    double? locationLat,
  }) async {
    if (throwOnCreate) throw Exception('boom-create');
    created.add(
      Apiary(
        id: 'fake-${created.length}',
        name: name,
        // The form no longer sets a counter (#346): create omits hiveCount,
        // so the created apiary starts with none (hive count reads 0).
        hiveCount: hiveCount ?? 0,
        notes: notes,
        placeLabel: placeLabel,
        locationLon: locationLon,
        locationLat: locationLat,
      ),
    );
    return 'fake-${created.length - 1}';
  }

  @override
  Future<void> update(
    String id, {
    String? name,
    int? hiveCount,
    String? notes,
    bool notesProvided = false,
    String? placeLabel,
    bool placeLabelProvided = false,
    double? locationLon,
    double? locationLat,
    bool locationProvided = false,
  }) async {
    updateCalled = true;
    if (throwOnUpdate) throw Exception('boom-update');
  }

  @override
  Future<void> delete(String id) async {
    deleteCalled = true;
    if (throwOnDelete) throw Exception('boom-delete');
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
  DeviceLocationService? locationService,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      // The detail screen (reached via the apiary-a1 -> edit-button chain
      // several tests below drive) watches apiaryByIdProvider (HIGH
      // finding), not the whole-org apiariesStreamProvider — overridden
      // here the same way apiary_detail_screen_test.dart already does, so
      // navigating into the detail screen resolves immediately instead of
      // hanging on the real (never-resolving in this environment)
      // apiariesRepositoryProvider chain.
      apiaryByIdProvider.overrideWith(
        (ref, apiaryId) => Stream.value(
          apiaries.cast<Apiary?>().firstWhere(
            (a) => a!.id == apiaryId,
            orElse: () => null,
          ),
        ),
      ),
      // The detail screen's activities section (#42) watches this
      // family provider per apiary id — overridden with an empty stream so
      // navigating into the detail screen doesn't hang on the real
      // (never-resolving here) activitiesRepositoryProvider chain and its
      // ActivityListView's loading spinner (which, unlike the counters
      // section, DOES render one, and its animation would make
      // pumpAndSettle time out).
      activitiesByApiaryProvider.overrideWith(
        (ref, apiaryId) => Stream.value(const <Activity>[]),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      // Hermetic member-name roster (#44) — see apiary_detail_screen_test.
      memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      // Only the "use current location" test passes this (CRITICAL
      // finding); every other test leaves it un-overridden, same as before.
      if (locationService != null)
        deviceLocationServiceProvider.overrideWithValue(locationService),
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
    'the create form has NO hive/counter field (#346, D-20: counters are '
    'managed on the detail screen, not set at creation)',
    (tester) async {
      await tester.pumpWidget(_buildApp(apiaries: const []));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();

      // The form is on-screen (its name field exists) but the old inline
      // hive field is gone entirely.
      expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
      expect(find.byKey(const Key('apiary-hive-field')), findsNothing);
      expect(find.text('Number of hives'), findsNothing);
    },
  );

  testWidgets(
    'saving a create form never sets a counter — create() is called without a '
    'hiveCount (#346)',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeApiariesRepository();
      await tester.pumpWidget(
        _buildApp(apiaries: const [], repositoryOverride: repo),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('apiary-name-field')),
        'Encosta Nova',
      );
      await tester.tap(find.byKey(const Key('apiary-save-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(repo.created, hasLength(1));
      // The fake records hiveCount ?? 0; the create form passes null, so the
      // recorded apiary reads 0 hives (no counter row would be written).
      expect(repo.created.single.hiveCount, 0);
    },
  );

  testWidgets(
    'the create form has a notes field that accepts free text (FR-AP-8, #196)',
    (tester) async {
      await tester.pumpWidget(_buildApp(apiaries: const []));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
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

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
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

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
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

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
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
      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
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

  group('"use current location" (CRITICAL finding: shared '
      'deviceLocationServiceProvider, not raw Geolocator)', () {
    testWidgets(
      'tapping "use current location" sets the pin from the overridden '
      'deviceLocationServiceProvider',
      (tester) async {
        // A tall viewport so "use current location" is on-screen without
        // scrolling — same rationale as the "save with no location" test
        // above (the default 800x600 test viewport puts it below the
        // fold once the map picker is expanded).
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _buildApp(
            apiaries: const [],
            locationService: const _FakeDeviceLocationService(
              DeviceLocationAvailable(lon: -8.6109, lat: 41.1496),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-toggle-map-button')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('apiary-use-current-location-button')),
        );
        await tester.pumpAndSettle();

        expect(find.text('Location set: 41.14960, -8.61090'), findsOneWidget);
      },
    );

    testWidgets(
      'a denied/unavailable location shows the permission-denied message, '
      'not a crash',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _buildApp(
            apiaries: const [],
            locationService: const _FakeDeviceLocationService(
              DeviceLocationPermissionDenied(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-toggle-map-button')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('apiary-use-current-location-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('apiary-location-permission-denied')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('error handling on create/update/delete/load (HIGH finding)', () {
    testWidgets(
      'a failing create() resets busy and shows an error toast instead of '
      'hanging on an indefinite spinner',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeApiariesRepository(throwOnCreate: true);
        await tester.pumpWidget(
          _buildApp(apiaries: const [], repositoryOverride: repo),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          'Encosta Nova',
        );
        await tester.tap(find.byKey(const Key('apiary-save-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        // Still on the form — a failed create must not navigate away.
        expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
        // Not stuck on an indefinite busy spinner.
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.textContaining('Could not save the apiary'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a failing update() (edit mode) resets busy and shows an error toast',
      (tester) async {
        // Tall viewport so Save is on-screen without scrolling.
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const existingApiary = Apiary(
          id: 'a1',
          name: 'Monte Alto',
          hiveCount: 4,
        );
        final repo = _FakeApiariesRepository(
          existing: existingApiary,
          throwOnUpdate: true,
        );
        await tester.pumpWidget(
          _buildApp(apiaries: const [existingApiary], repositoryOverride: repo),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-detail-edit-button')));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('apiary-save-button')), findsOneWidget);
        await tester.tap(find.byKey(const Key('apiary-save-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.textContaining('Could not save the apiary'),
          findsOneWidget,
        );
        expect(repo.updateCalled, isTrue);
      },
    );

    testWidgets('a failing delete() resets busy and shows an error toast', (
      tester,
    ) async {
      // Tall viewport so the delete button is on-screen without scrolling.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const existingApiary = Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4);
      final repo = _FakeApiariesRepository(
        existing: existingApiary,
        throwOnDelete: true,
      );
      await tester.pumpWidget(
        _buildApp(apiaries: const [existingApiary], repositoryOverride: repo),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apiary-detail-edit-button')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-delete-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apiary-delete-confirm-delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(
        find.textContaining('Could not delete the apiary'),
        findsOneWidget,
      );
      expect(repo.deleteCalled, isTrue);
    });

    testWidgets(
      'a failing initial load (edit mode) resets busy and shows an error '
      'instead of an indefinite spinner',
      (tester) async {
        final repo = _FakeApiariesRepository(throwOnGetById: true);
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4),
            ],
            repositoryOverride: repo,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-detail-edit-button')));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.textContaining('Could not load the apiary'),
          findsOneWidget,
        );
      },
    );
  });

  testWidgets(
    '_confirmDelete does not act on a disposed screen (MEDIUM finding: '
    'missing mounted check after await showDialog)',
    (tester) async {
      // A tall viewport so the delete button (below notes/location/save) is
      // on-screen without scrolling — same rationale as the other tall-
      // viewport tests in this file.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeApiariesRepository(
        existing: const Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4),
      );
      final showForm = ValueNotifier<bool>(true);
      addTearDown(showForm.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiariesRepositoryProvider.overrideWith((ref) async => repo),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ValueListenableBuilder<bool>(
              valueListenable: showForm,
              builder: (context, show, _) => Scaffold(
                body: show
                    ? const ApiaryFormScreen(apiaryId: 'a1')
                    : const Text('replaced'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-delete-button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('apiary-delete-confirm-dialog')),
        findsOneWidget,
      );

      // Simulate the form being torn down while its OWN confirm dialog is
      // still open above it (e.g. an auth/redirect elsewhere) — the dialog
      // route itself (pushed on the app's Navigator) stays open; only the
      // ApiaryFormScreen underneath is disposed.
      showForm.value = false;
      await tester.pump();

      // Resolve the dialog as if the user tapped confirm. Before the fix,
      // _confirmDelete would proceed straight into _delete(), which touches
      // AppLocalizations.of(context)/ScaffoldMessenger.of(context) on the
      // now-disposed State. The `if (!mounted) return;` guard must stop it.
      await tester.tap(find.byKey(const Key('apiary-delete-confirm-delete')));
      await tester.pumpAndSettle();

      expect(repo.deleteCalled, isFalse);
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
