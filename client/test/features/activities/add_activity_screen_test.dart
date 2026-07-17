import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/activities/add_activity_screen.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// A no-op [LocalStoreEngine] — [_FakeActivitiesRepository] overrides every
/// method the form touches, so the superclass's store is never actually
/// used. Mirrors apiary_form_screen_test.dart's identical fixture.
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
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}
  @override
  Future<void> clear() async {}
}

class _CreatedActivity {
  _CreatedActivity(this.apiaryId, this.type, this.occurredAt, this.attributes);
  final String apiaryId;
  final String type;
  final String occurredAt;
  final Map<String, dynamic> attributes;
}

class _UpdatedActivity {
  _UpdatedActivity(this.id, this.type, this.occurredAt, this.attributes);
  final String id;
  final String type;
  final String occurredAt;
  final Map<String, dynamic> attributes;
}

/// Records `create()`/`update()`/`delete()` calls so the save/edit/delete
/// paths can be asserted without a real PowerSync backend, mirroring
/// apiary_form_screen_test.dart's `_FakeApiariesRepository` — including its
/// `throwOn*` flags (HIGH-finding precedent: a test drives a failing
/// update/delete/getById without a real backend to prove the form catches
/// the error and resets `_busy` rather than hanging or crashing).
class _FakeActivitiesRepository extends ActivitiesRepository {
  _FakeActivitiesRepository({
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
  final Activity? existing;

  final List<_CreatedActivity> created = [];
  final List<_UpdatedActivity> updated = [];
  bool deleteCalled = false;

  @override
  Future<Activity?> getById(String id) async {
    if (throwOnGetById) throw Exception('boom-load');
    return existing;
  }

  @override
  Future<String> create({
    required String apiaryId,
    required String type,
    required String occurredAt,
    required Map<String, dynamic> attributes,
  }) async {
    if (throwOnCreate) throw Exception('boom-create');
    created.add(_CreatedActivity(apiaryId, type, occurredAt, attributes));
    return 'fake-${created.length - 1}';
  }

  @override
  Future<void> update(
    String id, {
    required String type,
    required String occurredAt,
    required Map<String, dynamic> attributes,
  }) async {
    if (throwOnUpdate) throw Exception('boom-update');
    updated.add(_UpdatedActivity(id, type, occurredAt, attributes));
  }

  @override
  Future<void> delete(String id) async {
    if (throwOnDelete) throw Exception('boom-delete');
    deleteCalled = true;
  }
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

const _apiary = Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4);

Widget _buildApp({required _FakeActivitiesRepository repo}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value([_apiary])),
      apiaryByIdProvider.overrideWith((ref, id) => Stream.value(_apiary)),
      // The detail screen's activities section (#42) — overridden with an
      // empty stream so navigating there doesn't hang on the real
      // (never-resolving here) activitiesRepositoryProvider chain and its
      // ActivityListView loading spinner.
      activitiesByApiaryProvider.overrideWith(
        (ref, id) => Stream.value(const <Activity>[]),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      activitiesRepositoryProvider.overrideWith((ref) async => repo),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openAddActivityForm(WidgetTester tester) async {
  await tester.pumpWidget(_buildApp(repo: _FakeActivitiesRepository()));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('apiary-a1')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('apiary-detail-add-activity-button')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the apiary detail page has an add-activity entry point (#39, FR-AC-2)',
    (tester) async {
      await tester.pumpWidget(_buildApp(repo: _FakeActivitiesRepository()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('apiary-detail-add-activity-button')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('apiary-detail-add-activity-button')),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('activity-type-field')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  group(
    'adaptive attribute form (#39 AC: the form adapts to the selected type)',
    () {
      testWidgets('harvest shows its own fields, not feeding/treatment ones', (
        tester,
      ) async {
        await _openAddActivityForm(tester);

        // Harvest is the default selection — its fields render immediately.
        expect(
          find.byKey(const Key('activity-honey-supers-field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('activity-honey-kg-field')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('activity-hives-involved-field')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('activity-notes-field')), findsOneWidget);
        // Feeding/treatment-only fields must NOT show.
        expect(find.byKey(const Key('activity-feed-type-field')), findsNothing);
        expect(
          find.byKey(const Key('activity-treatment-context-field')),
          findsNothing,
        );
      });

      testWidgets(
        'switching to feeding swaps in feed_type/feed_amount, drops harvest fields',
        (tester) async {
          await _openAddActivityForm(tester);

          await tester.tap(find.byKey(const Key('activity-type-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Feeding').last);
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('activity-feed-type-field')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('activity-feed-amount-field')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('activity-honey-supers-field')),
            findsNothing,
          );
          // notes and hives_involved are shared across types.
          expect(find.byKey(const Key('activity-notes-field')), findsOneWidget);
          expect(
            find.byKey(const Key('activity-hives-involved-field')),
            findsOneWidget,
          );
        },
      );

      testWidgets('switching to generic shows only the notes field', (
        tester,
      ) async {
        await _openAddActivityForm(tester);

        await tester.tap(find.byKey(const Key('activity-type-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Generic').last);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('activity-notes-field')), findsOneWidget);
        expect(
          find.byKey(const Key('activity-honey-supers-field')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('activity-hives-involved-field')),
          findsNothing,
        );
      });

      testWidgets(
        'treatment only shows the disease field once a disease-tied context is chosen '
        '(conditional requirement, D-19)',
        (tester) async {
          await _openAddActivityForm(tester);

          await tester.tap(find.byKey(const Key('activity-type-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Treatment').last);
          await tester.pumpAndSettle();

          expect(find.byKey(const Key('activity-disease-field')), findsNothing);

          await tester.tap(
            find.byKey(const Key('activity-treatment-context-field')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Specific disease/condition').last);
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('activity-disease-field')),
            findsOneWidget,
          );
        },
      );
    },
  );

  group('required-field validation before save (#39 AC)', () {
    testWidgets(
      'saving a harvest without the required honey_supers is genuinely blocked '
      '(Form.validate() returns false), nothing is created, no navigation',
      (tester) async {
        // Tall viewport + ensureVisible so the Save tap actually lands on the
        // button and runs _save() — the previous version tapped an off-screen
        // button (viewport 800x600, button at y=671), so _save() never ran and
        // the assertion was a false positive against a cosmetic error string.
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeActivitiesRepository();
        await tester.pumpWidget(_buildApp(repo: repo));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        // Before submission, no validation error is shown (validators only
        // run on validate()/user interaction — this proves the "This field is
        // required" assertion below can't be a pre-existing cosmetic string).
        expect(find.text('This field is required'), findsNothing);

        // Harvest is already selected; honey_supers (required) is left empty.
        final saveButton = find.byKey(const Key('activity-save-button'));
        await tester.ensureVisible(saveButton);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        // Genuinely blocked: nothing queued, the form did NOT navigate away
        // (Save button still present), and the required-field error now shows.
        expect(repo.created, isEmpty);
        expect(find.byKey(const Key('activity-save-button')), findsOneWidget);
        expect(find.text('This field is required'), findsOneWidget);
      },
    );

    testWidgets(
      'a required dropdown (feeding feed_type) left unselected also blocks save',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeActivitiesRepository();
        await tester.pumpWidget(_buildApp(repo: repo));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        // Switch to feeding — feed_type + feed_amount are both required and
        // both left empty.
        await tester.tap(find.byKey(const Key('activity-type-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Feeding').last);
        await tester.pumpAndSettle();

        final saveButton = find.byKey(const Key('activity-save-button'));
        await tester.ensureVisible(saveButton);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(repo.created, isEmpty);
        expect(find.byKey(const Key('activity-save-button')), findsOneWidget);
        // At least one required-field error is shown (feed_type/feed_amount).
        expect(find.text('This field is required'), findsWidgets);
      },
    );

    testWidgets(
      'a valid harvest saves successfully with the typed attributes',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeActivitiesRepository();
        await tester.pumpWidget(_buildApp(repo: repo));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('activity-honey-supers-field')),
          '4',
        );
        final saveButton = find.byKey(const Key('activity-save-button'));
        await tester.ensureVisible(saveButton);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(repo.created, hasLength(1));
        expect(repo.created.single.apiaryId, 'a1');
        expect(repo.created.single.type, 'harvest');
        expect(repo.created.single.attributes['honey_supers'], 4);
        // Navigated away.
        expect(find.byKey(const Key('activity-save-button')), findsNothing);
      },
    );

    testWidgets(
      'a failing create() keeps the form open and shows an error, not an indefinite spinner',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeActivitiesRepository(throwOnCreate: true);
        await tester.pumpWidget(_buildApp(repo: repo));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('activity-honey-supers-field')),
          '4',
        );
        await tester.tap(find.byKey(const Key('activity-save-button')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const Key('activity-save-button')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.textContaining("Couldn't save the activity"),
          findsOneWidget,
        );
      },
    );
  });

  // --- Edit (#40, FR-AC-3) ---

  const existingHarvest = Activity(
    id: 'act1',
    apiaryId: 'a1',
    type: 'harvest',
    occurredAt: '2026-06-01',
    attributes: {'honey_supers': 5, 'honey_kg': 15.0, 'hives_involved': 3},
  );

  /// Navigates straight to the edit route (there is no list screen yet to
  /// tap into, #42/#43's scope) via the router itself — mirrors
  /// apiary_map_screen_test.dart's own `GoRouter.of(tester.element(find
  /// .byType(AppShell)))` pattern for asserting/driving navigation directly.
  Future<void> goToEditForm(
    WidgetTester tester,
    _FakeActivitiesRepository repo,
  ) async {
    await tester.pumpWidget(_buildApp(repo: repo));
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/apiaries/a1/activities/act1/edit');
    await tester.pumpAndSettle();
  }

  group('edit mode (#40, FR-AC-3)', () {
    testWidgets(
      'pre-fills the form with the activity\'s current type/date/attributes',
      (tester) async {
        final repo = _FakeActivitiesRepository(existing: existingHarvest);
        await goToEditForm(tester, repo);

        expect(find.byKey(const Key('activity-type-field')), findsOneWidget);
        expect(find.text('Honey harvest'), findsOneWidget);
        final honeySupersField = tester.widget<TextFormField>(
          find.byKey(const Key('activity-honey-supers-field')),
        );
        expect(honeySupersField.controller!.text, '5');
        final honeyKgField = tester.widget<TextFormField>(
          find.byKey(const Key('activity-honey-kg-field')),
        );
        expect(honeyKgField.controller!.text, '15');
        // A delete affordance is present in edit mode.
        expect(find.byKey(const Key('activity-delete-button')), findsOneWidget);
      },
    );

    testWidgets(
      'clearing the required honey_supers on edit genuinely blocks save '
      '(same wired validators as #39, not a cosmetic errorText)',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeActivitiesRepository(existing: existingHarvest);
        await goToEditForm(tester, repo);

        await tester.enterText(
          find.byKey(const Key('activity-honey-supers-field')),
          '',
        );
        final saveButton = find.byKey(const Key('activity-save-button'));
        await tester.ensureVisible(saveButton);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(repo.updated, isEmpty);
        expect(find.byKey(const Key('activity-save-button')), findsOneWidget);
        expect(find.text('This field is required'), findsOneWidget);
      },
    );

    testWidgets('a valid edit calls update(), not create(), with the new values', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeActivitiesRepository(existing: existingHarvest);
      await goToEditForm(tester, repo);

      await tester.enterText(
        find.byKey(const Key('activity-honey-supers-field')),
        '9',
      );
      final saveButton = find.byKey(const Key('activity-save-button'));
      await tester.ensureVisible(saveButton);
      await tester.pumpAndSettle();
      await tester.tap(saveButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(repo.created, isEmpty);
      expect(repo.updated, hasLength(1));
      expect(repo.updated.single.id, 'act1');
      expect(repo.updated.single.attributes['honey_supers'], 9);
      // Navigated away.
      expect(find.byKey(const Key('activity-save-button')), findsNothing);
    });

    testWidgets(
      'a failing load resets busy and shows an error, not an indefinite spinner',
      (tester) async {
        final repo = _FakeActivitiesRepository(throwOnGetById: true);
        await goToEditForm(tester, repo);

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.textContaining("Couldn't load the activity"),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'a failing update() keeps the form open and shows an error, not an indefinite spinner',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeActivitiesRepository(
          existing: existingHarvest,
          throwOnUpdate: true,
        );
        await goToEditForm(tester, repo);

        final saveButton = find.byKey(const Key('activity-save-button'));
        await tester.ensureVisible(saveButton);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const Key('activity-save-button')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.textContaining("Couldn't save the activity"),
          findsOneWidget,
        );
      },
    );
  });

  // --- Delete (#41, FR-AC-4) ---

  group('delete (#41, FR-AC-4)', () {
    testWidgets(
      'tapping delete opens a confirmation dialog; cancel is a no-op',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeActivitiesRepository(existing: existingHarvest);
        await goToEditForm(tester, repo);

        final deleteButton = find.byKey(const Key('activity-delete-button'));
        await tester.ensureVisible(deleteButton);
        await tester.pumpAndSettle();
        await tester.tap(deleteButton);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('activity-delete-confirm-dialog')),
          findsOneWidget,
        );
        expect(find.text('Delete activity?'), findsOneWidget);

        await tester.tap(find.byKey(const Key('activity-delete-confirm-cancel')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('activity-delete-confirm-dialog')),
          findsNothing,
        );
        expect(repo.deleteCalled, isFalse);
        // Cancel is a no-op: the edit form is still showing, not navigated away.
        expect(find.byKey(const Key('activity-save-button')), findsOneWidget);
      },
    );

