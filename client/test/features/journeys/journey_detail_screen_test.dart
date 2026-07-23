import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/history/history_repository.dart';
import 'package:beekeepingit_client/features/journeys/journey_stats.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/a11y_matchers.dart';

/// Widget tests for the #48 journey detail page (FR-JO-3, D-21): apiaries
/// visited/planned, per-apiary activities, the embedded #49 stats section,
/// and offline rendering — mirroring activity_detail_screen_test.dart's/
/// journey_stats_section_test.dart's own house style: hand-written fakes,
/// full `ProviderScope` overrides (every provider this page — and everything
/// it embeds — reads is overridden here with a plain `Stream.value(...)`, no
/// network/PowerSync involved anywhere in this file, which is itself the
/// #48 AC's "renders offline from the local store" guarantee made concrete),
/// `Key('...')` naming.

/// A no-op [LocalStoreEngine] — [_FakeJourneysRepository] overrides every
/// method the edit-route push touches, mirroring journey_form_screen_test.
/// dart's identical fixture.
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

/// Resolves getById() immediately so navigating into the edit route (via the
/// detail page's own edit FAB) never hangs on the real
/// journeysRepositoryProvider chain — mirrors journeys_list_screen_test.
/// dart's/journey_form_screen_test.dart's own `_FakeJourneysRepository`.
class _FakeJourneysRepository extends JourneysRepository {
  _FakeJourneysRepository(this.existing) : super(_NoopLocalStore());
  final Journey? existing;

  @override
  Future<Journey?> getById(String id) async => existing;
}

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

const _journey = Journey(
  id: 'j1',
  name: 'Colheita de Primavera',
  mainActivityType: 'harvest',
  status: journeyStatusOpen,
);

Activity _activity({
  required String id,
  required String apiaryId,
  String type = 'harvest',
  String occurredAt = '2026-06-01',
}) => Activity(
  id: id,
  apiaryId: apiaryId,
  type: type,
  occurredAt: occurredAt,
  attributes: const {},
  journeyId: 'j1',
);

Widget _buildApp({
  Journey? journey = _journey,
  List<Apiary> apiaries = const [
    Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4),
    Apiary(id: 'a2', name: 'Serra Norte', hiveCount: 2),
    Apiary(id: 'a3', name: 'Vale Fundo', hiveCount: 1),
  ],
  List<String> plannedApiaryIds = const ['a1', 'a2'],
  List<Activity> activities = const [],
  JourneyStats stats = JourneyStats.empty,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      // Navigating straight to the nested `/journeys/:id` route still builds
      // the Journeys tab's own root page onto that branch's stack (mirrors
      // journey_form_screen_test.dart's identical note on `.../:id/edit`) —
      // overridden so it resolves immediately rather than hanging.
      journeysStreamProvider.overrideWith(
        (ref) => Stream.value(journey == null ? const <Journey>[] : [journey]),
      ),
      journeyByIdProvider.overrideWith((ref, id) => Stream.value(journey)),
      journeyStatsProvider.overrideWith((ref, id) => Stream.value(stats)),
      activitiesByJourneyProvider.overrideWith(
        (ref, id) => Stream.value(activities),
      ),
      journeyPlanApiariesByJourneyProvider.overrideWith(
        (ref) => Stream.value({'j1': plannedApiaryIds}),
      ),
      journeysRepositoryProvider.overrideWith(
        (ref) async => _FakeJourneysRepository(journey),
      ),
      // The #384 journey-scoped activity route renders the same
      // ActivityDetailScreen the apiaries branch does, which watches this
      // per-id family provider directly (not activitiesByJourneyProvider,
      // already overridden above) and embeds HistorySection (#60) — both
      // left un-overridden would hang on their real, never-resolving
      // repository chains in this offline test environment. Mirrors
      // activity_detail_screen_test.dart's own identical overrides.
      activityByIdProvider.overrideWith(
        (ref, id) => Stream.value(
          activities.cast<Activity?>().firstWhere(
            (a) => a!.id == id,
            orElse: () => null,
          ),
        ),
      ),
      entityHistoryProvider.overrideWith(
        (ref, target) => Stream.value(const <HistoryEntry>[]),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openDetail(
  WidgetTester tester, {
  Journey? journey = _journey,
  List<Apiary> apiaries = const [
    Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4),
    Apiary(id: 'a2', name: 'Serra Norte', hiveCount: 2),
    Apiary(id: 'a3', name: 'Vale Fundo', hiveCount: 1),
  ],
  List<String> plannedApiaryIds = const ['a1', 'a2'],
  List<Activity> activities = const [],
  JourneyStats stats = JourneyStats.empty,
}) async {
  await tester.pumpWidget(
    _buildApp(
      journey: journey,
      apiaries: apiaries,
      plannedApiaryIds: plannedApiaryIds,
      activities: activities,
      stats: stats,
    ),
  );
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(AppShell)));
  router.go('/journeys/j1');
  await tester.pumpAndSettle();
}

