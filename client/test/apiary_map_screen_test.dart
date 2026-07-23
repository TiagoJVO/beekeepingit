import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/core/geo/haversine.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_map_screen.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' as intl;

import 'support/a11y_matchers.dart';

/// A deterministic fake for [DeviceLocationService] (#34 AC — the map's
/// permission-denied path must be testable without depending on the real
/// `geolocator` plugin's MethodChannel, which has no handler under
/// flutter_test). CRITICAL finding fix: this replaces the previous
/// `GeolocatorPlatform.instance` fake — the map screen now goes through
/// `deviceLocationServiceProvider` (core/geo/device_location.dart) the same
/// way apiaries_list_screen_test.dart already overrides it, rather than the
/// screen reaching past that abstraction to the raw plugin. [result] is
/// returned from every [current] call, letting a test fix the location
/// outcome (available, denied, disabled, ...) deterministically. [onCalled]
/// (optional) lets a test count invocations — see the "only ONE location
/// request" regression test below.
class _FakeDeviceLocationService implements DeviceLocationService {
  const _FakeDeviceLocationService(this.result, {this.onCalled});
  final DeviceLocation result;
  final void Function()? onCalled;

  @override
  Future<DeviceLocation> current() async {
    onCalled?.call();
    return result;
  }
}

/// Mirrors widget_test.dart's onboarding-gate stubs (profile/organization
/// already complete) so these tests reach the apiaries tab directly.
class _CompleteProfileController extends ProfileController {
  _CompleteProfileController({this.locale = 'en'});

  final String locale;

