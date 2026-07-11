import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_list_screen.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A fake that never touches the real `geolocator` platform channel — see
/// device_location.dart's own doc comment on why [DeviceLocationService] is
/// behind an overridable provider. [result] is returned from every
/// [current] call, letting a test fix the location outcome (available,
/// denied, disabled, ...) deterministically.
class _FakeDeviceLocationService implements DeviceLocationService {
  const _FakeDeviceLocationService(this.result);
  final DeviceLocation result;

  @override
  Future<DeviceLocation> current() async => result;
}

/// Wraps [ApiariesListScreen] with just enough scaffolding (router for the
/// row-tap navigation, l10n, a ProviderScope with the apiaries stream and
/// device-location fixed) to test it in isolation — this screen has no own
/// AppBar/Scaffold (it's embedded in the app shell), so tests give it a
/// minimal Scaffold host, matching how the shell renders it.
Widget _buildScreen({
  required List<Apiary> apiaries,
  DeviceLocation location = const DeviceLocationUnavailable(),
}) {
  final router = GoRouter(
    initialLocation: '/apiaries',
    routes: [
      GoRoute(
        path: '/apiaries',
        builder: (context, state) => const Scaffold(body: ApiariesListScreen()),
      ),
      GoRoute(
        path: '/apiaries/:id',
        builder: (context, state) =>
            Scaffold(body: Text('detail-${state.pathParameters['id']}')),
      ),
    ],
  );
  return ProviderScope(
    overrides: [
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      deviceLocationServiceProvider.overrideWithValue(
        _FakeDeviceLocationService(location),
      ),
    ],
    child: MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

Apiary _apiary(
  String id,
  String name, {
  int hiveCount = 0,
  double? lon,
  double? lat,
}) => Apiary(
  id: id,
  name: name,
  hiveCount: hiveCount,
  locationLon: lon,
  locationLat: lat,
);

void main() {
  group('search (FR-AP-6, D-17)', () {
    testWidgets('an empty query shows every apiary', (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          apiaries: [_apiary('a1', 'Serra Norte'), _apiary('a2', 'Vale Sul')],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Serra Norte'), findsOneWidget);
      expect(find.text('Vale Sul'), findsOneWidget);
    });

    testWidgets('typing a query filters by name, case-insensitively', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(
          apiaries: [_apiary('a1', 'Serra Norte'), _apiary('a2', 'Vale Sul')],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('apiaries-search-field')),
        'serra',
      );
      await tester.pumpAndSettle();

      expect(find.text('Serra Norte'), findsOneWidget);
      expect(find.text('Vale Sul'), findsNothing);
    });

    testWidgets('a substring match (not just prefix) finds the apiary', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(apiaries: [_apiary('a1', 'Encosta Norte')]),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('apiaries-search-field')),
        'orte',
      );
      await tester.pumpAndSettle();

      expect(find.text('Encosta Norte'), findsOneWidget);
    });

    testWidgets('a query matching nothing shows the no-results empty state', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(apiaries: [_apiary('a1', 'Serra Norte')]),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('apiaries-search-field')),
        'nonexistent',
      );
      await tester.pumpAndSettle();

      expect(find.text('Serra Norte'), findsNothing);
      expect(find.text('No apiaries match your search.'), findsOneWidget);
    });

    testWidgets('the clear button resets the query and restores the list', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(
          apiaries: [_apiary('a1', 'Serra Norte'), _apiary('a2', 'Vale Sul')],
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('apiaries-search-field')),
        'serra',
      );
      await tester.pumpAndSettle();
      expect(find.text('Vale Sul'), findsNothing);

      await tester.tap(find.byKey(const Key('apiaries-search-clear-button')));
      await tester.pumpAndSettle();

      expect(find.text('Serra Norte'), findsOneWidget);
      expect(find.text('Vale Sul'), findsOneWidget);
    });
  });

  group('proximity ordering (FR-AP-2, #33)', () {
    testWidgets(
      'apiaries are ordered nearest-first when location is available',
      (tester) async {
        // Reference point near (0,0); "Far" is much further east than "Near".
        await tester.pumpWidget(
          _buildScreen(
            apiaries: [
              _apiary('far', 'Far', lon: 10.0, lat: 0.0),
              _apiary('near', 'Near', lon: 0.01, lat: 0.0),
            ],
            location: const DeviceLocationAvailable(lon: 0.0, lat: 0.0),
          ),
        );
        await tester.pumpAndSettle();

        final tiles = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .toList();
        final titles = tiles
            .map((t) => (t.title as Text).data)
            .toList(growable: false);
        expect(titles, ['Near', 'Far']);
      },
    );

    testWidgets(
      'falls back to alphabetical order with a banner when location is denied',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(
            apiaries: [_apiary('z', 'Zulu'), _apiary('a', 'Alpha')],
            location: const DeviceLocationPermissionDenied(),
          ),
        );
        await tester.pumpAndSettle();

        final tiles = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .toList();
        final titles = tiles
            .map((t) => (t.title as Text).data)
            .toList(growable: false);
        expect(titles, ['Alpha', 'Zulu']);

        expect(
          find.byKey(const Key('apiaries-location-fallback-banner')),
          findsOneWidget,
        );
        expect(
          find.text('Location access denied — showing apiaries by name.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'falls back to alphabetical order with a banner when location services are disabled',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(
            apiaries: [_apiary('z', 'Zulu'), _apiary('a', 'Alpha')],
            location: const DeviceLocationServicesDisabled(),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('apiaries-location-fallback-banner')),
          findsOneWidget,
        );
        expect(
          find.text('Location services are off — showing apiaries by name.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('no fallback banner is shown once location is available', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(
          apiaries: [_apiary('a1', 'Serra Norte', lon: 0, lat: 0)],
          location: const DeviceLocationAvailable(lon: 0, lat: 0),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('apiaries-location-fallback-banner')),
        findsNothing,
      );
    });

    testWidgets(
      'an apiary without a location sorts after every located apiary',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(
            apiaries: [
              _apiary('none', 'No Location'),
              _apiary('near', 'Near', lon: 0.01, lat: 0.0),
            ],
            location: const DeviceLocationAvailable(lon: 0.0, lat: 0.0),
          ),
        );
        await tester.pumpAndSettle();

        final tiles = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .toList();
        final titles = tiles
            .map((t) => (t.title as Text).data)
            .toList(growable: false);
        expect(titles, ['Near', 'No Location']);
      },
    );
  });

  group('pure sort/filter helpers', () {
    test('filterApiariesByQuery matches name case-insensitively', () {
      final apiaries = [_apiary('a', 'Serra Norte'), _apiary('b', 'Vale Sul')];
      expect(filterApiariesByQuery(apiaries, 'SERRA').map((a) => a.id), ['a']);
      expect(filterApiariesByQuery(apiaries, ''), apiaries);
      expect(filterApiariesByQuery(apiaries, '   '), apiaries);
      expect(filterApiariesByQuery(apiaries, 'zzz'), isEmpty);
    });

    test(
      'sortApiariesByDistance orders ascending and puts no-location entries last',
      () {
        final apiaries = [
          _apiary('far', 'Far', lon: 10, lat: 0),
          _apiary('none', 'No Location'),
          _apiary('near', 'Near', lon: 0.01, lat: 0),
        ];
        final sorted = sortApiariesByDistance(
          apiaries,
          originLon: 0,
          originLat: 0,
        );
        expect(sorted.map((a) => a.id).toList(), ['near', 'far', 'none']);
      },
    );

    test('sortApiariesByName orders alphabetically', () {
      final apiaries = [_apiary('z', 'Zulu'), _apiary('a', 'Alpha')];
      final sorted = sortApiariesByName(apiaries);
      expect(sorted.map((a) => a.id).toList(), ['a', 'z']);
    });
  });
}
