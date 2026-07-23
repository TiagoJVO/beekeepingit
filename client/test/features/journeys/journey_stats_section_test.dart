import 'package:beekeepingit_client/features/activities/activity_types.dart';
import 'package:beekeepingit_client/features/journeys/journey_stats.dart';
import 'package:beekeepingit_client/features/journeys/journey_stats_section.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Widget tests for the #49 minimal display surface (FR-JO-1) — a lightweight
/// `MaterialApp` + `journeyStatsProvider` override, mirroring
/// core/l10n/locale_formatting_test.dart's own "wrap the widget directly,
/// skip the full app shell" convention rather than
/// apiary_activities_section_test.dart's (that section is already wired
/// into a real screen; this one isn't yet — #48 does that wiring).
Widget _buildSection({
  required String journeyId,
  required Stream<JourneyStats> stats,
  String mainActivityType = activityTypeHarvest,
  Locale locale = const Locale('en'),
}) {
  return ProviderScope(
    overrides: [journeyStatsProvider.overrideWith((ref, id) => stats)],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: JourneyStatsSection(
          journeyId: journeyId,
          mainActivityType: mainActivityType,
        ),
      ),
    ),
  );
}

/// A router-backed variant of [_buildSection] for the "More stats" button's
/// own navigation test (#391) — a plain `MaterialApp` has no `GoRouter` for
/// `context.go` to find, so this wraps the section in a minimal two-route
/// `GoRouter` (mirrors journey_detail_screen_test.dart's fuller
/// `BeekeepingitApp`-based approach, but scoped down to just the one
/// navigation this file needs to prove).
Widget _buildSectionWithRouter({
  required String journeyId,
  required Stream<JourneyStats> stats,
  String mainActivityType = activityTypeHarvest,
}) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: JourneyStatsSection(
            journeyId: journeyId,
            mainActivityType: mainActivityType,
          ),
        ),
      ),
      GoRoute(
        path: '/journeys/:id/stats',
        builder: (context, state) => Scaffold(
          body: Text(
            'stats-screen-${state.pathParameters['id']}',
            key: const Key('journey-stats-detail-placeholder'),
          ),
        ),
      ),
    ],
  );
  return ProviderScope(
    overrides: [journeyStatsProvider.overrideWith((ref, id) => stats)],
    child: MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
}

JourneyStats _sampleStats({
  int apiariesPlanned = 5,
  int apiariesVisited = 3,
  int hivesHarvested = 42,
  num honeyCollectedKg = 18.5,
  double? averageSupersPerHive = 1.6,
  int hivesWorked = 0,
  int? hivesPlanned,
}) => JourneyStats(
  apiariesPlanned: apiariesPlanned,
  apiariesVisited: apiariesVisited,
  hivesHarvested: hivesHarvested,
  honeyCollectedKg: honeyCollectedKg,
  averageSupersPerHive: averageSupersPerHive,
  hivesWorked: hivesWorked,
  hivesPlanned: hivesPlanned,
);