    testWidgets('confirming delete calls delete() and navigates away', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeActivitiesRepository(existing: existingHarvest);
      await goToEditForm(tester, repo);

      final deleteButton = find.byKey(const Key('activity-delete-button'));
      await tester.ensureVisible(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('activity-delete-confirm-delete')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));

      expect(repo.deleteCalled, isTrue);
      expect(find.byKey(const Key('activity-save-button')), findsNothing);
    });

    testWidgets(
      'a failing delete() keeps the form open and shows an error, not an indefinite spinner',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final repo = _FakeActivitiesRepository(
          existing: existingHarvest,
          throwOnDelete: true,
        );
        await goToEditForm(tester, repo);

        final deleteButton = find.byKey(const Key('activity-delete-button'));
        await tester.ensureVisible(deleteButton);
        await tester.pumpAndSettle();
        await tester.tap(deleteButton);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('activity-delete-confirm-delete')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const Key('activity-delete-button')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.textContaining("Couldn't delete the activity"),
          findsOneWidget,
        );
      },
    );
  });

  group('DeleteActivityConfirmDialog (#41)', () {
    // Pumps just the dialog (via showDialog, matching how the real edit form
    // opens it) behind a minimal MaterialApp/l10n host — no repository/
    // PowerSync dependency, mirroring apiary_form_screen_test.dart's own
    // DeleteApiaryConfirmDialog group.
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
                  builder: (_) => const DeleteActivityConfirmDialog(),
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

    testWidgets('confirm pops true and dismisses the dialog', (tester) async {
      await tester.pumpWidget(hostApp());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('activity-delete-confirm-delete')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('activity-delete-confirm-dialog')),
        findsNothing,
      );
      expect(find.text('result: true'), findsOneWidget);
    });

    testWidgets(
      'cancel pops false, dismisses the dialog, and is a no-op (#41 AC)',
      (tester) async {
        await tester.pumpWidget(hostApp());
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('activity-delete-confirm-cancel')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('activity-delete-confirm-dialog')),
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

        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('activity-delete-confirm-dialog')),
          findsNothing,
        );
        expect(find.text('result: null'), findsOneWidget);
      },
    );

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
                    builder: (_) => const DeleteActivityConfirmDialog(),
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

      expect(find.text('Eliminar atividade?'), findsOneWidget);
    });
  });
}
