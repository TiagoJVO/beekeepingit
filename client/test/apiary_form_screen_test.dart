import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_form_screen.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

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

  /// The registration-number override the last update() carried
  /// (FR-AP-9, #296) — null both when the form cleared it and when no update
  /// has run, which the assertions disambiguate via [updateCalled].
  String? updatedRegistrationNumber;
  bool deleteCalled = false;

  @override
  Future<Apiary?> getById(String id, {required String? organizationId}) async {
    if (throwOnGetById) throw Exception('boom-load');
    return existing;
  }

  @override
  Future<String> create({
    required String name,
    int? hiveCount,
    String? notes,
    String? placeLabel,
    String? registrationNumber,
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
        registrationNumber: registrationNumber,
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
    String? registrationNumber,
    bool registrationNumberProvided = false,
    double? locationLon,
    double? locationLat,
    bool locationProvided = false,
  }) async {
    updateCalled = true;
    updatedRegistrationNumber = registrationNumber;
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
      // Tasks is the app's landing screen now (#427, D-29) — stub its stream
      // so booting the app renders the Todos tab without hanging on the real,
      // never-resolving todos repository chain.
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
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

/// Sets a location on the open apiary form by expanding the map picker and
/// tapping "use current location" (resolved via the overridden
/// [DeviceLocationService]). Location is mandatory (#341), so create tests
/// must set one before saving.
Future<void> _setLocationViaCurrentLocation(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('apiary-toggle-map-button')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('apiary-use-current-location-button')));
  await tester.pumpAndSettle();
}

