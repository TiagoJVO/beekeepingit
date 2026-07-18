import 'package:beekeepingit_client/features/journeys/journey_stats.dart';
import 'package:beekeepingit_client/features/journeys/journey_stats_section.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Widget tests for the #49 minimal display surface (FR-JO-1) — a lightweight
/// `MaterialApp` + `journeyStatsProvider` override, mirroring
/// core/l10n/locale_formatting_test.dart's own "wrap the widget directly,
/// skip the full app shell" convention rather than
/// apiary_activities_section_test.dart's (that section is already wired
/// into a real screen; this one isn't yet — #48 does that wiring).
Widget _buildSection({
  required String journeyId,
  required Stream<JourneyStats> stats,
  Locale locale = const Locale('en'),
}) {
  return ProviderScope(
    overrides: [journeyStatsProvider.overrideWith((ref, id) => stats)],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: JourneyStatsSection(journeyId: journeyId)),
    ),
  );
}

void main() {
  group('JourneyStatsSection (#49, FR-JO-1)', () {
    testWidgets('renders every stat card with its computed value', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildSection(
          journeyId: 'j1',
          stats: Stream.value(
            const JourneyStats(
              apiariesPlanned: 5,
              apiariesVisited: 3,
              hivesHarvested: 42,
              honeyCollectedKg: 18.5,
              averageSupersPerHive: 1.6,
            ),
          ),
        ),
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
            const JourneyStats(
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
            const JourneyStats(
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
}
