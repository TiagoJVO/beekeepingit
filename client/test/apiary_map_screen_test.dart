import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator_platform_interface/geolocator_platform_interface.dart';
import 'package:go_router/go_router.dart';

/// A deterministic fake for [GeolocatorPlatform] (#34 AC — the map's
/// permission-denied path must be testable without depending on the real
/// plugin's MethodChannel, which has no handler under flutter_test and
/// resolves via a real platform round-trip that flutter_test's fake async
/// zone can't reliably wait out). Reports location services as disabled,
/// exercising the same "no user marker, denied banner shown" branch a real
/// denial would.
class _LocationServicesDisabledGeolocator extends GeolocatorPlatform {
  @override
  Future<bool> isLocationServiceEnabled() async => false;
}

/// Mirrors widget_test.dart's onboarding-gate stubs (profile/organization
/// already complete) so these tests reach the apiaries tab directly.
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

Widget _buildApp(List<Apiary> apiaries) {
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

/// Navigates from the apiaries list (the router's initial location) to the
/// map screen via the list's "View map" entry point (#34).
Future<void> _goToMap(WidgetTester tester) async {
  await tester.pumpWidget(_buildApp([_serraNorte, _valeDasEguas, _semLocal]));
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
  setUp(() {
    GeolocatorPlatform.instance = _LocationServicesDisabledGeolocator();
  });

  testWidgets('renders a marker for each apiary with a location, skipping unlocated ones', (
    tester,
  ) async {
    await _goToMap(tester);

    expect(find.byKey(const Key('apiary-map')), findsOneWidget);
    expect(find.byKey(Key('apiary-marker-${_serraNorte.id}')), findsOneWidget);
    expect(
      find.byKey(Key('apiary-marker-${_valeDasEguas.id}')),
      findsOneWidget,
    );
    // The unlocated apiary must not produce a marker or throw.
    expect(find.byKey(Key('apiary-marker-${_semLocal.id}')), findsNothing);
  });

  testWidgets('the empty case (no located apiaries) shows the empty state, not an error', (
    tester,
  ) async {
    await tester.pumpWidget(_buildApp([_semLocal]));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('apiaries-view-map-button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('apiary-map')), findsOneWidget);
    expect(find.byKey(const Key('apiary-map-empty')), findsOneWidget);
  });

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

  testWidgets('tapping the map entry point navigates to /apiaries/map with the shell title', (
    tester,
  ) async {
    await _goToMap(tester);

    expect(find.text('Apiary map'), findsOneWidget);
  });

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
      expect(find.text('km', findRichText: true), findsNothing); // sanity: no stray literal
    },
  );

  testWidgets('the clear-selection action resets the measurement', (tester) async {
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
    expect(router.routeInformationProvider.value.uri.toString(), '/apiaries/a1');
  });
}
