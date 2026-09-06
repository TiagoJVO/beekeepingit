import 'dart:async';

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// #634 (FR-UX-2, FR-AC-2): the Activities tab's own quick-add, and the
/// apiary -> type -> fields flow it opens. Boots the REAL app (shell +
/// router) rather than a hand-built MaterialApp, so the FAB wiring, the
/// route and the shell header are all exercised as shipped — the same
/// convention app_shell_test.dart and add_activity_screen_test.dart use.

/// A no-op store: every repository fake below overrides the methods the
/// screens actually call, so the superclass's store is never reached.
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

class _FakeActivitiesRepository extends ActivitiesRepository {
  _FakeActivitiesRepository() : super(_NoopLocalStore());

  final List<String> createdForApiary = [];

  @override
  Future<Activity?> getById(String id) async => null;

  @override
  Future<String> create({
    required String apiaryId,
    required String type,
    required String occurredAt,
    required Map<String, dynamic> attributes,
    String? journeyId,
  }) async {
    createdForApiary.add(apiaryId);
    return 'created-${createdForApiary.length}';
  }
}

class _FakeJourneysRepository extends JourneysRepository {
  _FakeJourneysRepository() : super(_NoopLocalStore());

  @override
  Stream<List<Journey>> watchMatching({
    required String apiaryId,
    required String activityType,
    required String? organizationId,
  }) => Stream.value(const []);

  @override
  Stream<List<Journey>> watchTypeMatchingUnplanned({
    required String apiaryId,
    required String activityType,
    required String? organizationId,
  }) => Stream.value(const []);

  @override
  Future<Journey?> getById(String id) async => null;
}

/// Serves the create-mode `hives_involved` prefill (#424) from the same
/// fixture list the streams use, so it never awaits a real PowerSync chain.
class _FakeApiariesRepository extends ApiariesRepository {
  _FakeApiariesRepository(this._apiaries) : super(_NoopLocalStore());

  final List<Apiary> _apiaries;

  @override
  Future<Apiary?> getById(String id, {required String? organizationId}) async {
    for (final apiary in _apiaries) {
      if (apiary.id == id) return apiary;
    }
    return null;
  }
}