void main() {
  _registrationNumberFormTests();
  group('the primary actions stay reachable with the map picker expanded '
      '(FR-UX-1, D-18, #341 regression)', () {
    // The defect this guards: #341 made location mandatory, so every apiary
    // creation has to expand the 220px map picker — and back when Save was
    // the last child of the form's scroll view, that pushed it below the
    // fold on a short viewport, behind a map whose gesture region swallows
    // the drag that would scroll it back. CI reproduced exactly this: a
    // fully valid form (name + notes + "Location set: …"), Save clicked,
    // silent no-op, still parked on "New apiary". Save now lives in a pinned
    // action bar OUTSIDE the scroll view, so these tests deliberately never
    // scroll it into view before tapping it — `ensureVisible` is used only
    // for the in-form location controls, which legitimately scroll.
    const shortViewport = Size(400, 640);

    testWidgets(
      'Save is on-screen and actually saves while the picker is expanded, at '
      'a short viewport and scrolled to the bottom of the form',
      (tester) async {
        tester.view.physicalSize = shortViewport;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeApiariesRepository();
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [],
            repositoryOverride: repo,
            locationService: const _FakeDeviceLocationService(
              DeviceLocationAvailable(lon: -8.0, lat: 39.5),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
        // tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          'Encosta Nova',
        );
        await tester.pump();

        // Expand the picker and set a location — exactly what a real
        // creation now has to do. Both controls live inside the scroll view,
        // so they're scrolled into view first; that also leaves the form
        // scrolled away from the top, which is the state Save has to survive.
        final toggle = find.byKey(const Key('apiary-toggle-map-button'));
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();

        final useCurrent = find.byKey(
          const Key('apiary-use-current-location-button'),
        );
        await tester.ensureVisible(useCurrent);
        await tester.pumpAndSettle();
        await tester.tap(useCurrent);
        await tester.pumpAndSettle();

        // The picker is expanded and the location is set — the exact state
        // that used to strand the user.
        expect(find.byKey(const Key('apiary-location-picker')), findsOneWidget);
        expect(find.text('Location set: 39.50000, -8.00000'), findsOneWidget);

        // Save is fully inside the viewport…
        final save = find.byKey(const Key('apiary-save-button'));
        final saveRect = tester.getRect(save);
        final screen = Offset.zero & tester.view.physicalSize;
        expect(
          screen.contains(saveRect.topLeft) &&
              screen.contains(saveRect.bottomRight - const Offset(1, 1)),
          isTrue,
          reason:
              'Save must be fully on-screen with the map picker expanded; '
              'it rendered at $saveRect on a $shortViewport viewport',
        );
        // …still a gloves-friendly target (D-18)…
        expectMinTapTarget(tester, save);
        // …and a tap at its rendered position really reaches the handler —
        // NO ensureVisible/scrolling first, which is the whole point.
        await tester.tap(save);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(
          repo.created,
          hasLength(1),
          reason:
              'tapping Save with the picker expanded must create the '
              'apiary, not silently no-op',
        );
        expect(repo.created.single.locationLat, 39.5);
        expect(repo.created.single.locationLon, -8.0);
        // And it left the form.
        expect(find.byKey(const Key('apiary-name-field')), findsNothing);
      },
    );

    testWidgets(
      'the pinned Save keeps its semantics label and the location-required '
      'error still surfaces from it',
      (tester) async {
        tester.view.physicalSize = shortViewport;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeApiariesRepository();
        await tester.pumpWidget(
          _buildApp(apiaries: const [], repositoryOverride: repo),
        );
        await tester.pumpAndSettle();
        // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
        // tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          'Encosta Nova',
        );
        final toggle = find.byKey(const Key('apiary-toggle-map-button'));
        await tester.ensureVisible(toggle);
        await tester.pumpAndSettle();
        await tester.tap(toggle);
        await tester.pumpAndSettle();

        expectHasSemanticsLabel(tester, const Key('apiary-save-button'));

        // Saving with the picker expanded but no pin still surfaces the
        // mandatory-location error (#341) rather than doing nothing.
        await tester.tap(find.byKey(const Key('apiary-save-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        final error = find.byKey(const Key('apiary-location-required-error'));
        await tester.ensureVisible(error);
        await tester.pumpAndSettle();
        expect(error, findsOneWidget);
        expect(repo.created, isEmpty);
      },
    );
  });

  testWidgets(
    'the create form has NO hive/counter field (#346, D-20: counters are '
    'managed on the detail screen, not set at creation)',
    (tester) async {
      await tester.pumpWidget(_buildApp(apiaries: const []));
      await tester.pumpAndSettle();
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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
        _buildApp(
          apiaries: const [],
          repositoryOverride: repo,
          // Location is mandatory now (#341) — set one via "use current
          // location" so the create form passes validation and reaches save.
          locationService: const _FakeDeviceLocationService(
            DeviceLocationAvailable(lon: -8.6109, lat: 41.1496),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('apiary-name-field')),
        'Encosta Nova',
      );
      await _setLocationViaCurrentLocation(tester);
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
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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
    'saving without a location shows the required error and does NOT create '
    '(#341, FR-AP-7 — location is mandatory)',
    (tester) async {
      // Replaces the pre-#341 "create with no location succeeds" test:
      // location is now mandatory, so a save attempt with only a name must be
      // blocked with a validation error and must not call create().
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeApiariesRepository();
      await tester.pumpWidget(
        _buildApp(apiaries: const [], repositoryOverride: repo),
      );
      await tester.pumpAndSettle();
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('apiary-name-field')),
        'Encosta Nova',
      );
      // Map picker still collapsed by default (the #252 layout guarantee) —
      // Save stays reachable; the location is simply not set.
      expect(
        find.byKey(const Key('apiary-location-picker')),
        findsNothing,
        reason: 'map picker must be collapsed by default so Save is reachable',
      );

      await tester.tap(find.byKey(const Key('apiary-save-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // The required-location error is shown, nothing was created, and we
      // stayed on the form.
      expect(
        find.byKey(const Key('apiary-location-required-error')),
        findsOneWidget,
      );
      expect(repo.created, isEmpty);
      expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
    },
  );

  testWidgets(
    'a create form with a location set saves successfully (#341); the map '
    'picker is still collapsed by default (#252 layout)',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeApiariesRepository();
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [],
          repositoryOverride: repo,
          locationService: const _FakeDeviceLocationService(
            DeviceLocationAvailable(lon: -8.6109, lat: 41.1496),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
      await tester.pumpAndSettle();

      // The Apiaries tab now exposes an expandable Actions speed dial (#347),
      // so open it first, then tap the primary "New apiary" action.
      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('apiary-name-field')),
        'Encosta Nova',
      );
      // Collapsed by default — the location controls only appear on expand.
      expect(
        find.byKey(const Key('apiary-location-picker')),
        findsNothing,
        reason: 'map picker must be collapsed by default so Save is reachable',
      );
      await _setLocationViaCurrentLocation(tester);

      // Save by key. Bounded pumps (not pumpAndSettle): saving navigates to
      // the list and shows a SnackBar (a 4s timer).
      await tester.tap(find.byKey(const Key('apiary-save-button')));
      await tester.pump(); // let _save() start (setState busy)
      await tester.pump(const Duration(milliseconds: 100)); // await create()
      await tester.pump(const Duration(milliseconds: 100)); // navigation frame

      // Exactly one apiary created, carrying the location that was set.
      expect(repo.created, hasLength(1));
      expect(repo.created.single.name, 'Encosta Nova');
      expect(repo.created.single.locationLon, -8.6109);
      expect(repo.created.single.locationLat, 41.1496);
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
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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
    testWidgets('tapping "use current location" sets the pin from the overridden '
        'deviceLocationServiceProvider', (tester) async {
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
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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
    });

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
        // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
        // tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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

  group('map-picker recenter (#420)', () {
    testWidgets('the recenter control appears only once a pin is set, and is '
        'gloves-friendly with a semantics label', (tester) async {
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
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apiary-toggle-map-button')));
      await tester.pumpAndSettle();

      // No pin yet: nothing to recenter on, so no control.
      expect(
        find.byKey(const Key('apiary-location-picker-recenter-button')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const Key('apiary-use-current-location-button')),
      );
      await tester.pumpAndSettle();

      final recenter = find.byKey(
        const Key('apiary-location-picker-recenter-button'),
      );
      expect(recenter, findsOneWidget);
      expectMinTapTarget(tester, recenter);
      expectHasSemanticsLabel(
        tester,
        const Key('apiary-location-picker-recenter-button'),
      );
    });

    testWidgets(
      '"use current location" recenters the picker camera onto the fix at '
      'street zoom',
      (tester) async {
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
        // The app now lands on the Tasks tab (#427, D-29); switch to the
        // Apiaries tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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

        // The picker's own MapController — asserting its camera proves the
        // fetch drove a live move(point, streetZoom), not just that the pin
        // status text updated.
        final controller = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        expect(controller.camera.zoom, 16.0);
        expect(controller.camera.center.latitude, closeTo(41.1496, 0.0001));
        expect(controller.camera.center.longitude, closeTo(-8.6109, 0.0001));
      },
    );

    testWidgets(
      'tapping the recenter control moves the camera back onto the pin at '
      'street zoom',
      (tester) async {
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
        // The app now lands on the Tasks tab (#427, D-29); switch to the
        // Apiaries tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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

        final controller = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        // Pan the camera away and zoom out, simulating the user browsing the
        // map after the pin was placed.
        controller.move(const LatLng(0, 0), 3);
        await tester.pumpAndSettle();
        expect(controller.camera.zoom, 3);

        await tester.tap(
          find.byKey(const Key('apiary-location-picker-recenter-button')),
        );
        await tester.pumpAndSettle();

        expect(controller.camera.zoom, 16.0);
        expect(controller.camera.center.latitude, closeTo(41.1496, 0.0001));
        expect(controller.camera.center.longitude, closeTo(-8.6109, 0.0001));
      },
    );
  });

  group('full-screen map picker (#421)', () {
    testWidgets(
      'the embedded picker exposes a gloves-friendly maximize control with a '
      'semantics label, even before a pin is set',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(_buildApp(apiaries: const []));
        await tester.pumpAndSettle();
        // The app now lands on the Tasks tab (#427, D-29); switch to the
        // Apiaries tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-toggle-map-button')));
        await tester.pumpAndSettle();

        // No pin yet, but the maximize control is visible regardless — the
        // full-screen view is where a first pin can be placed too.
        final maximize = find.byKey(
          const Key('apiary-location-picker-maximize-button'),
        );
        expect(maximize, findsOneWidget);
        expectMinTapTarget(tester, maximize);
        expectHasSemanticsLabel(
          tester,
          const Key('apiary-location-picker-maximize-button'),
        );
      },
    );

    testWidgets(
      'tapping maximize opens the full-screen picker; confirming a tapped '
      'location returns it and the form persists it',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(_buildApp(apiaries: const []));
        await tester.pumpAndSettle();
        // The app now lands on the Tasks tab (#427, D-29); switch to the
        // Apiaries tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-toggle-map-button')));
        await tester.pumpAndSettle();

        // No location yet on the form.
        expect(
          find.text('No location set — tap the map to place a pin'),
          findsOneWidget,
        );

        // Open the full-screen picker.
        await tester.tap(
          find.byKey(const Key('apiary-location-picker-maximize-button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('apiary-fullscreen-picker')),
          findsOneWidget,
        );

        // Confirm is disabled while there's no pin to return.
        final confirmButton = tester.widget<IconButton>(
          find.byKey(const Key('apiary-fullscreen-picker-confirm')),
        );
        expect(confirmButton.onPressed, isNull);

        // Tap the full-screen map to place a pin (flutter_map debounces a tap
        // behind a ~250ms timer before firing MapOptions.onTap — wait past it,
        // matching the embedded-picker tap test above). The exact projected
        // lon/lat isn't asserted (that's flutter_map's projection, not this
        // screen's logic) — only that a location becomes set and round-trips
        // back to the form.
        final fullScreenMap = find.byKey(
          const Key('apiary-fullscreen-picker-map'),
        );
        await tester.tapAt(tester.getCenter(fullScreenMap));
        await tester.pump(const Duration(milliseconds: 300));

        // The pin now renders and the recenter control appears.
        expect(
          find.byKey(const Key('apiary-fullscreen-picker-pin')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('apiary-fullscreen-picker-recenter-button')),
          findsOneWidget,
        );

        // Confirm returns the chosen location to the form.
        await tester.tap(
          find.byKey(const Key('apiary-fullscreen-picker-confirm')),
        );
        await tester.pumpAndSettle();

        // Back on the form, and the location is now set (persisted in state):
        // the status text flipped off "not set" and the clear action appeared.
        expect(find.byKey(const Key('apiary-fullscreen-picker')), findsNothing);
        expect(
          find.text('No location set — tap the map to place a pin'),
          findsNothing,
        );
        expect(
          find.byKey(const Key('apiary-clear-location-button')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'the full-screen picker seeds from the form pin and cancel discards any '
      'change (the form keeps its original location)',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(
          _buildApp(
            apiaries: const [],
            // Set an initial pin via "use current location" so the picker has
            // something to seed from and the form has a location to keep.
            locationService: const _FakeDeviceLocationService(
              DeviceLocationAvailable(lon: -8.6109, lat: 41.1496),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // The app now lands on the Tasks tab (#427, D-29); switch to the
        // Apiaries tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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

        // Open the full-screen picker — it seeds from the form's pin, so its
        // pin + recenter control are present immediately.
        await tester.tap(
          find.byKey(const Key('apiary-location-picker-maximize-button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('apiary-fullscreen-picker-pin')),
          findsOneWidget,
        );

        // Move the pin elsewhere, then CANCEL — the change must be discarded.
        await tester.tapAt(
          tester.getCenter(
            find.byKey(const Key('apiary-fullscreen-picker-map')),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(
          find.byKey(const Key('apiary-fullscreen-picker-cancel')),
        );
        await tester.pumpAndSettle();

        // Back on the form with the ORIGINAL location intact.
        expect(find.byKey(const Key('apiary-fullscreen-picker')), findsNothing);
        expect(find.text('Location set: 41.14960, -8.61090'), findsOneWidget);
      },
    );

    testWidgets(
      'the full-screen picker "use current location" sets the pin from the '
      'overridden device-location service',
      (tester) async {
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
        // The app now lands on the Tasks tab (#427, D-29); switch to the
        // Apiaries tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-toggle-map-button')));
        await tester.pumpAndSettle();

        // Open the full-screen picker with no pin yet.
        await tester.tap(
          find.byKey(const Key('apiary-location-picker-maximize-button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('apiary-fullscreen-picker-pin')),
          findsNothing,
        );

        // "Use current location" fetches from the fake and drops the pin,
        // moving the camera onto it at street zoom.
        await tester.tap(
          find.byKey(
            const Key('apiary-fullscreen-picker-use-current-location'),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('apiary-fullscreen-picker-pin')),
          findsOneWidget,
        );
        final controller = tester
            .widget<FlutterMap>(
              find.byKey(const Key('apiary-fullscreen-picker-map')),
            )
            .mapController!;
        expect(controller.camera.zoom, 16.0);
        expect(controller.camera.center.latitude, closeTo(41.1496, 0.0001));
        expect(controller.camera.center.longitude, closeTo(-8.6109, 0.0001));

        // Confirm carries it back to the form.
        await tester.tap(
          find.byKey(const Key('apiary-fullscreen-picker-confirm')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Location set: 41.14960, -8.61090'), findsOneWidget);
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
          _buildApp(
            apiaries: const [],
            repositoryOverride: repo,
            // Location is mandatory (#341) — set one so save reaches create().
            locationService: const _FakeDeviceLocationService(
              DeviceLocationAvailable(lon: -8.6109, lat: 41.1496),
            ),
          ),
        );
        await tester.pumpAndSettle();
        // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
        // tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          'Encosta Nova',
        );
        await _setLocationViaCurrentLocation(tester);
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
          // Has a location so edit-mode save passes the mandatory-location
          // check (#341) and reaches update().
          locationLon: -8.6109,
          locationLat: 41.1496,
        );
        final repo = _FakeApiariesRepository(
          existing: existingApiary,
          throwOnUpdate: true,
        );
        await tester.pumpWidget(
          _buildApp(apiaries: const [existingApiary], repositoryOverride: repo),
        );
        await tester.pumpAndSettle();
        // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
        // tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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
      // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
      // tab before interacting with the apiaries list.
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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
        // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
        // tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
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
            // The edit prefill is org-scoped (#658, FR-TEN-2), so it awaits
            // organizationProvider — left un-overridden it never resolves
            // (its logged-out gate) and the form would sit on its spinner.
            organizationProvider.overrideWith(
              _ExistingOrganizationController.new,
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: kSupportedLocales,
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
      supportedLocales: kSupportedLocales,
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
          supportedLocales: kSupportedLocales,
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

/// FR-AP-9 (#296): the apiary form carries the per-apiary
/// registration-number OVERRIDE. The organization-wide default it overrides is
/// edited elsewhere (the organization-details screen under Account) — this
/// deals with the override, which is why the field is last and hinted as
/// "only if different from the organization's".
void _registrationNumberFormTests() {
  group('apiary form registration number (FR-AP-9, #296)', () {
    testWidgets('the create form offers an optional registration number field', (
      tester,
    ) async {
      await tester.pumpWidget(_buildApp(apiaries: const []));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();

      final field = find.byKey(const Key('apiary-registration-number-field'));
      // No scrollUntilVisible: the form is a SingleChildScrollView, so every
      // field is built regardless of scroll offset, and enterText/controller
      // reads do not need the widget on screen. (scrollUntilVisible would also
      // fail here — the app shell has several Scrollables, so its default
      // find.byType(Scrollable) matches more than one.)
      expect(field, findsOneWidget);

      await tester.enterText(field, 'PT-654321');
      await tester.pump();
      expect(find.text('PT-654321'), findsOneWidget);
    });

    testWidgets(
      'edit mode pre-fills the existing override so a save that does not touch '
      'it cannot silently clear it',
      (tester) async {
        // Tall viewport so Save is on-screen without scrolling, and the
        // fixture carries a location — edit-mode save enforces the mandatory
        // location (#341) before it ever reaches update().
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeApiariesRepository(
          existing: const Apiary(
            id: 'a1',
            name: 'Monte Alto',
            hiveCount: 4,
            registrationNumber: 'PT-654321',
            locationLon: -8.6109,
            locationLat: 41.1496,
          ),
        );
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(
                id: 'a1',
                name: 'Monte Alto',
                hiveCount: 4,
                registrationNumber: 'PT-654321',
                locationLon: -8.6109,
                locationLat: 41.1496,
              ),
            ],
            repositoryOverride: repo,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-detail-edit-button')));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        final field = find.byKey(const Key('apiary-registration-number-field'));
        expect(
          tester
              .widget<TextField>(
                find.descendant(of: field, matching: find.byType(TextField)),
              )
              .controller
              ?.text,
          'PT-654321',
        );

        await tester.tap(find.byKey(const Key('apiary-save-button')));
        await tester.pumpAndSettle();

        expect(repo.updateCalled, isTrue);
        expect(repo.updatedRegistrationNumber, 'PT-654321');
      },
    );

    testWidgets(
      'clearing the field clears the override, so the apiary falls back to the '
      "organization's number",
      (tester) async {
        // Tall viewport so Save is on-screen without scrolling, and the
        // fixture carries a location — edit-mode save enforces the mandatory
        // location (#341) before it ever reaches update().
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeApiariesRepository(
          existing: const Apiary(
            id: 'a1',
            name: 'Monte Alto',
            hiveCount: 4,
            registrationNumber: 'PT-654321',
            locationLon: -8.6109,
            locationLat: 41.1496,
          ),
        );
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(
                id: 'a1',
                name: 'Monte Alto',
                hiveCount: 4,
                registrationNumber: 'PT-654321',
                locationLon: -8.6109,
                locationLat: 41.1496,
              ),
            ],
            repositoryOverride: repo,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-detail-edit-button')));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        final field = find.byKey(const Key('apiary-registration-number-field'));
        await tester.enterText(field, '');
        await tester.pump();

        await tester.tap(find.byKey(const Key('apiary-save-button')));
        await tester.pumpAndSettle();

        expect(repo.updateCalled, isTrue);
        expect(repo.updatedRegistrationNumber, isNull);
      },
    );
  });

  /// Save-time validation parity (#597, FR-OF-2, D-12, sync.md §9): the same
  /// evaluator and the same shared description the pre-push check runs, moved
  /// to the moment the beekeeper presses Save — so a rule the server would
  /// break on is reported **in this form, with the apiary still open**,
  /// instead of as a needs-fix card after the next push.
  group('save-time validation parity (#597)', () {
    /// A name that fits the field but not the server: 150 'ç' are 150
    /// characters and 300 UTF-8 bytes, over `apiary.name`'s 200-**byte** cap.
    /// Nothing in the form could catch this before — `maxLength` counts
    /// characters, and the server counts Go's `len()` on a UTF-8 string.
    final overlongName = 'ç' * 150;

    Future<void> openNewApiaryForm(
      WidgetTester tester,
      _FakeApiariesRepository repo,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _buildApp(
          apiaries: const [],
          repositoryOverride: repo,
          locationService: const _FakeDeviceLocationService(
            DeviceLocationAvailable(lon: -8.6109, lat: 41.1496),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-fab-new-apiary')));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'a name the server would reject is caught in the form, not at the next '
      'push — the apiary is never created',
      (tester) async {
        final repo = _FakeApiariesRepository();
        await openNewApiaryForm(tester, repo);
        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          overlongName,
        );
        await _setLocationViaCurrentLocation(tester);
        await tester.tap(find.byKey(const Key('apiary-save-button')));
        await tester.pumpAndSettle();

        // Never written: the beekeeper still has the record in front of them.
        expect(repo.created, isEmpty);
        // …and is told which field is wrong, in app-owned localized copy —
        // #443's mapping reused, never the description's English `message`
        // and never the `name` column.
        expect(find.text('Name: this text is too long.'), findsOneWidget);
      },
    );

    testWidgets('the failure is announced, not signalled by colour alone', (
      tester,
    ) async {
      final repo = _FakeApiariesRepository();
      await openNewApiaryForm(tester, repo);
      await tester.enterText(
        find.byKey(const Key('apiary-name-field')),
        overlongName,
      );
      await _setLocationViaCurrentLocation(tester);
      await tester.tap(find.byKey(const Key('apiary-save-button')));
      await tester.pumpAndSettle();

      // The message is real text in the semantics tree (WCAG 2.2 AA,
      // 1.4.1 Use of Colour) — a screen reader reaches it, and it is not the
      // error tint doing the work.
      expect(
        tester
            .getSemantics(find.text('Name: this text is too long.'))
            .label
            .contains('too long'),
        isTrue,
      );
    });

    testWidgets('correcting the field lets the same save through', (
      tester,
    ) async {
      final repo = _FakeApiariesRepository();
      await openNewApiaryForm(tester, repo);
      await tester.enterText(
        find.byKey(const Key('apiary-name-field')),
        overlongName,
      );
      await _setLocationViaCurrentLocation(tester);
      await tester.tap(find.byKey(const Key('apiary-save-button')));
      await tester.pumpAndSettle();
      expect(repo.created, isEmpty);

      await tester.enterText(
        find.byKey(const Key('apiary-name-field')),
        'Montargil',
      );
      await tester.tap(find.byKey(const Key('apiary-save-button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(repo.created, hasLength(1));
      expect(repo.created.single.name, 'Montargil');
      expect(find.text('Name: this text is too long.'), findsNothing);
    });

    testWidgets(
      'a blocked save moves focus to the offending field — Save is pinned '
      'outside the scroll view, so an error below the fold would be invisible',
      (tester) async {
        final repo = _FakeApiariesRepository();
        await openNewApiaryForm(tester, repo);
        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          'Montargil',
        );
        // The DGAV number is the LAST field on the form, well below the fold.
        await tester.enterText(
          find.byKey(const Key('apiary-registration-number-field')),
          'ç' * 30,
        );
        await _setLocationViaCurrentLocation(tester);
        await tester.tap(find.byKey(const Key('apiary-save-button')));
        await tester.pumpAndSettle();

        expect(repo.created, isEmpty);
        // Focusing the offending field is what scrolls it into view and moves
        // a screen reader to the message.
        final editable = tester.widget<EditableText>(
          find.descendant(
            of: find.byKey(const Key('apiary-registration-number-field')),
            matching: find.byType(EditableText),
          ),
        );
        expect(editable.focusNode.hasFocus, isTrue);
      },
    );

    testWidgets(
      'editing a field clears the previous verdict, so a corrected value is '
      'not left sitting under a stale message',
      (tester) async {
        final repo = _FakeApiariesRepository();
        await openNewApiaryForm(tester, repo);
        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          overlongName,
        );
        await _setLocationViaCurrentLocation(tester);
        await tester.tap(find.byKey(const Key('apiary-save-button')));
        await tester.pumpAndSettle();
        expect(find.text('Name: this text is too long.'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          'Montargil',
        );
        await tester.pump();

        // Gone as soon as it is wrong, not on the next Save — this form does
        // not autovalidate, so the Form's onChanged has to re-run validate().
        expect(find.text('Name: this text is too long.'), findsNothing);
      },
    );

    testWidgets(
      'a label added to the #443 mapping reaches the save-time check for free '
      '— this PR owns no copy of its own',
      (tester) async {
        // #595 added `registration_number` to `sync_rejection_messages.dart`'s
        // label table for the needs-fix screen. Nothing here was changed to
        // follow it: the save-time check reads that same table, so the field
        // gets the specific line rather than the generic fallback purely
        // because the shared mapping grew.
        final repo = _FakeApiariesRepository();
        await openNewApiaryForm(tester, repo);
        await tester.enterText(
          find.byKey(const Key('apiary-name-field')),
          'Montargil',
        );
        // `registration_number` is capped at 50 bytes server-side; the
        // field's own maxLength counts characters, so 30 two-byte characters
        // pass it and fail the server's cap.
        await tester.enterText(
          find.byKey(const Key('apiary-registration-number-field')),
          'ç' * 30,
        );
        await _setLocationViaCurrentLocation(tester);
        await tester.tap(find.byKey(const Key('apiary-save-button')));
        await tester.pumpAndSettle();

        expect(repo.created, isEmpty);
        expect(
          find.text('Registration number: this text is too long.'),
          findsOneWidget,
        );
      },
    );
  });
}