void main() {
  group('JourneyDetailScreen (#48, FR-JO-3, D-21)', () {
    testWidgets('renders the journey header and embeds the #49 stats section', (
      tester,
    ) async {
      await _openDetail(
        tester,
        stats: const JourneyStats(
          apiariesPlanned: 2,
          apiariesVisited: 1,
          hivesHarvested: 6,
          honeyCollectedKg: 9,
          averageSupersPerHive: 2,
          hivesWorked: 6,
          hivesPlanned: 20,
        ),
      );

      expect(find.byKey(const Key('journey-detail-header')), findsOneWidget);
      expect(find.text('Colheita de Primavera'), findsOneWidget);
      expect(find.text('Honey harvest'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      expect(find.byKey(const Key('journey-stats-section')), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
    });

    testWidgets(
      'lists a visited apiary with its attributed activities, and keeps a '
      'planned-but-not-yet-visited apiary visually distinct (#48 AC: '
      'planned vs. actual)',
      (tester) async {
        await _openDetail(
          tester,
          plannedApiaryIds: const ['a1', 'a2'],
          activities: [_activity(id: 'act1', apiaryId: 'a1')],
        );

        // a1: visited — its own activity renders via the shared
        // ActivityListView, and the visited badge shows.
        expect(
          find.byKey(const Key('journey-detail-apiary-a1')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('activity-act1')), findsOneWidget);
        expect(find.text('Visited'), findsOneWidget);
        expect(
          find.byKey(const Key('journey-detail-apiary-not-visited-a1')),
          findsNothing,
        );

        // a2: planned only — no activity list, the "not visited yet"
        // placeholder shows instead, and no visited badge for it.
        expect(
          find.byKey(const Key('journey-detail-apiary-a2')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('journey-detail-apiary-not-visited-a2')),
          findsOneWidget,
        );
        expect(find.text('Planned'), findsOneWidget);
      },
    );

    testWidgets(
      'shows an apiary as visited even once it has fallen out of the plan '
      '(D-21: activity attribution is by the stored journey_id, not a live '
      're-match against the current plan)',
      (tester) async {
        await _openDetail(
          tester,
          plannedApiaryIds: const ['a1'],
          activities: [
            _activity(id: 'act1', apiaryId: 'a1'),
            _activity(id: 'act2', apiaryId: 'a3'),
          ],
        );

        expect(
          find.byKey(const Key('journey-detail-apiary-a3')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('activity-act2')), findsOneWidget);
        // Both a1 and a3 are visited, a2 was never planned nor visited so it
        // has no card at all.
        expect(find.text('Visited'), findsNWidgets(2));
        expect(find.byKey(const Key('journey-detail-apiary-a2')), findsNothing);
      },
    );

    testWidgets(
      'shows a placeholder, never a raw internal id, for an apiary that '
      "can't be resolved against the currently-loaded apiaries list",
      (tester) async {
        await _openDetail(
          tester,
          apiaries: const [],
          plannedApiaryIds: const ['deleted-apiary'],
        );

        expect(find.text('Unknown apiary'), findsOneWidget);
        expect(find.text('deleted-apiary'), findsNothing);
      },
    );

    testWidgets('shows the empty state when the journey has no plan and no '
        'attributed activities yet', (tester) async {
      await _openDetail(tester, plannedApiaryIds: const []);

      expect(
        find.byKey(const Key('journey-detail-apiaries-empty')),
        findsOneWidget,
      );
    });

    testWidgets(
      'the edit FAB navigates to the existing, pre-filled edit form',
      (tester) async {
        await _openDetail(tester);

        expect(
          find.byKey(const Key('journey-detail-edit-button')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('journey-detail-edit-button')));
        await tester.pumpAndSettle();

        final nameField = tester.widget<TextFormField>(
          find.byKey(const Key('journey-name-field')),
        );
        expect(nameField.controller!.text, 'Colheita de Primavera');
      },
    );

    testWidgets(
      'a deleted/unknown journey bounces back to the journeys list rather '
      'than rendering a blank detail page',
      (tester) async {
        await _openDetail(tester, journey: null);

        expect(find.byKey(const Key('journey-detail-header')), findsNothing);
        // Bounced to the Journeys tab root — its own empty state, since this
        // fixture's journeysStreamProvider override has nothing else in the
        // org either (proves we left the detail route, not merely that its
        // data resolved to null in place).
        expect(
          find.text('No journeys yet. Tap “New journey” to create one.'),
          findsOneWidget,
        );
      },
    );

    group('journey-scoped activity navigation (#384)', () {
      testWidgets(
        'tapping an activity from the journey detail screen stays on the '
        'Journeys tab and its own branch, and the shell back button returns '
        'to the journey rather than the apiary',
        (tester) async {
          await _openDetail(
            tester,
            plannedApiaryIds: const ['a1'],
            activities: [_activity(id: 'act1', apiaryId: 'a1')],
          );

          // The activity tile sits below the fold on this fixture's card
          // layout — a bare tap() resolves to an off-screen coordinate and
          // silently misses (mirrors activity_detail_screen_test.dart's own
          // `_tapDelete` note), so scroll it into view first.
          final activityTile = find.byKey(const Key('activity-act1'));
          await tester.ensureVisible(activityTile);
          await tester.pumpAndSettle();
          await tester.tap(activityTile);
          await tester.pumpAndSettle();

          final router = GoRouter.of(tester.element(find.byType(AppShell)));
          expect(
            router.routeInformationProvider.value.uri.toString(),
            '/journeys/j1/activities/act1?apiaryId=a1',
          );
          expect(
            find.byKey(const Key('activity-detail-header')),
            findsOneWidget,
          );
          // Still the Journeys tab (index 2 in AppShell.tabs), not bounced
          // into the Apiaries branch.
          final nav = tester.widget<NavigationBar>(
            find.byKey(const Key('shell-bottom-nav')),
          );
          expect(nav.selectedIndex, 2);

          await tester.tap(find.byKey(const Key('shell-back-button')));
          await tester.pumpAndSettle();

          // Asserting on .path (not the full uri string): popping the
          // branch's own Navigator leaves the now-current match's own path
          // segments, but go_router carries the popped location's query
          // component along rather than clearing it (a pre-existing
          // framework quirk, not specific to this route) — so the bar can
          // still briefly show a stray `?apiaryId=a1`. Harmless (this screen
          // never reads that param) and orthogonal to the #384 fix itself,
          // which is that Back lands on the journey at all, not the apiary.
          expect(
            router.routeInformationProvider.value.uri.path,
            '/journeys/j1',
          );
          expect(
            find.byKey(const Key('journey-detail-header')),
            findsOneWidget,
          );
        },
      );

      // Regression coverage for the *default* (non-journey) tap path — that
      // the shared _ActivityTile still lands on the apiaries-branch route
      // when `detailLocationBuilder` is unset — already exists end-to-end at
      // activity_detail_screen_test.dart:167 ("tapping a row in the main
      // all-apiaries Activities tab opens the detail"): it taps an activity
      // tile reached via the Activities tab (the same shared tile, unmodified
      // default `detailLocationBuilder`), asserts the detail renders, and
      // asserts the shell back button returns to the *apiary* detail (proof
      // of the apiaries-branch route, not just a URL string). No separate
      // test added here to avoid duplicating that coverage.
    });

    group(
      'accessibility (D-18, docs/design/accessibility-field-ux-checklist.md)',
      () {
        testWidgets('the edit FAB meets the 44x44 minimum tap target', (
          tester,
        ) async {
          await _openDetail(tester);

          expectMinTapTarget(
            tester,
            find.byKey(const Key('journey-detail-edit-button')),
          );
          expectHasSemanticsLabel(
            tester,
            const Key('journey-detail-edit-button'),
          );
        });
      },
    );
  });
}