Profile _profileWithLocale(String locale) => Profile(
  id: 'test-user',
  name: 'Test User',
  email: 'test@example.com',
  locale: locale,
  profileComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

class _EnglishProfileController extends ProfileController {
  @override
  Future<Profile> build() async => _profileWithLocale('en');
}

/// The app's UI locale comes from the stored profile locale, so this drives
/// the whole app in European Portuguese (D-34) through the real wiring.
class _PortugueseProfileController extends ProfileController {
  @override
  Future<Profile> build() async => _profileWithLocale('pt');
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

const _twoApiaries = [
  Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
  Apiary(id: 'a2', name: 'Vale Sul', hiveCount: 5),
];

const _soloApiary = Apiary(id: 'solo', name: 'Only One', hiveCount: 2);

Widget _buildApp({
  List<Apiary> apiaries = _twoApiaries,
  List<Activity> activities = const [],
  bool portuguese = false,
  _FakeActivitiesRepository? activitiesRepo,
  // A live, test-driven apiary stream in place of the one-shot [apiaries]
  // value, for the tests that need to push a SECOND emission after the
  // initial pump. [apiaries] still seeds the repository fake either way.
  StreamController<List<Apiary>>? apiariesStream,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith(
        (ref) => apiariesStream?.stream ?? Stream.value(apiaries),
      ),
      apiaryByIdProvider.overrideWith((ref, id) => Stream.value(null)),
      apiariesRepositoryProvider.overrideWith(
        (ref) async => _FakeApiariesRepository(apiaries),
      ),
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      activitiesStreamProvider.overrideWith((ref) => Stream.value(activities)),
      activitiesByApiaryProvider.overrideWith(
        (ref, id) => Stream.value(const <Activity>[]),
      ),
      activitiesRepositoryProvider.overrideWith(
        (ref) async => activitiesRepo ?? _FakeActivitiesRepository(),
      ),
      journeysRepositoryProvider.overrideWith(
        (ref) async => _FakeJourneysRepository(),
      ),
      journeysStreamProvider.overrideWith(
        (ref) => Stream.value(const <Journey>[]),
      ),
      memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
      profileProvider.overrideWith(
        portuguese
            ? _PortugueseProfileController.new
            : _EnglishProfileController.new,
      ),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openActivitiesTab(
  WidgetTester tester, {
  List<Apiary> apiaries = _twoApiaries,
  List<Activity> activities = const [],
  bool portuguese = false,
  _FakeActivitiesRepository? activitiesRepo,
}) async {
  await tester.pumpWidget(
    _buildApp(
      apiaries: apiaries,
      activities: activities,
      portuguese: portuguese,
      activitiesRepo: activitiesRepo,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('shell-tab-activities')));
  await tester.pumpAndSettle();
}

Element _shellElement(WidgetTester tester) =>
    tester.element(find.byKey(const Key('shell-bottom-nav')));

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(_shellElement(tester));

String _location(WidgetTester tester) =>
    GoRouter.of(_shellElement(tester)).state.uri.toString();

int _selectedTabIndex(WidgetTester tester) => tester
    .widget<NavigationBar>(find.byKey(const Key('shell-bottom-nav')))
    .selectedIndex;

void main() {
  group('Activities-tab quick-add (#634, FR-UX-2)', () {
    testWidgets('the Activities tab offers a quick-add control', (
      tester,
    ) async {
      await _openActivitiesTab(tester);

      // One scope action -> the speed dial renders it as a direct honey FAB
      // (actions_speed_dial.dart), so there is no collapsed "Actions" toggle.
      expect(find.byKey(const Key('shell-fab')), findsOneWidget);
      expect(find.byKey(const Key('actions-speed-dial-toggle')), findsNothing);
      expect(
        find.text(_l10n(tester).addActivityAction),
        findsWidgets,
        reason: 'the quick-add is labelled with the add-activity action',
      );
    });

    testWidgets('it asks which apiary before the type and fields', (
      tester,
    ) async {
      await _openActivitiesTab(tester);
      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('new-activity-apiary-list')), findsOneWidget);
      expect(
        find.byKey(const Key('activity-type-field')),
        findsNothing,
        reason: 'the type/fields step comes after the apiary is chosen',
      );

      await tester.tap(find.byKey(const Key('new-activity-apiary-option-a2')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('activity-type-field')), findsOneWidget);
      expect(find.byKey(const Key('new-activity-apiary-list')), findsNothing);
    });

    testWidgets('the apiary step can be searched', (tester) async {
      await _openActivitiesTab(tester);
      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('new-activity-apiary-search-field')),
        'vale',
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('new-activity-apiary-option-a2')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('new-activity-apiary-option-a1')),
        findsNothing,
      );
    });

    testWidgets('with exactly one apiary the picker step is skipped entirely', (
      tester,
    ) async {
      await _openActivitiesTab(tester, apiaries: const [_soloApiary]);
      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('new-activity-apiary-list')), findsNothing);
      expect(find.byKey(const Key('activity-type-field')), findsOneWidget);
    });

    testWidgets('with no apiaries it explains why and offers to create one', (
      tester,
    ) async {
      await _openActivitiesTab(tester, apiaries: const []);
      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('new-activity-no-apiaries')), findsOneWidget);
      expect(find.text(_l10n(tester).newActivityNoApiaries), findsOneWidget);
      expect(find.byKey(const Key('activity-type-field')), findsNothing);

      // Not a dead end: the state's own action opens the apiary form.
      await tester.tap(find.byKey(const Key('new-activity-add-apiary-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('apiary-name-field')), findsOneWidget);
    });

    testWidgets('the chosen apiary is the one the activity is created for', (
      tester,
    ) async {
      // A taller surface so the whole form — including its Save button —
      // fits above the shell's bottom nav; `ensureVisible` alone lands the
      // button a couple of pixels past the default 800x600 viewport.
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final repo = _FakeActivitiesRepository();
      await _openActivitiesTab(tester, activitiesRepo: repo);
      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-activity-apiary-option-a2')));
      await tester.pumpAndSettle();

      // Harvest is the default type; its honey-supers field is required.
      await tester.enterText(
        find.byKey(const Key('activity-honey-supers-field')),
        '3',
      );
      final saveButton = find.byKey(const Key('activity-save-button'));
      await tester.ensureVisible(saveButton);
      await tester.pumpAndSettle();
      await tester.tap(saveButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(repo.createdForApiary, ['a2']);
      // ...and the save lands back on the tab the user started from, not on
      // the apiary detail page in another branch (AddActivityScreen's
      // returnLocation, #634).
      expect(_location(tester), '/activities');
    });

    testWidgets('the form names the apiary the activity will be recorded at', (
      tester,
    ) async {
      await _openActivitiesTab(tester);
      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-activity-apiary-option-a2')));
      await tester.pumpAndSettle();

      // Otherwise every screen after the picker looks identical whichever
      // apiary was tapped, and a mis-tap files the activity against the
      // wrong one with nothing on screen to notice it by.
      expect(
        find.byKey(const Key('new-activity-apiary-banner')),
        findsOneWidget,
      );
      expect(find.text('Vale Sul'), findsWidgets);
    });

    testWidgets(
      'Back unwinds inside the Activities tab, which never switches',
      (tester) async {
        await _openActivitiesTab(tester);
        await tester.tap(find.byKey(const Key('shell-fab')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('new-activity-apiary-option-a2')),
        );
        await tester.pumpAndSettle();
        expect(_location(tester), '/activities/new/a2');
        expect(_selectedTabIndex(tester), 1);

        // Form -> picker -> list, all within the activities branch.
        await tester.tap(find.byKey(const Key('shell-back-button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('new-activity-apiary-list')),
          findsOneWidget,
        );
        expect(_selectedTabIndex(tester), 1);

        await tester.tap(find.byKey(const Key('shell-back-button')));
        await tester.pumpAndSettle();
        expect(_location(tester), '/activities');
        expect(_selectedTabIndex(tester), 1);
      },
    );

    testWidgets('both steps are headed "New activity" in the shell header', (
      tester,
    ) async {
      await _openActivitiesTab(tester);
      final expected = _l10n(tester).newActivityTitle;

      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();
      expect(find.text(expected), findsWidgets);

      await tester.tap(find.byKey(const Key('new-activity-apiary-option-a2')));
      await tester.pumpAndSettle();
      expect(find.text(expected), findsWidgets);
    });

    testWidgets(
      'a second apiary syncing in mid-form does not swap the form for the '
      'picker',
      (tester) async {
        // The single-apiary shortcut renders the form straight off
        // /activities/new. Before #634's latch, the live apiary stream could
        // then rebuild that same route into the picker underneath a
        // half-filled form, discarding it silently.
        final apiaries = StreamController<List<Apiary>>();
        addTearDown(apiaries.close);

        await tester.pumpWidget(
          _buildApp(apiaries: const [_soloApiary], apiariesStream: apiaries),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-tab-activities')));
        await tester.pumpAndSettle();
        apiaries.add(const [_soloApiary]);
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('shell-fab')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('activity-type-field')), findsOneWidget);

        apiaries.add(const [_soloApiary, ..._twoApiaries]);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('activity-type-field')), findsOneWidget);
        expect(find.byKey(const Key('new-activity-apiary-list')), findsNothing);
      },
    );
  });

  group('Activities empty state points at the quick-add (#634 AC3)', () {
    testWidgets('EN describes the action without naming a control label', (
      tester,
    ) async {
      await _openActivitiesTab(tester);
      final l10n = _l10n(tester);

      expect(
        l10n.activitiesEmpty,
        'No activities yet. Record your first activity with the button below.',
      );
      expect(find.text(l10n.activitiesEmpty), findsOneWidget);
      // #636's lesson: a control's visible label depends on how many actions
      // the scope has (one -> a direct FAB, two+ -> a collapsed "Actions"
      // toggle), so the copy must never hard-name one.
      expect(l10n.activitiesEmpty.contains(l10n.addActivityAction), isFalse);
      expect(l10n.activitiesEmpty.contains(l10n.actionsMenuLabel), isFalse);
    });

    testWidgets('PT describes the action without naming a control label', (
      tester,
    ) async {
      await _openActivitiesTab(tester, portuguese: true);
      final l10n = _l10n(tester);

      expect(
        l10n.activitiesEmpty,
        'Ainda não há atividades. Registe a sua primeira atividade com o botão abaixo.',
      );
      expect(find.text(l10n.activitiesEmpty), findsOneWidget);
      expect(l10n.activitiesEmpty.contains(l10n.addActivityAction), isFalse);
      expect(l10n.activitiesEmpty.contains(l10n.actionsMenuLabel), isFalse);
    });
  });

  group('the apiary step is localized (NFR-I18N-1, D-34)', () {
    testWidgets('EN', (tester) async {
      await _openActivitiesTab(tester);
      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();
      final l10n = _l10n(tester);

      expect(l10n.newActivityApiaryTitle, 'Which apiary?');
      expect(find.text(l10n.newActivityApiaryTitle), findsWidgets);
      expect(find.text(l10n.newActivityApiaryPrompt), findsOneWidget);
    });

    testWidgets('PT', (tester) async {
      await _openActivitiesTab(tester, portuguese: true);
      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();
      final l10n = _l10n(tester);

      expect(l10n.newActivityApiaryTitle, 'Que apiário?');
      expect(find.text(l10n.newActivityApiaryTitle), findsWidgets);
      expect(find.text(l10n.newActivityApiaryPrompt), findsOneWidget);
    });
  });

  testWidgets('every apiary row is a gloves-friendly tap target (D-18)', (
    tester,
  ) async {
    await _openActivitiesTab(tester);
    await tester.tap(find.byKey(const Key('shell-fab')));
    await tester.pumpAndSettle();

    for (final apiary in _twoApiaries) {
      final size = tester.getSize(
        find.byKey(Key('new-activity-apiary-option-${apiary.id}')),
      );
      expect(size.height, greaterThanOrEqualTo(44.0));
    }
  });
}