void main() {
  group('JourneyStatsSection (#49, FR-JO-1)', () {
    testWidgets('renders every stat card with its computed value', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildSection(journeyId: 'j1', stats: Stream.value(_sampleStats())),
      );
      await tester.pumpAndSettle();

      expect(find.text('3/5'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('18.5 kg'), findsOneWidget);
      expect(find.text('1.6'), findsOneWidget);
      expect(find.text('2 apiaries missing'), findsOneWidget);
    });

    testWidgets(
      'shows the no-data placeholder (not a divide-by-zero crash or a bare '
      '"0") when averageSupersPerHive is null',
      (tester) async {
        await tester.pumpWidget(
          _buildSection(
            journeyId: 'j-empty',
            stats: Stream.value(JourneyStats.empty),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('0/0'), findsOneWidget);
        expect(find.text('No data yet'), findsOneWidget);
        expect(find.text('All planned apiaries visited'), findsOneWidget);
      },
    );

    testWidgets('pluralizes the missing count correctly for exactly one '
        'apiary missing', (tester) async {
      await tester.pumpWidget(
        _buildSection(
          journeyId: 'j2',
          stats: Stream.value(
            _sampleStats(
              apiariesPlanned: 2,
              apiariesVisited: 1,
              hivesHarvested: 4,
              honeyCollectedKg: 6,
              averageSupersPerHive: null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('1 apiary still missing'), findsOneWidget);
    });

    testWidgets('renders the Portuguese labels when the locale is pt (#49)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildSection(
          journeyId: 'j1',
          locale: const Locale('pt'),
          stats: Stream.value(
            _sampleStats(
              apiariesPlanned: 2,
              apiariesVisited: 2,
              hivesHarvested: 10,
              honeyCollectedKg: 12,
              averageSupersPerHive: 2,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Apiários visitados'), findsOneWidget);
      expect(find.text('Colmeias trabalhadas'), findsOneWidget);
      expect(find.text('Mel colhido'), findsOneWidget);
      expect(find.text('Média alças/colmeia'), findsOneWidget);
      expect(
        find.text('Todos os apiários planeados foram visitados'),
        findsOneWidget,
      );
    });

    testWidgets('renders the average-supers-per-hive label in English when the '
        'locale is en, not the Portuguese prototype wording (#382)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildSection(
          journeyId: 'j1',
          stats: Stream.value(
            _sampleStats(
              apiariesPlanned: 2,
              apiariesVisited: 2,
              hivesHarvested: 10,
              honeyCollectedKg: 12,
              averageSupersPerHive: 2,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Avg. supers/hive'), findsOneWidget);
      expect(find.text('Média alças/colmeia'), findsNothing);
    });

    // #342, FR-JO-3, D-2: the harvest-only aggregation tiles (hives
    // harvested, honey collected, média alças/colmeia) must appear ONLY on a
    // harvest journey; every journey type still shows the universal progress
    // metrics (apiaries visited + how much is still missing, FR-JO-1) and
    // the #391 hives-worked tile.
    const harvestOnlyKeys = [
      Key('journey-stats-hives-harvested'),
      Key('journey-stats-honey-collected'),
      Key('journey-stats-average-supers'),
    ];

    testWidgets('harvest journey shows the harvest-only aggregation tiles', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildSection(
          journeyId: 'j-harvest',
          mainActivityType: activityTypeHarvest,
          stats: Stream.value(_sampleStats()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('journey-stats-apiaries-visited')),
        findsOneWidget,
      );
      for (final key in harvestOnlyKeys) {
        expect(find.byKey(key), findsOneWidget);
      }
      expect(find.byKey(const Key('journey-stats-missing')), findsOneWidget);
    });

    for (final type in const [
      activityTypeFeeding,
      activityTypeTreatment,
      activityTypeGeneric,
    ]) {
      testWidgets('$type journey hides the harvest-only aggregation tiles but '
          'still shows the progress metrics', (tester) async {
        await tester.pumpWidget(
          _buildSection(
            journeyId: 'j-$type',
            mainActivityType: type,
            stats: Stream.value(_sampleStats()),
          ),
        );
        await tester.pumpAndSettle();

        // Universal progress metrics remain.
        expect(
          find.byKey(const Key('journey-stats-apiaries-visited')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('journey-stats-missing')), findsOneWidget);

        // No harvest aggregation tiles, and none of their values leak.
        for (final key in harvestOnlyKeys) {
          expect(find.byKey(key), findsNothing);
        }
        expect(find.text('42'), findsNothing);
        expect(find.text('18.5 kg'), findsNothing);
        expect(find.text('1.6'), findsNothing);
      });
    }

    testWidgets('shows an error message when the stats stream errors', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildSection(
          journeyId: 'j-err',
          stats: Stream<JourneyStats>.error(Exception('boom')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('journey-stats-error')), findsOneWidget);
    });
  });

  group('JourneyStatsSection — hives-worked tile (#391)', () {
    for (final type in const [
      activityTypeHarvest,
      activityTypeFeeding,
      activityTypeTreatment,
      activityTypeGeneric,
    ]) {
      testWidgets('$type journey renders the hives-worked tile (universal, '
          'not harvest-gated)', (tester) async {
        await tester.pumpWidget(
          _buildSection(
            journeyId: 'j-$type',
            mainActivityType: type,
            stats: Stream.value(
              _sampleStats(hivesWorked: 12, hivesPlanned: 40),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('journey-stats-hives-worked')),
          findsOneWidget,
        );
        expect(find.text('12/40'), findsOneWidget);
      });
    }

    testWidgets('shows "—" for the planned denominator (not a fake 0) when '
        'hivesPlanned is null', (tester) async {
      await tester.pumpWidget(
        _buildSection(
          journeyId: 'j1',
          stats: Stream.value(_sampleStats(hivesWorked: 5, hivesPlanned: null)),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('5/—'), findsOneWidget);
    });
  });

  group('JourneyStatsSection — "More stats" button (#391)', () {
    testWidgets('is always present, regardless of journey type', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildSection(
          journeyId: 'j1',
          mainActivityType: activityTypeGeneric,
          stats: Stream.value(_sampleStats()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('journey-stats-more-button')),
        findsOneWidget,
      );
    });

    testWidgets('navigates to /journeys/:id/stats when tapped', (tester) async {
      await tester.pumpWidget(
        _buildSectionWithRouter(
          journeyId: 'j1',
          stats: Stream.value(_sampleStats()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('journey-stats-more-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('journey-stats-detail-placeholder')),
        findsOneWidget,
      );
      expect(find.text('stats-screen-j1'), findsOneWidget);
    });
  });
}
