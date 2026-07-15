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
  String? placeLabel,
}) => Apiary(
  id: id,
  name: name,
  hiveCount: hiveCount,
  locationLon: lon,
  locationLat: lat,
  placeLabel: placeLabel,
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

    testWidgets(
      'a query matching only the place label (not the name) still finds the '
      'apiary (#252/#254)',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(
            apiaries: [
              _apiary('a1', 'Colmeia 3', placeLabel: 'Montargil'),
              _apiary('a2', 'Colmeia 4', placeLabel: 'Alcácer'),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('apiaries-search-field')),
          'montargil',
        );
        await tester.pumpAndSettle();

        expect(find.text('Colmeia 3'), findsOneWidget);
        expect(find.text('Colmeia 4'), findsNothing);
      },
    );

    testWidgets(
      'the place label match is diacritic-insensitive (PT "São" ≈ "sao", #254 AC)',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(
            apiaries: [_apiary('a1', 'Colmeia 1', placeLabel: 'São Domingos')],
          ),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('apiaries-search-field')),
          'sao domingos',
        );
        await tester.pumpAndSettle();

        expect(find.text('Colmeia 1'), findsOneWidget);
      },
    );
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

  group('distance display (FR-AP-2, #253)', () {
    testWidgets(
      'a located apiary shows its distance from the device location',
      (tester) async {
        // ~1.1km east at the equator (0.01° longitude ≈ 1.11km).
        await tester.pumpWidget(
          _buildScreen(
            apiaries: [_apiary('near', 'Near', lon: 0.01, lat: 0.0)],
            location: const DeviceLocationAvailable(lon: 0.0, lat: 0.0),
          ),
        );
        await tester.pumpAndSettle();

        final tile = tester.widget<ListTile>(find.byType(ListTile));
        final subtitle = (tile.subtitle as Text).data!;
        expect(subtitle, contains('km away'));
        // Also still shows the hive count (distance is appended, not
        // replacing the existing subtitle content, #253 AC).
        expect(subtitle, contains('hives'));
      },
    );

    testWidgets(
      'an apiary without a location shows no distance (no placeholder noise, #253 AC)',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(
            apiaries: [_apiary('none', 'No Location')],
            location: const DeviceLocationAvailable(lon: 0.0, lat: 0.0),
          ),
        );
        await tester.pumpAndSettle();

        final tile = tester.widget<ListTile>(find.byType(ListTile));
        final subtitle = (tile.subtitle as Text).data!;
        expect(subtitle, isNot(contains('km away')));
      },
    );

    testWidgets(
      'no distance is shown when the device location is unavailable (#253 AC)',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(
            apiaries: [_apiary('a1', 'Serra Norte', lon: 0.01, lat: 0.0)],
            location: const DeviceLocationPermissionDenied(),
          ),
        );
        await tester.pumpAndSettle();

        final tile = tester.widget<ListTile>(find.byType(ListTile));
        final subtitle = (tile.subtitle as Text).data!;
        expect(subtitle, isNot(contains('km away')));
      },
    );
  });

  group('list/map toggle (FR-AP-4, #35)', () {
    testWidgets('the list view is active by default and the map is hidden', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(apiaries: [_apiary('a1', 'Serra Norte')]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Serra Norte'), findsOneWidget);
      expect(find.byKey(const Key('apiary-map')), findsNothing);

      expect(
        tester.getSemantics(find.byKey(const Key('apiaries-view-list-button'))),
        matchesSemantics(
          isButton: true,
          isSelected: true,
          hasSelectedState: true,
          isFocusable: true,
          hasTapAction: true,
          hasFocusAction: true,
          label: 'List view',
        ),
      );
    });

    testWidgets(
      'tapping the map segment shows the map, hides the list, and marks the map segment active',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(apiaries: [_apiary('a1', 'Serra Norte')]),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiaries-view-map-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('apiary-map')), findsOneWidget);

        expect(
          tester.getSemantics(
            find.byKey(const Key('apiaries-view-map-button')),
          ),
          matchesSemantics(
            isButton: true,
            isSelected: true,
            hasSelectedState: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
            label: 'Map view',
          ),
        );
        expect(
          tester.getSemantics(
            find.byKey(const Key('apiaries-view-list-button')),
          ),
          matchesSemantics(
            isButton: true,
            isSelected: false,
            hasSelectedState: true,
            isFocusable: true,
            hasTapAction: true,
            hasFocusAction: true,
            label: 'List view',
          ),
        );
      },
    );

    testWidgets(
      'switching to map and back to list preserves the typed search query',
      (tester) async {
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

        await tester.tap(find.byKey(const Key('apiaries-view-map-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiaries-view-list-button')));
        await tester.pumpAndSettle();

        // The search field still shows what was typed, and the list is
        // still filtered by it — the query wasn't reset by switching views
        // (#35 AC: "switching views preserves relevant context").
        expect(find.text('serra'), findsOneWidget);
        expect(find.text('Serra Norte'), findsOneWidget);
        expect(find.text('Vale Sul'), findsNothing);
      },
    );

    testWidgets('each toggle segment meets the 44x44 minimum tap target size', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(apiaries: [_apiary('a1', 'Serra Norte')]),
      );
      await tester.pumpAndSettle();

      for (final key in [
        'apiaries-view-list-button',
        'apiaries-view-map-button',
      ]) {
        final size = tester.getSize(find.byKey(Key(key)));
        expect(size.width, greaterThanOrEqualTo(44));
        expect(size.height, greaterThanOrEqualTo(44));
      }
    });

    testWidgets(
      'each toggle segment also shows a tooltip, for pointer users hovering/long-pressing it',
      (tester) async {
        await tester.pumpWidget(
          _buildScreen(apiaries: [_apiary('a1', 'Serra Norte')]),
        );
        await tester.pumpAndSettle();

        final tooltips = tester
            .widgetList<Tooltip>(find.byType(Tooltip))
            .map((t) => t.message)
            .toList();
        expect(tooltips, containsAll(['List view', 'Map view']));
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
      'filterApiariesByQuery also matches place_label, diacritic-insensitively '
      '(FR-AP-6, #252/#254)',
      () {
        final apiaries = [
          _apiary('a', 'Colmeia 1', placeLabel: 'Montargil'),
          _apiary('b', 'Colmeia 2', placeLabel: 'São Domingos'),
          _apiary('c', 'Colmeia 3'), // no place_label
        ];
        expect(filterApiariesByQuery(apiaries, 'montargil').map((a) => a.id), [
          'a',
        ]);
        // PT "São" ≈ "sao" — case AND diacritic-insensitive (#254 AC).
        expect(
          filterApiariesByQuery(apiaries, 'sao domingos').map((a) => a.id),
          ['b'],
        );
        expect(filterApiariesByQuery(apiaries, 'SÃO').map((a) => a.id), ['b']);
        // An apiary with no place_label never throws/matches spuriously.
        expect(filterApiariesByQuery(apiaries, 'zzz'), isEmpty);
      },
    );

    test('filterApiariesByQuery matches either name OR place_label — a query '
        'need not appear in both', () {
      final apiaries = [_apiary('a', 'Encosta Norte', placeLabel: 'Alcácer')];
      expect(
        filterApiariesByQuery(apiaries, 'encosta').map((a) => a.id),
        ['a'],
        reason: 'name-only match still works',
      );
      expect(
        filterApiariesByQuery(apiaries, 'alcacer').map((a) => a.id),
        ['a'],
        reason: 'place_label-only match, diacritic-folded',
      );
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

  group('apiariesViewModelProvider memoization (HIGH #2)', () {
    test('an unrelated provider change (the list/map view toggle) does not '
        'recompute the filtered/sorted list — only the actual inputs '
        '(stream, query, location) do', () async {
      final container = ProviderContainer(
        overrides: [
          apiariesStreamProvider.overrideWith(
            (ref) =>
                Stream.value([_apiary('z', 'Zulu'), _apiary('a', 'Alpha')]),
          ),
          // Avoids touching the real geolocator plugin (no platform
          // channel under a plain test(), unlike testWidgets()) — this
          // test only cares about apiariesViewModelProvider's own caching
          // behavior, not the resolved location value.
          deviceLocationServiceProvider.overrideWithValue(
            const _FakeDeviceLocationService(DeviceLocationUnavailable()),
          ),
        ],
      );
      addTearDown(container.dispose);

      // Establish a listener so the stream provider is actually evaluated
      // (a bare container.read of a StreamProvider's own .future can hang
      // without an active listener keeping it subscribed), then let its
      // first emission flow through the event queue before reading —
      // otherwise the first read could observe AsyncLoading, which is a
      // different AsyncValue instance every time regardless of
      // memoization. Mirrors apiaries_repository_test.dart's own
      // listen()+pumpEventQueue() pattern for watch()-backed streams.
      container.listen(apiariesStreamProvider, (previous, next) {});
      await pumpEventQueue();

      final first = container.read(apiariesViewModelProvider);

      // Before the fix, this computation ran straight inside build(), so
      // ANY rebuild of ApiariesListScreen — including one triggered by an
      // unrelated provider like this view toggle — redid the O(n)
      // filter+haversine-sort. Hoisted into its own Provider, Riverpod
      // caches the result: reading it again without touching one of its
      // three real inputs (stream/query/location) must return the exact
      // same object.
      container.read(apiariesViewProvider.notifier).state = ApiariesView.map;
      final second = container.read(apiariesViewModelProvider);

      expect(
        identical(first, second),
        isTrue,
        reason:
            'unrelated apiariesViewProvider change must not recompute '
            'apiariesViewModelProvider',
      );

      // Changing an actual input (the search query) DOES recompute.
      container.read(apiariesSearchQueryProvider.notifier).state = 'zulu';
      final third = container.read(apiariesViewModelProvider);

      expect(
        identical(first, third),
        isFalse,
        reason: 'a real input change (search query) must recompute it',
      );
    });
  });

  group('error state (HIGH #4: no test previously drove the error branch)', () {
    testWidgets(
      'shows an error state (not a crash) when the apiaries stream errors',
      (tester) async {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiariesStreamProvider.overrideWith(
                (ref) => Stream<List<Apiary>>.error('boom'),
              ),
              deviceLocationServiceProvider.overrideWithValue(
                const _FakeDeviceLocationService(
                  DeviceLocationServicesDisabled(),
                ),
              ),
            ],
            child: const MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(body: ApiariesListScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Could not load apiaries'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