  @override
  Future<Profile> build() async => Profile(
    id: 'test-user',
    name: 'Test User',
    email: 'test@example.com',
    locale: locale,
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

const _serraNorte = Apiary(
  id: 'a1',
  name: 'Serra Norte',
  hiveCount: 5,
  locationLon: -8.6109,
  locationLat: 41.1496,
);
const _valeDasEguas = Apiary(
  id: 'a2',
  name: 'Vale das Éguas',
  hiveCount: 8,
  locationLon: -8.4265,
  locationLat: 41.5503,
);
const _semLocal = Apiary(id: 'a3', name: 'Sem Local', hiveCount: 2);

/// [locationService] defaults to reporting location services disabled —
/// the same "no user marker, denied banner shown" branch the previous
/// `GeolocatorPlatform` fake exercised by default, now driven through
/// `deviceLocationServiceProvider` (CRITICAL fix — both the map screen and
/// the list's proximity-ordering banner share this one override, matching
/// how they share the real `deviceLocationProvider` cache in production).
Widget _buildApp(
  List<Apiary> apiaries, {
  DeviceLocationService? locationService,
  String profileLocale = 'en',
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      deviceLocationServiceProvider.overrideWithValue(
        locationService ??
            const _FakeDeviceLocationService(DeviceLocationServicesDisabled()),
      ),
      // The stored profile locale now drives the app's UI language (#340),
      // so a test exercising PT formatting sets it here rather than forcing
      // the device locale.
      profileProvider.overrideWith(
        () => _CompleteProfileController(locale: profileLocale),
      ),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

/// Switches from the apiaries list (the router's initial location) to the
/// map view via the list/map toggle's map segment (#34, #35).
Future<void> _goToMap(
  WidgetTester tester, {
  DeviceLocationService? locationService,
  String profileLocale = 'en',
}) async {
  await tester.pumpWidget(
    _buildApp(
      [_serraNorte, _valeDasEguas, _semLocal],
      locationService: locationService,
      profileLocale: profileLocale,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('apiaries-view-map-button')));
  await tester.pumpAndSettle();
}

/// Taps a flutter_map [Marker] by [key]. flutter_map positions markers via
/// its own internal Stack/MobileLayerTransformer, whose paint transform
/// WidgetController.getCenter's cached RenderBox geometry doesn't always
/// reflect exactly (a known interaction between flutter_map's custom layer
/// layout and flutter_test's hit-test warning, not a bug in this screen) —
/// re-resolving the element's actual paint bounds immediately before tapping
/// (rather than trusting a finder's precomputed center) taps the real
/// on-screen location reliably.
Future<void> _tapMarker(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  final box = tester.renderObject<RenderBox>(finder);
  final center = box.localToGlobal(box.size.center(Offset.zero));
  await tester.tapAt(center);
  await tester.pumpAndSettle();
}

Future<void> _longPressMarker(WidgetTester tester, Key key) async {
  final finder = find.byKey(key);
  final box = tester.renderObject<RenderBox>(finder);
  final center = box.localToGlobal(box.size.center(Offset.zero));
  final gesture = await tester.startGesture(center);
  await tester.pump(kLongPressTimeout + kPressTimeout);
  await gesture.up();
  // Not pumpAndSettle: the map's own pan/fling gesture recognizer can pick
  // up residual velocity from this synthetic gesture sequence and animate
  // indefinitely-ish, which pumpAndSettle would wait out. A couple of fixed
  // pumps are enough to let the navigation (context.go) take effect.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  testWidgets(
    'renders a marker for each apiary with a location, skipping unlocated ones',
    (tester) async {
      await _goToMap(tester);

      expect(find.byKey(const Key('apiary-map')), findsOneWidget);
      expect(
        find.byKey(Key('apiary-marker-${_serraNorte.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('apiary-marker-${_valeDasEguas.id}')),
        findsOneWidget,
      );
      // The unlocated apiary must not produce a marker or throw.
      expect(find.byKey(Key('apiary-marker-${_semLocal.id}')), findsNothing);
    },
  );

  testWidgets(
    'each located apiary marker surfaces its name as a visible label (#344, FR-AP-3)',
    (tester) async {
      await _goToMap(tester);

      // Each located apiary's name renders as a visible on-map label, keyed
      // per apiary so the two markers are distinguishable at a glance (the
      // bug: the name was only in the Semantics label, never drawn).
      expect(
        find.byKey(Key('apiary-marker-name-${_serraNorte.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(Key('apiary-marker-name-${_valeDasEguas.id}')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(Key('apiary-marker-name-${_serraNorte.id}')),
          matching: find.text(_serraNorte.name),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(Key('apiary-marker-name-${_valeDasEguas.id}')),
          matching: find.text(_valeDasEguas.name),
        ),
        findsOneWidget,
      );
      // The unlocated apiary has no marker, hence no name label.
      expect(
        find.byKey(Key('apiary-marker-name-${_semLocal.id}')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'the apiary marker keeps exposing name + hive count to screen readers (#344)',
    (tester) async {
      await _goToMap(tester);

      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel('${_serraNorte.name}, ${_serraNorte.hiveCount}'),
        findsOneWidget,
      );
      handle.dispose();
    },
  );

  testWidgets(
    'the empty case (no located apiaries) shows the empty state, not an error',
    (tester) async {
      await tester.pumpWidget(_buildApp([_semLocal]));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apiaries-view-map-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('apiary-map')), findsOneWidget);
      expect(find.byKey(const Key('apiary-map-empty')), findsOneWidget);
    },
  );

  testWidgets(
    'location permission denied/unavailable in the test harness shows the banner, not an error, and no user marker',
    (tester) async {
      await _goToMap(tester);

      // flutter_test has no real location plugin wired up, so the screen's
      // graceful-degradation path (#34 AC) is exactly what's exercised here:
      // no user marker, and the permission-denied banner is shown instead of
      // a crash.
      expect(find.byKey(const Key('apiary-map-user-marker')), findsNothing);
      expect(
        find.byKey(const Key('apiary-map-location-denied')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'tapping the map toggle segment shows the map without leaving the Apiaries tab (#35)',
    (tester) async {
      await _goToMap(tester);

      // The map is a sibling view within the Apiaries tab (#35), not a
      // pushed route — the shell header keeps showing the tab title (also
      // duplicated in the bottom nav label, hence findsWidgets — same
      // pattern as app_shell_test.dart), and the map segment of the toggle
      // is now the selected one.
      expect(find.text('Apiaries'), findsWidgets);
      expect(find.byKey(const Key('apiary-map')), findsOneWidget);
    },
  );

  testWidgets(
    'tap-to-select-two-then-measure: selecting two apiaries shows the haversine distance',
    (tester) async {
      await _goToMap(tester);

      // Before any selection: the hint invites tapping two apiaries.
      expect(
        find.text('Tap two apiaries to measure the distance between them.'),
        findsOneWidget,
      );

      await _tapMarker(tester, Key('apiary-marker-${_serraNorte.id}'));
      expect(
        find.text('Selected Serra Norte. Tap another apiary to measure.'),
        findsOneWidget,
      );

      await _tapMarker(tester, Key('apiary-marker-${_valeDasEguas.id}'));

      // Same known coordinate pair as the server-side ST_Distance test
      // (services/apiaries/main_test.go) and the haversine unit test
      // (~47.6km) — the displayed result must show that value in km.
      expect(
        find.textContaining('Serra Norte to Vale das Éguas: 47.'),
        findsOneWidget,
      );
      expect(
        find.text('km', findRichText: true),
        findsNothing,
      ); // sanity: no stray literal
    },
  );

  testWidgets('the clear-selection action resets the measurement', (
    tester,
  ) async {
    await _goToMap(tester);

    await _tapMarker(tester, Key('apiary-marker-${_serraNorte.id}'));
    await _tapMarker(tester, Key('apiary-marker-${_valeDasEguas.id}'));

    expect(find.byKey(const Key('apiary-map-measure-clear')), findsOneWidget);
    await tester.tap(find.byKey(const Key('apiary-map-measure-clear')));
    await tester.pumpAndSettle();

    expect(
      find.text('Tap two apiaries to measure the distance between them.'),
      findsOneWidget,
    );
  });

  testWidgets('tapping the same selected apiary again clears the selection', (
    tester,
  ) async {
    await _goToMap(tester);

    await _tapMarker(tester, Key('apiary-marker-${_serraNorte.id}'));
    expect(
      find.text('Selected Serra Norte. Tap another apiary to measure.'),
      findsOneWidget,
    );

    await _tapMarker(tester, Key('apiary-marker-${_serraNorte.id}'));
    expect(
      find.text('Tap two apiaries to measure the distance between them.'),
      findsOneWidget,
    );
  });

  testWidgets('long-pressing an apiary marker navigates to its detail route', (
    tester,
  ) async {
    await _goToMap(tester);

    await _longPressMarker(tester, Key('apiary-marker-${_serraNorte.id}'));

    // Asserted via the router's own current location (not e.g. the edit
    // form's field key) — robust regardless of whether the pushed
    // ApiaryFormScreen's async _loadExisting has finished rendering its
    // fields yet, and independent of the residual map-gesture-animation
    // that keeps pumpAndSettle from ever fully quiescing on this screen (see
    // _longPressMarker). Anchored on AppShell (not MaterialApp): GoRouter's
    // InheritedWidget is provided by the Router built INSIDE
    // MaterialApp.router, i.e. below it in the tree — GoRouter.of looks
    // upward from its context, so resolving it from the MaterialApp element
    // itself never finds it. AppShell wraps the StatefulShellRoute's
    // navigationShell and stays mounted across this in-tab navigation, so
    // it's a reliable descendant to anchor on instead.
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    expect(
      router.routeInformationProvider.value.uri.toString(),
      '/apiaries/a1',
    );
  });

  group('satellite default + layer toggle (#257, D-16)', () {
    testWidgets('the map opens with the satellite tile layer by default', (
      tester,
    ) async {
      await _goToMap(tester);

      expect(
        find.byKey(const Key('apiary-map-tile-layer-satellite')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('apiary-map-tile-layer-streets')),
        findsNothing,
      );
      final tileLayer = tester.widget<TileLayer>(
        find.byKey(const Key('apiary-map-tile-layer-satellite')),
      );
      // Esri World Imagery, {z}/{y}/{x} order (not OSM's {z}/{x}/{y}) — the
      // exact endpoint the #257 AC calls for, asserted by value rather than
      // just "a TileLayer exists" so a regression back to the OSM URL (or a
      // typo'd segment order) fails this test.
      expect(
        tileLayer.urlTemplate,
        'https://server.arcgisonline.com/ArcGIS/rest/services/'
        'World_Imagery/MapServer/tile/{z}/{y}/{x}',
      );
    });

    testWidgets('the toggle switches to the streets (OSM) layer and back', (
      tester,
    ) async {
      await _goToMap(tester);

      await tester.tap(
        find.byKey(const Key('apiary-map-layer-streets-button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('apiary-map-tile-layer-streets')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('apiary-map-tile-layer-satellite')),
        findsNothing,
      );
      final streetsLayer = tester.widget<TileLayer>(
        find.byKey(const Key('apiary-map-tile-layer-streets')),
      );
      expect(
        streetsLayer.urlTemplate,
        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      );

      await tester.tap(
        find.byKey(const Key('apiary-map-layer-satellite-button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('apiary-map-tile-layer-satellite')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('apiary-map-tile-layer-streets')),
        findsNothing,
      );
    });

    testWidgets(
      'the chosen layer survives switching to the list view and back (#257 AC)',
      (tester) async {
        await _goToMap(tester);

        await tester.tap(
          find.byKey(const Key('apiary-map-layer-streets-button')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('apiary-map-tile-layer-streets')),
          findsOneWidget,
        );

        // Switch to the list view (the map stays mounted in the IndexedStack,
        // #35) and back to the map.
        await tester.tap(find.byKey(const Key('apiaries-view-list-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiaries-view-map-button')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('apiary-map-tile-layer-streets')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('apiary-map-tile-layer-satellite')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'the layer toggle segments meet the min tap target and have semantics labels',
      (tester) async {
        await _goToMap(tester);

        expectMinTapTarget(
          tester,
          find.byKey(const Key('apiary-map-layer-satellite-button')),
        );
        expectMinTapTarget(
          tester,
          find.byKey(const Key('apiary-map-layer-streets-button')),
        );
        expectHasSemanticsLabel(
          tester,
          const Key('apiary-map-layer-satellite-button'),
        );
        expectHasSemanticsLabel(
          tester,
          const Key('apiary-map-layer-streets-button'),
        );
        expectHasSemanticsLabel(tester, const Key('apiary-map-layer-toggle'));
      },
    );

    testWidgets(
      'attribution shows the active source and switches with the layer',
      (tester) async {
        await _goToMap(tester);

        expect(
          find.byKey(const Key('apiary-map-attribution-text')),
          findsOneWidget,
        );
        expect(find.textContaining('Esri'), findsOneWidget);
        expect(find.textContaining('OpenStreetMap'), findsNothing);

        await tester.tap(
          find.byKey(const Key('apiary-map-layer-streets-button')),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('OpenStreetMap'), findsOneWidget);
        expect(find.textContaining('Esri'), findsNothing);
      },
    );

    testWidgets(
      'at phone width the attribution wraps on-screen and sits clear of the measure card',
      (tester) async {
        // The constrained case for the map's overlay layout: at 375 logical
        // px the measure card's hint text wraps (making the card taller than
        // its desktop height) and the long Esri credit line is wider than
        // the screen. Both were real overlaps/overflows during development —
        // the attribution shares the measure overlay's bottom-anchored
        // Positioned (bounded width, stacked above) precisely so neither can
        // happen; this pins that.
        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await _goToMap(tester);

        final attribution = tester.getRect(
          find.byKey(const Key('apiary-map-attribution-text')),
        );
        final measure = tester.getRect(
          find.byKey(const Key('apiary-map-measure-overlay')),
        );

        // Wraps within the screen instead of overflowing off the right edge.
        expect(attribution.right, lessThanOrEqualTo(375));
        // Fully above the measure card, never underneath it.
        expect(attribution.bottom, lessThanOrEqualTo(measure.top));
      },
    );

    testWidgets('the default layer provider value is MapLayer.satellite', (
      tester,
    ) async {
      // Belt-and-suspenders unit-level check on the provider default
      // itself (independent of the widget tree), matching how
      // apiariesViewProvider's default is implicitly relied upon —
      // this pins MapLayer.satellite as literally the provider's
      // initial state, not just "whatever the first-rendered TileLayer
      // happens to be".
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(mapLayerProvider), MapLayer.satellite);
    });
  });

  group('device location sharing (CRITICAL finding)', () {
    testWidgets(
      'only ONE location request fires when the list and map screens are '
      'both alive in the IndexedStack',
      (tester) async {
        var callCount = 0;
        await tester.pumpWidget(
          _buildApp(
            [_serraNorte, _valeDasEguas, _semLocal],
            locationService: _FakeDeviceLocationService(
              const DeviceLocationAvailable(lon: -8.6109, lat: 41.1496),
              onCalled: () => callCount++,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Before the fix, the list screen's own proximity-ordering banner
        // fetch (via deviceLocationProvider) and the map screen's
        // independent raw-Geolocator _loadUserLocation each fired their own
        // request as soon as the Apiaries tab opened — both views are
        // mounted at once inside the list/map IndexedStack (#35), so that
        // was already 2 requests before the user ever touched the toggle.
        expect(callCount, 1);

        // Switching to the map view must not fire a second request either
        // — the map screen shares the same cached deviceLocationProvider
        // the list screen already resolved, rather than re-fetching its own.
        await tester.tap(find.byKey(const Key('apiaries-view-map-button')));
        await tester.pumpAndSettle();

        expect(callCount, 1);
      },
    );

    testWidgets(
      'the map screen renders the user-location marker when the shared '
      'provider resolves to an available location',
      (tester) async {
        await _goToMap(
          tester,
          locationService: const _FakeDeviceLocationService(
            DeviceLocationAvailable(lon: -8.6109, lat: 41.1496),
          ),
        );

        expect(find.byKey(const Key('apiary-map-user-marker')), findsOneWidget);
        expect(
          find.byKey(const Key('apiary-map-location-denied')),
          findsNothing,
        );
      },
    );
  });

  group('error state (HIGH #4: no test previously drove the error branch)', () {
    testWidgets(
      'shows an error state (not a crash) when the apiaries stream errors',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              isAuthenticatedProvider.overrideWithValue(true),
              apiariesStreamProvider.overrideWith(
                (ref) => Stream<List<Apiary>>.error('boom'),
              ),
              deviceLocationServiceProvider.overrideWithValue(
                const _FakeDeviceLocationService(
                  DeviceLocationServicesDisabled(),
                ),
              ),
              profileProvider.overrideWith(_CompleteProfileController.new),
              organizationProvider.overrideWith(
                _ExistingOrganizationController.new,
              ),
            ],
            child: const BeekeepingitApp(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiaries-view-map-button')));
        await tester.pumpAndSettle();

        expect(find.textContaining('Could not load apiaries'), findsWidgets);
        expect(find.byKey(const Key('apiary-map')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('locale-aware measurement (MEDIUM finding)', () {
    testWidgets(
      'the measure result uses a comma decimal separator in Portuguese, not '
      'a hardcoded period',
      (tester) async {
        // Driving the locale through the stored profile (rather than
        // wrapping ApiaryMapScreen in its own standalone MaterialApp) reuses
        // the full app/_goToMap harness every other test in this file relies
        // on — the map's camera-fit position for these two markers is only
        // verified tap-reachable at THIS harness's viewport (a standalone
        // MaterialApp(home: Scaffold(body: ApiaryMapScreen())) fits the
        // markers differently at the default 800x600 test viewport, close
        // enough to the bottom measure/attribution overlay that the first
        // tap lands on the overlay instead of the marker underneath). Since
        // #340 the profile locale — not the device locale — drives the app's
        // UI language, so setting it here also exercises that wiring.
        await _goToMap(tester, profileLocale: 'pt');

        await _tapMarker(tester, Key('apiary-marker-${_serraNorte.id}'));
        await _tapMarker(tester, Key('apiary-marker-${_valeDasEguas.id}'));

        // Compute the expected PT-formatted value directly (rather than
        // hardcoding an assumed distance) so this test doesn't depend on
        // guessing the exact haversine result to 2 decimal places.
        final km = haversineDistanceKm(
          lat1: _serraNorte.locationLat!,
          lon1: _serraNorte.locationLon!,
          lat2: _valeDasEguas.locationLat!,
          lon2: _valeDasEguas.locationLon!,
        );
        final ptFormatted = intl.NumberFormat.decimalPatternDigits(
          locale: 'pt',
          decimalDigits: 2,
        ).format(km);
        expect(
          ptFormatted,
          contains(','),
          reason: 'sanity: PT formatting must actually use a comma here',
        );

        // Was previously always km.toStringAsFixed(2), which renders a
        // literal period regardless of locale.
        expect(find.textContaining(ptFormatted), findsOneWidget);
        expect(
          find.textContaining(km.toStringAsFixed(2)),
          findsNothing,
          reason: 'the locale-unaware, period-separated form must be gone',
        );
      },
    );
  });

  group('marker rotation + badge (#383)', () {
    testWidgets('apiary pins no longer render the hive-count badge', (
      tester,
    ) async {
      await _goToMap(tester);

      final markerFinder = find.byKey(Key('apiary-marker-${_serraNorte.id}'));
      expect(
        find.descendant(
          of: markerFinder,
          matching: find.text('${_serraNorte.hiveCount}'),
        ),
        findsNothing,
      );
    });

    testWidgets('markers counter-rotate to stay upright as the map rotates', (
      tester,
    ) async {
      await _goToMap(tester);

      final layer = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
      expect(layer.rotate, isTrue);
    });
  });

  group('theme-token pin styling (MEDIUM finding)', () {
    testWidgets(
      'the user-location pin label derives its style from theme.textTheme, '
      'not a hardcoded TextStyle',
      (tester) async {
        await _goToMap(
          tester,
          locationService: const _FakeDeviceLocationService(
            DeviceLocationAvailable(lon: -8.6109, lat: 41.1496),
          ),
        );

        final userMarker = find.byKey(const Key('apiary-map-user-marker'));
        final theme = Theme.of(tester.element(userMarker));
        final labelText = tester.widget<Text>(
          find.descendant(of: userMarker, matching: find.text('You')),
        );

        expect(
          labelText.style,
          theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onTertiary,
            fontWeight: FontWeight.bold,
          ),
        );
      },
    );
  });
}
