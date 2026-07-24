import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/activities/add_activity_screen.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:beekeepingit_client/theming/app_theme.dart';
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
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => const [];
  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}
  @override
  Future<void> clear() async {}
}

class _CreatedActivity {
  _CreatedActivity(
    this.apiaryId,
    this.type,
    this.occurredAt,
    this.attributes, [
    this.journeyId,
  ]);
  final String apiaryId;
  final String type;
  final String occurredAt;
  final Map<String, dynamic> attributes;
  final String? journeyId;
}

class _UpdatedActivity {
  _UpdatedActivity(
    this.id,
    this.type,
    this.occurredAt,
    this.attributes,
    this.journeyId,
  );
  final String id;
  final String type;
  final String occurredAt;
  final Map<String, dynamic> attributes;
  final String? journeyId;
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
    String? journeyId,
  }) async {
    if (throwOnCreate) throw Exception('boom-create');
    created.add(
      _CreatedActivity(apiaryId, type, occurredAt, attributes, journeyId),
    );
    return 'fake-${created.length - 1}';
  }

  @override
  Future<void> update(
    String id, {
    required String type,
    required String occurredAt,
    required Map<String, dynamic> attributes,
    required String? journeyId,
  }) async {
    if (throwOnUpdate) throw Exception('boom-update');
    updated.add(_UpdatedActivity(id, type, occurredAt, attributes, journeyId));
  }

  @override
  Future<void> delete(String id) async {
    if (throwOnDelete) throw Exception('boom-delete');
    deleteCalled = true;
  }
}

class _CreatedJourney {
  _CreatedJourney(
    this.name,
    this.mainActivityType,
    this.apiaryIds, [
    this.defaultAttributes = const {},
  ]);
  final String name;
  final String mainActivityType;
  final List<String> apiaryIds;
  final Map<String, dynamic> defaultAttributes;
}

/// A [JourneysRepository] fake for the #46 journey-picker section on the
/// add-activity form — mirrors `_FakeActivitiesRepository`'s own
/// record-and-return convention. [matches] is the CANNED candidate set
/// [watchMatching] returns regardless of the apiaryId/activityType/
/// organizationId it's called with — the real SQL-level apiary+type
/// filtering is covered by journeys_repository_test.dart's own
/// `watchMatching` tests; this fake only needs to drive the picker's
/// behavior (auto-select/deselect/switch/closed-confirm) given a fixed
/// candidate list, same as journey_form_screen_test.dart's
/// `_FakeJourneysRepository` fakes create/update/close/delete without
/// re-deriving any real persistence.
class _FakeJourneysRepository extends JourneysRepository {
  _FakeJourneysRepository({
    this.matches = const [],
    this.throwOnCreate = false,
    Map<String, Journey>? journeysById,
  }) : journeysById = journeysById ?? {for (final j in matches) j.id: j},
       super(_NoopLocalStore());

  final List<Journey> matches;
  final bool throwOnCreate;
  final Map<String, Journey> journeysById;

  final List<_CreatedJourney> created = [];

  @override
  Stream<List<Journey>> watchMatching({
    required String apiaryId,
    required String activityType,
    required String? organizationId,
  }) => Stream.value(matches);

  @override
  Future<Journey?> getById(String id) async => journeysById[id];

  @override
  Future<String> create({
    required String name,
    required String mainActivityType,
    required List<String> apiaryIds,
    Map<String, dynamic> defaultAttributes = const {},
  }) async {
    if (throwOnCreate) throw Exception('boom-journey-create');
    created.add(
      _CreatedJourney(name, mainActivityType, apiaryIds, defaultAttributes),
    );
    return 'new-journey-${created.length - 1}';
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

/// Returns a fixed apiary from [getById] so the #424 create-mode
/// `hives_involved` prefill can read a hive count without a real PowerSync
/// backend — mirrors `_FakeActivitiesRepository`'s record-and-return
/// convention, including its `throwOnGetById` precedent for driving the
/// "lookup fails, form must stay usable" path. Every other method is
/// inherited untouched (the form only calls [getById]). A null [_apiary]
/// stands in for a since-deleted apiary.
class _FakeApiariesRepository extends ApiariesRepository {
  _FakeApiariesRepository(this._apiary, {this.throwOnGetById = false})
    : super(_NoopLocalStore());

  final Apiary? _apiary;
  final bool throwOnGetById;

  @override
  Future<Apiary?> getById(String id) async {
    if (throwOnGetById) throw Exception('boom-apiary-load');
    return _apiary;
  }
}

Widget _buildApp({
  required _FakeActivitiesRepository repo,
  _FakeJourneysRepository? journeysRepo,
  Apiary apiary = _apiary,
  _FakeApiariesRepository? apiariesRepo,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value([apiary])),
      apiaryByIdProvider.overrideWith((ref, id) => Stream.value(apiary)),
      // #424: the create-mode prefill reads the apiary's hive count via
      // apiariesRepositoryProvider.getById — override it (default: the same
      // fixture the list/detail streams use) so it never hangs on the real,
      // never-resolving powerSyncProvider chain a bare provider would await.
      // Tests exercising the "lookup fails / apiary gone" paths inject their
      // own fake here (a throwing one, or one returning null).
      apiariesRepositoryProvider.overrideWith(
        (ref) async => apiariesRepo ?? _FakeApiariesRepository(apiary),
      ),
      // The detail screen's activities section (#42) — overridden with an
      // empty stream so navigating there doesn't hang on the real
      // (never-resolving here) activitiesRepositoryProvider chain and its
      // ActivityListView loading spinner.
      activitiesByApiaryProvider.overrideWith(
        (ref, id) => Stream.value(const <Activity>[]),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      // Hermetic member-name roster (#44) — see apiary_detail_screen_test.
      memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      activitiesRepositoryProvider.overrideWith((ref) async => repo),
      // #46: the journey-picker section's journeyMatchesProvider chain —
      // overridden (default: no candidates) so it never hangs on the real,
      // never-resolving _NoopLocalStore-backed watchMatching() a bare
      // JourneysRepository would produce.
      journeysRepositoryProvider.overrideWith(
        (ref) async => journeysRepo ?? _FakeJourneysRepository(),
      ),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openAddActivityForm(
  WidgetTester tester, {
  _FakeJourneysRepository? journeysRepo,
  Apiary apiary = _apiary,
}) async {
  await tester.pumpWidget(
    _buildApp(
      repo: _FakeActivitiesRepository(),
      journeysRepo: journeysRepo,
      apiary: apiary,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('apiary-a1')));
  await tester.pumpAndSettle();
  // Add-activity now lives behind the single "Actions" speed dial (#347) —
  // expand it before tapping the revealed option.
  await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
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

      // The add-activity entry point is one of the "Actions" speed dial's
      // scope options (#347) — revealed once the control is expanded.
      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
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

      testWidgets(
        'the disease field is a dropdown populated from the DGAV-DDO-informed '
        'candidate vocabulary, not free text (#291)',
        (tester) async {
          // Tall viewport: the #46 journey-attachment section pushes the
          // treatment fields further down than the default 800x600 test
          // viewport shows, so tapping the disease field directly (without
          // ensureVisible) needs the same fix the save-button tests already
          // apply elsewhere in this file.
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await _openAddActivityForm(tester);

          await tester.tap(find.byKey(const Key('activity-type-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Treatment').last);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('activity-treatment-context-field')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Specific disease/condition').last);
          await tester.pumpAndSettle();

          final diseaseField = find.byKey(const Key('activity-disease-field'));
          await tester.ensureVisible(diseaseField);
          await tester.pumpAndSettle();
          await tester.tap(diseaseField);
          await tester.pumpAndSettle();

          expect(find.text('Varroose').last, findsOneWidget);
          expect(find.text('Loque americana').last, findsOneWidget);
        },
      );

      testWidgets(
        'harvest shows an optional lot/batch identifier field (#292)',
        (tester) async {
          await _openAddActivityForm(tester);

          expect(
            find.byKey(const Key('activity-lot-batch-field')),
            findsOneWidget,
          );
        },
      );
    },
  );

  group('create-mode hives_involved prefill (#424, EPIC-17, FR-AC-2)', () {
    testWidgets(
      'prefills the shared hives_involved field with the apiary\'s current '
      'hive count, across every type that carries it',
      (tester) async {
        // The fixture apiary has hiveCount 4.
        await _openAddActivityForm(tester);

        // Harvest (the default type) — prefilled from the apiary.
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('activity-hives-involved-field')),
              )
              .controller!
              .text,
          '4',
        );

        // The field is shared, so switching type keeps the prefilled value
        // (feeding/treatment carry the same hives_involved field).
        await tester.tap(find.byKey(const Key('activity-type-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Feeding').last);
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('activity-hives-involved-field')),
              )
              .controller!
              .text,
          '4',
        );
      },
    );

    testWidgets(
      'the prefilled value is editable and the user\'s override is what saves',
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
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        // Prefilled to the apiary's hive count...
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('activity-hives-involved-field')),
              )
              .controller!
              .text,
          '4',
        );

        // ...but the user overrides it, and the override is what is saved.
        await tester.enterText(
          find.byKey(const Key('activity-honey-supers-field')),
          '4',
        );
        await tester.enterText(
          find.byKey(const Key('activity-hives-involved-field')),
          '9',
        );
        final saveButton = find.byKey(const Key('activity-save-button'));
        await tester.ensureVisible(saveButton);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(repo.created, hasLength(1));
        expect(repo.created.single.attributes['hives_involved'], 9);
      },
    );

    testWidgets(
      'an apiary with 0/unknown hives leaves the field empty, not "0"',
      (tester) async {
        await _openAddActivityForm(
          tester,
          apiary: const Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 0),
        );

        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('activity-hives-involved-field')),
              )
              .controller!
              .text,
          isEmpty,
        );
      },
    );

    testWidgets(
      'a failing apiary lookup leaves the field empty and the form usable, '
      'never blocking or crashing',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            repo: _FakeActivitiesRepository(),
            apiariesRepo: _FakeApiariesRepository(
              _apiary,
              throwOnGetById: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        // The form rendered and is usable; the prefill just no-op'd.
        expect(find.byKey(const Key('activity-type-field')), findsOneWidget);
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('activity-hives-involved-field')),
              )
              .controller!
              .text,
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'a since-deleted apiary (getById returns null) leaves the field empty, '
      'no crash',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            repo: _FakeActivitiesRepository(),
            apiariesRepo: _FakeApiariesRepository(null),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('activity-type-field')), findsOneWidget);
        expect(
          tester
              .widget<TextFormField>(
                find.byKey(const Key('activity-hives-involved-field')),
              )
              .controller!
              .text,
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      },
    );
  });

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
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
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
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
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
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
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
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
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

    testWidgets(
      'a detection-only treatment saves successfully with NO treatment_type '
      'selected (#291 AC: a detection can be logged with no treatment applied yet)',
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
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('activity-type-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Treatment').last);
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('activity-treatment-context-field')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Detection only (no treatment yet)').last);
        await tester.pumpAndSettle();

        // treatment_type is deliberately left unselected — only the disease
        // is chosen, proving detection-only doesn't require a treatment.
        await tester.tap(find.byKey(const Key('activity-disease-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Varroose').last);
        await tester.pumpAndSettle();

        final saveButton = find.byKey(const Key('activity-save-button'));
        await tester.ensureVisible(saveButton);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(repo.created, hasLength(1));
        expect(repo.created.single.type, 'treatment');
        expect(
          repo.created.single.attributes['treatment_context'],
          'detection_only',
        );
        expect(repo.created.single.attributes['disease'], 'Varroose');
        expect(
          repo.created.single.attributes.containsKey('treatment_type'),
          isFalse,
        );
        // Navigated away (i.e. genuinely saved, not blocked by validation).
        expect(find.byKey(const Key('activity-save-button')), findsNothing);
      },
    );

    testWidgets(
      'a harvest with an optional lot_batch identifier saves it (#292)',
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
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('activity-honey-supers-field')),
          '4',
        );
        await tester.enterText(
          find.byKey(const Key('activity-lot-batch-field')),
          '2026-07-A1',
        );
        final saveButton = find.byKey(const Key('activity-save-button'));
        await tester.ensureVisible(saveButton);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(repo.created, hasLength(1));
        expect(repo.created.single.attributes['lot_batch'], '2026-07-A1');
      },
    );

    testWidgets(
      'a harvest with lot_batch left empty saves without it (optional, #292)',
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
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
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
        expect(
          repo.created.single.attributes.containsKey('lot_batch'),
          isFalse,
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
    _FakeActivitiesRepository repo, {
    _FakeJourneysRepository? journeysRepo,
  }) async {
    await tester.pumpWidget(_buildApp(repo: repo, journeysRepo: journeysRepo));
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    router.go('/apiaries/a1/activities/act1/edit');
    await tester.pumpAndSettle();
  }

  // --- Journey picker (#46, FR-JO-1, D-21) ---

  const openJourney = Journey(
    id: 'j1',
    name: 'Spring Harvest Round',
    mainActivityType: 'harvest',
    status: journeyStatusOpen,
  );
  const otherOpenJourney = Journey(
    id: 'j2',
    name: 'Second Harvest Round',
    mainActivityType: 'harvest',
    status: journeyStatusOpen,
  );
  const closedJourney = Journey(
    id: 'j3',
    name: 'Last Season',
    mainActivityType: 'harvest',
    status: journeyStatusClosed,
  );

  group('journey picker (#46, FR-JO-1, D-21)', () {
    testWidgets(
      'auto-match HIT: a matching open journey is pre-filled and saved '
      'as journey_id',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final journeysRepo = _FakeJourneysRepository(matches: [openJourney]);
        final repo = _FakeActivitiesRepository();
        await tester.pumpWidget(
          _buildApp(repo: repo, journeysRepo: journeysRepo),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('activity-journey-attachment-name')),
          findsOneWidget,
        );
        expect(find.text('Spring Harvest Round'), findsOneWidget);

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
        expect(repo.created.single.journeyId, 'j1');
      },
    );

    testWidgets('auto-match MISS: no matching journey -> no journey attached, '
        'journey_id is null on save', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = _FakeActivitiesRepository();
      await tester.pumpWidget(_buildApp(repo: repo));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('apiary-detail-add-activity-button')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('activity-journey-attachment-name')),
        findsOneWidget,
      );
      // The default fixture (no journeysRepo override) has no candidates.
      expect(
        find.byKey(const Key('activity-journey-remove-button')),
        findsNothing,
      );

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
      expect(repo.created.single.journeyId, isNull);
    });

    testWidgets(
      'deselect: removing the auto-selected journey saves journey_id as null',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final journeysRepo = _FakeJourneysRepository(matches: [openJourney]);
        final repo = _FakeActivitiesRepository();
        await tester.pumpWidget(
          _buildApp(repo: repo, journeysRepo: journeysRepo),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('activity-journey-remove-button')),
        );
        await tester.pumpAndSettle();

        expect(find.text('No journey attached'), findsOneWidget);
        expect(
          find.byKey(const Key('activity-journey-remove-button')),
          findsNothing,
        );

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
        expect(repo.created.single.journeyId, isNull);
      },
    );

    testWidgets(
      'switch: picking a different matching open journey from the picker '
      'replaces the auto-selected one',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final journeysRepo = _FakeJourneysRepository(
          matches: [openJourney, otherOpenJourney],
        );
        final repo = _FakeActivitiesRepository();
        await tester.pumpWidget(
          _buildApp(repo: repo, journeysRepo: journeysRepo),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        // Initially auto-selected to the first match.
        expect(find.text('Spring Harvest Round'), findsOneWidget);

        await tester.tap(
          find.byKey(const Key('activity-journey-change-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('journey-picker-option-j1')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('journey-picker-option-j2')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('journey-picker-option-j2')));
        await tester.pumpAndSettle();

        expect(find.text('Second Harvest Round'), findsOneWidget);

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
        expect(repo.created.single.journeyId, 'j2');
      },
    );

    testWidgets(
      'closed journeys are hidden by default in the picker, revealed by '
      'the "show hidden journeys" toggle',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final journeysRepo = _FakeJourneysRepository(matches: [closedJourney]);
        await tester.pumpWidget(
          _buildApp(
            repo: _FakeActivitiesRepository(),
            journeysRepo: journeysRepo,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        // No open matches -> auto-match miss even though a closed one exists.
        expect(find.text('No journey attached'), findsOneWidget);

        await tester.tap(
          find.byKey(const Key('activity-journey-change-button')),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('journey-picker-option-j3')), findsNothing);
        expect(
          find.byKey(const Key('journey-picker-show-hidden-toggle')),
          findsOneWidget,
        );

        await tester.tap(
          find.byKey(const Key('journey-picker-show-hidden-toggle')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('journey-picker-option-j3')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'closed-journey confirm: saving against a selected closed journey '
      'shows a confirm dialog; cancel aborts the save',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final journeysRepo = _FakeJourneysRepository(matches: [closedJourney]);
        final repo = _FakeActivitiesRepository();
        await tester.pumpWidget(
          _buildApp(repo: repo, journeysRepo: journeysRepo),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('activity-journey-change-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('journey-picker-show-hidden-toggle')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('journey-picker-option-j3')));
        await tester.pumpAndSettle();

        expect(find.text('Last Season'), findsOneWidget);

        await tester.enterText(
          find.byKey(const Key('activity-honey-supers-field')),
          '4',
        );
        final saveButton = find.byKey(const Key('activity-save-button'));
        await tester.ensureVisible(saveButton);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('activity-closed-journey-confirm-dialog')),
          findsOneWidget,
        );
        expect(repo.created, isEmpty);

        await tester.tap(
          find.byKey(const Key('activity-closed-journey-confirm-cancel')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('activity-closed-journey-confirm-dialog')),
          findsNothing,
        );
        expect(repo.created, isEmpty);
        // Canceling stays on the form, nothing saved.
        expect(find.byKey(const Key('activity-save-button')), findsOneWidget);
      },
    );

    testWidgets(
      'closed-journey confirm: confirming "add anyway" saves the activity '
      'with the closed journey_id',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final journeysRepo = _FakeJourneysRepository(matches: [closedJourney]);
        final repo = _FakeActivitiesRepository();
        await tester.pumpWidget(
          _buildApp(repo: repo, journeysRepo: journeysRepo),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('activity-journey-change-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('journey-picker-show-hidden-toggle')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('journey-picker-option-j3')));
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('activity-honey-supers-field')),
          '4',
        );
        final saveButton = find.byKey(const Key('activity-save-button'));
        await tester.ensureVisible(saveButton);
        await tester.pumpAndSettle();
        await tester.tap(saveButton);
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('activity-closed-journey-confirm-add')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));

        expect(repo.created, hasLength(1));
        expect(repo.created.single.journeyId, 'j3');
      },
    );

    testWidgets(
      'inline create: creating a new journey from the picker attaches it '
      'to the activity being saved',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final journeysRepo = _FakeJourneysRepository();
        final repo = _FakeActivitiesRepository();
        await tester.pumpWidget(
          _buildApp(repo: repo, journeysRepo: journeysRepo),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('activity-journey-change-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('journey-picker-create-new-option')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('journey-quick-create-name-field')),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const Key('journey-quick-create-name-field')),
          'Brand New Journey',
        );
        await tester.tap(
          find.byKey(const Key('journey-quick-create-save-button')),
        );
        await tester.pumpAndSettle();

        // Quick-create sheet closed, back on the activity form, showing the
        // just-created journey attached (name known immediately, before the
        // (fake, static) matches list would ever reflect it).
        expect(find.text('Brand New Journey'), findsOneWidget);
        expect(journeysRepo.created, hasLength(1));
        expect(journeysRepo.created.single.name, 'Brand New Journey');
        expect(journeysRepo.created.single.apiaryIds, ['a1']);
        expect(journeysRepo.created.single.mainActivityType, 'harvest');

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
        expect(repo.created.single.journeyId, 'new-journey-0');
      },
    );

    testWidgets(
      'the "Create a new journey" row uses the accent (tertiary) color, not '
      'the muted secondary color that reads as disabled (#381)',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await _openAddActivityForm(tester);

        await tester.tap(
          find.byKey(const Key('activity-journey-change-button')),
        );
        await tester.pumpAndSettle();

        final scheme = AppTheme.light().colorScheme;
        final createNewOption = find.byKey(
          const Key('journey-picker-create-new-option'),
        );
        final icon = tester.widget<Icon>(
          find.descendant(
            of: createNewOption,
            matching: find.byIcon(Icons.add_circle_outline),
          ),
        );
        expect(icon.color, scheme.tertiary);
        expect(icon.color, isNot(scheme.secondary));

        final title = tester.widget<Text>(
          find.descendant(of: createNewOption, matching: find.byType(Text)),
        );
        expect(title.style?.color, scheme.onSurface);
        expect(title.style?.color, isNot(scheme.secondary));
      },
    );

    testWidgets(
      'inline create: the main activity type is locked to the activity being '
      'registered so a mismatched-type journey cannot be created (#343, '
      'FR-JO-4, D-21)',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final journeysRepo = _FakeJourneysRepository();
        await _openAddActivityForm(tester, journeysRepo: journeysRepo);

        await tester.tap(
          find.byKey(const Key('activity-journey-change-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('journey-picker-create-new-option')),
        );
        await tester.pumpAndSettle();

        // The type field is present, shows the activity's own type, but is
        // locked (disabled) — the user has no way to pick a different type.
        final typeField = tester.widget<DropdownButtonFormField<String>>(
          find.byKey(
            const Key('journey-quick-create-main-activity-type-field'),
          ),
        );
        expect(
          typeField.onChanged,
          isNull,
          reason: 'the main activity type must be locked on inline create',
        );

        // Creating the journey still works and carries the matching type.
        await tester.enterText(
          find.byKey(const Key('journey-quick-create-name-field')),
          'Matched Journey',
        );
        await tester.tap(
          find.byKey(const Key('journey-quick-create-save-button')),
        );
        await tester.pumpAndSettle();

        expect(journeysRepo.created, hasLength(1));
        expect(journeysRepo.created.single.mainActivityType, 'harvest');
      },
    );

    testWidgets('inline create: canceling the quick-create sheet leaves the '
        'attachment unchanged', (tester) async {
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final journeysRepo = _FakeJourneysRepository();
      await _openAddActivityForm(tester, journeysRepo: journeysRepo);

      await tester.tap(find.byKey(const Key('activity-journey-change-button')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('journey-picker-create-new-option')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('journey-quick-create-cancel-button')),
      );
      await tester.pumpAndSettle();

      expect(find.text('No journey attached'), findsOneWidget);
      expect(journeysRepo.created, isEmpty);
    });

    testWidgets(
      'inline create: a failing create() keeps the quick-create sheet open '
      'and shows an error, not an indefinite spinner',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final journeysRepo = _FakeJourneysRepository(throwOnCreate: true);
        await _openAddActivityForm(tester, journeysRepo: journeysRepo);

        await tester.tap(
          find.byKey(const Key('activity-journey-change-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('journey-picker-create-new-option')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('journey-quick-create-name-field')),
          'Doomed Journey',
        );
        await tester.tap(
          find.byKey(const Key('journey-quick-create-save-button')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(journeysRepo.created, isEmpty);
        expect(
          find.byKey(const Key('journey-quick-create-save-button')),
          findsOneWidget,
        );
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(
          find.textContaining("Couldn't save the journey"),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'switching activity type resets an explicit manual selection back to '
      'auto-select (a journey\'s main_activity_type must match, #46 AC)',
      (tester) async {
        // The fake's watchMatching ignores the activityType it's called
        // with (its own doc comment) and always returns the same canned
        // list — this test still meaningfully distinguishes "reset
        // happened" from "reset didn't happen": if the type-change reset
        // were missing, the manually-switched selection (otherOpenJourney)
        // would persist; with the reset, the attachment re-derives via
        // auto-select and lands back on the FIRST match (openJourney).
        final journeysRepo = _FakeJourneysRepository(
          matches: [openJourney, otherOpenJourney],
        );
        await _openAddActivityForm(tester, journeysRepo: journeysRepo);

        expect(find.text('Spring Harvest Round'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('activity-journey-change-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('journey-picker-option-j2')));
        await tester.pumpAndSettle();
        expect(find.text('Second Harvest Round'), findsOneWidget);

        await tester.tap(find.byKey(const Key('activity-type-field')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Generic').last);
        await tester.pumpAndSettle();

        expect(find.text('Second Harvest Round'), findsNothing);
        expect(find.text('Spring Harvest Round'), findsOneWidget);
      },
    );

    group('prefill from journey defaults (#386)', () {
      testWidgets(
        'auto-select: an auto-selected journey\'s defaults fill empty '
        'attribute fields',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final treatmentJourney = const Journey(
            id: 'jt1',
            name: 'Spring Treatment',
            mainActivityType: 'treatment',
            status: journeyStatusOpen,
            defaultAttributes: {
              'treatment_context': 'disease_specific',
              'treatment_type': 'Apivar/amitraz',
              'disease': 'Varroose',
            },
          );
          final journeysRepo = _FakeJourneysRepository(
            matches: [treatmentJourney],
          );
          await _openAddActivityForm(tester, journeysRepo: journeysRepo);

          await tester.tap(find.byKey(const Key('activity-type-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Treatment').last);
          await tester.pumpAndSettle();

          expect(find.text('Specific disease/condition'), findsOneWidget);
          expect(find.text('Apivar/amitraz'), findsOneWidget);
          expect(find.text('Varroose'), findsOneWidget);
        },
      );

      testWidgets(
        'a field the user already set is NOT overwritten by a subsequent '
        'pick (non-clobber rule)',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final journeyWithDefaults = const Journey(
            id: 'jd1',
            name: 'Batch Journey',
            mainActivityType: 'harvest',
            status: journeyStatusOpen,
            defaultAttributes: {'lot_batch': 'LOTE-2026-07'},
          );
          final journeysRepo = _FakeJourneysRepository(
            matches: [journeyWithDefaults],
          );
          await _openAddActivityForm(tester, journeysRepo: journeysRepo);

          // Auto-select already prefilled lot_batch from the default — the
          // user now types over it explicitly.
          expect(
            tester
                .widget<TextFormField>(
                  find.byKey(const Key('activity-lot-batch-field')),
                )
                .controller!
                .text,
            'LOTE-2026-07',
          );
          await tester.enterText(
            find.byKey(const Key('activity-lot-batch-field')),
            'USER-ENTERED',
          );
          await tester.pumpAndSettle();

          // Explicitly re-pick the SAME journey via the picker — exercises
          // the explicit-pick prefill trigger, not just auto-select.
          await tester.tap(
            find.byKey(const Key('activity-journey-change-button')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('journey-picker-option-jd1')));
          await tester.pumpAndSettle();

          expect(
            tester
                .widget<TextFormField>(
                  find.byKey(const Key('activity-lot-batch-field')),
                )
                .controller!
                .text,
            'USER-ENTERED',
            reason: 'a non-empty field must never be clobbered by a default',
          );
        },
      );

      testWidgets(
        'inline create: the quick-created journey\'s defaults prefill '
        'immediately, without waiting for the live query',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          // Empty matches: journeysById stays empty too (built from `matches`
          // at construction, _FakeJourneysRepository's own doc comment) — a
          // getById(newlyCreatedId) call would return null, proving the
          // prefill can't be coming from a re-read of the store; it must be
          // the quick-create sheet's own returned record.
          final journeysRepo = _FakeJourneysRepository();
          await _openAddActivityForm(tester, journeysRepo: journeysRepo);

          await tester.tap(
            find.byKey(const Key('activity-journey-change-button')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('journey-picker-create-new-option')),
          );
          await tester.pumpAndSettle();

          await tester.enterText(
            find.byKey(const Key('journey-quick-create-name-field')),
            'Fresh Harvest Journey',
          );
          await tester.enterText(
            find.byKey(const Key('journey-default-lot-batch-field')),
            'NEWLOT-01',
          );
          await tester.tap(
            find.byKey(const Key('journey-quick-create-save-button')),
          );
          await tester.pumpAndSettle();

          expect(journeysRepo.created.single.defaultAttributes, {
            'lot_batch': 'NEWLOT-01',
          });
          expect(
            tester
                .widget<TextFormField>(
                  find.byKey(const Key('activity-lot-batch-field')),
                )
                .controller!
                .text,
            'NEWLOT-01',
          );
        },
      );

      testWidgets('the occurred_at date is untouched by a prefill', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // InputDecoration renders its OWN label as a Text descendant too
        // (alongside the actual date value), so this filters it out by
        // content rather than assuming a fixed widget count/order.
        String? dateText() {
          final l10n = AppLocalizations.of(
            tester.element(find.byKey(const Key('activity-occurred-at-field'))),
          );
          return tester
              .widgetList<Text>(
                find.descendant(
                  of: find.byKey(const Key('activity-occurred-at-field')),
                  matching: find.byType(Text),
                ),
              )
              .map((t) => t.data)
              .firstWhere(
                (d) => d != null && d != l10n.activityOccurredAtLabel,
              );
        }

        final journeyWithDefaults = const Journey(
          id: 'jd1',
          name: 'Batch Journey',
          mainActivityType: 'harvest',
          status: journeyStatusOpen,
          defaultAttributes: {'lot_batch': 'LOTE-2026-07'},
        );
        final journeysRepo = _FakeJourneysRepository(
          matches: [journeyWithDefaults],
        );
        await _openAddActivityForm(tester, journeysRepo: journeysRepo);
        final beforeDate = dateText();

        // Trigger the explicit-pick prefill path (re-picking the SAME
        // auto-matched journey) within this SAME session/build — #386's
        // prefill runs here.
        await tester.tap(
          find.byKey(const Key('activity-journey-change-button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('journey-picker-option-jd1')));
        await tester.pumpAndSettle();
        final afterDate = dateText();

        expect(afterDate, beforeDate);
      });

      testWidgets(
        'switching activity type then back re-runs prefill for the new '
        'match',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final journeyWithDefaults = const Journey(
            id: 'jd1',
            name: 'Batch Journey',
            mainActivityType: 'harvest',
            status: journeyStatusOpen,
            defaultAttributes: {'lot_batch': 'LOTE-2026-07'},
          );
          final journeysRepo = _FakeJourneysRepository(
            matches: [journeyWithDefaults],
          );
          await _openAddActivityForm(tester, journeysRepo: journeysRepo);

          // Auto-select already prefilled lot_batch — clear it, to prove
          // the NEXT prefill (after the round trip below) is a fresh run,
          // not a leftover value.
          await tester.enterText(
            find.byKey(const Key('activity-lot-batch-field')),
            '',
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('activity-type-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Feeding').last);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('activity-type-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Honey harvest').last);
          await tester.pumpAndSettle();

          expect(
            tester
                .widget<TextFormField>(
                  find.byKey(const Key('activity-lot-batch-field')),
                )
                .controller!
                .text,
            'LOTE-2026-07',
          );
        },
      );
    });
  });

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
        // #424 regression: edit mode loads the activity's OWN stored
        // hives_involved (3), never the apiary's hive count (the fixture's 4)
        // — the create-mode prefill must not leak into the edit path.
        final hivesField = tester.widget<TextFormField>(
          find.byKey(const Key('activity-hives-involved-field')),
        );
        expect(hivesField.controller!.text, '3');
        // A delete affordance is present in edit mode.
        expect(find.byKey(const Key('activity-delete-button')), findsOneWidget);
      },
    );

    testWidgets(
      'editing a Treatment whose stored disease is outside the curated vocab '
      'renders without crashing and shows the legacy value (#306 review)',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        // A Treatment created while `disease` was still free text (before
        // #291 narrowed it to a vocab) — or synced from an older client —
        // whose stored disease isn't in diseaseConditions.
        const legacyTreatment = Activity(
          id: 'act1',
          apiaryId: 'a1',
          type: 'treatment',
          occurredAt: '2026-06-01',
          attributes: {
            'treatment_context': 'disease_specific',
            'treatment_type': 'Apivar/amitraz',
            'disease': 'Some unusual finding',
          },
        );
        final repo = _FakeActivitiesRepository(existing: legacyTreatment);
        await goToEditForm(tester, repo);

        // The disease dropdown renders (no DropdownButtonFormField
        // initialValue-must-be-in-items assertion crash) and the stored
        // out-of-vocab value is visible/kept, not silently dropped.
        expect(find.byKey(const Key('activity-disease-field')), findsOneWidget);
        expect(find.text('Some unusual finding'), findsOneWidget);
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

    testWidgets(
      'a valid edit calls update(), not create(), with the new values',
      (tester) async {
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
      },
    );

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

    group('journey attachment on edit (#387)', () {
      const existingHarvestWithJourney = Activity(
        id: 'act1',
        apiaryId: 'a1',
        type: 'harvest',
        occurredAt: '2026-06-01',
        attributes: {'honey_supers': 5},
        journeyId: 'j1',
      );

      testWidgets(
        'renders the stored journey — NOT an auto-match — even when a '
        'DIFFERENT journey would otherwise be the auto-selected candidate',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final journeysRepo = _FakeJourneysRepository(
            matches: [otherOpenJourney], // deliberately NOT the stored journey
            journeysById: {'j1': openJourney},
          );
          final repo = _FakeActivitiesRepository(
            existing: existingHarvestWithJourney,
          );
          await goToEditForm(tester, repo, journeysRepo: journeysRepo);

          expect(find.text('Spring Harvest Round'), findsOneWidget);
          expect(find.text('Second Harvest Round'), findsNothing);
        },
      );

      testWidgets(
        'picking a different journey shows the relink confirm dialog at '
        'save time; cancel keeps the original link untouched',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final journeysRepo = _FakeJourneysRepository(
            matches: [openJourney, otherOpenJourney],
            journeysById: {'j1': openJourney, 'j2': otherOpenJourney},
          );
          final repo = _FakeActivitiesRepository(
            existing: existingHarvestWithJourney,
          );
          await goToEditForm(tester, repo, journeysRepo: journeysRepo);

          await tester.tap(
            find.byKey(const Key('activity-journey-change-button')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('journey-picker-option-j2')));
          await tester.pumpAndSettle();
          expect(find.text('Second Harvest Round'), findsOneWidget);

          final saveButton = find.byKey(const Key('activity-save-button'));
          await tester.ensureVisible(saveButton);
          await tester.pumpAndSettle();
          await tester.tap(saveButton);
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('activity-journey-relink-confirm-dialog')),
            findsOneWidget,
          );
          expect(repo.updated, isEmpty);

          await tester.tap(
            find.byKey(const Key('activity-journey-relink-confirm-cancel')),
          );
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('activity-journey-relink-confirm-dialog')),
            findsNothing,
          );
          expect(repo.updated, isEmpty);
        },
      );

      testWidgets(
        'confirming a relink calls update() with the new journey_id',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final journeysRepo = _FakeJourneysRepository(
            matches: [openJourney, otherOpenJourney],
            journeysById: {'j1': openJourney, 'j2': otherOpenJourney},
          );
          final repo = _FakeActivitiesRepository(
            existing: existingHarvestWithJourney,
          );
          await goToEditForm(tester, repo, journeysRepo: journeysRepo);

          await tester.tap(
            find.byKey(const Key('activity-journey-change-button')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('journey-picker-option-j2')));
          await tester.pumpAndSettle();

          final saveButton = find.byKey(const Key('activity-save-button'));
          await tester.ensureVisible(saveButton);
          await tester.pumpAndSettle();
          await tester.tap(saveButton);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('activity-journey-relink-confirm-confirm')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 100));

          expect(repo.updated, hasLength(1));
          expect(repo.updated.single.journeyId, 'j2');
        },
      );

      testWidgets(
        'removing the journey attachment on edit shows the relink dialog '
        '(journey -> no journey) and saves journey_id as null',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final journeysRepo = _FakeJourneysRepository(
            matches: [openJourney],
            journeysById: {'j1': openJourney},
          );
          final repo = _FakeActivitiesRepository(
            existing: existingHarvestWithJourney,
          );
          await goToEditForm(tester, repo, journeysRepo: journeysRepo);

          await tester.tap(
            find.byKey(const Key('activity-journey-remove-button')),
          );
          await tester.pumpAndSettle();
          expect(find.text('No journey attached'), findsOneWidget);

          final saveButton = find.byKey(const Key('activity-save-button'));
          await tester.ensureVisible(saveButton);
          await tester.pumpAndSettle();
          await tester.tap(saveButton);
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('activity-journey-relink-confirm-dialog')),
            findsOneWidget,
          );
          await tester.tap(
            find.byKey(const Key('activity-journey-relink-confirm-confirm')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 100));

          expect(repo.updated, hasLength(1));
          expect(repo.updated.single.journeyId, isNull);
        },
      );

      testWidgets(
        're-linking to a closed journey on edit shows the closed-journey '
        'confirm dialog',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final journeysRepo = _FakeJourneysRepository(
            matches: [openJourney, closedJourney],
            journeysById: {'j1': openJourney, 'j3': closedJourney},
          );
          final repo = _FakeActivitiesRepository(
            existing: existingHarvestWithJourney,
          );
          await goToEditForm(tester, repo, journeysRepo: journeysRepo);

          await tester.tap(
            find.byKey(const Key('activity-journey-change-button')),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('journey-picker-show-hidden-toggle')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('journey-picker-option-j3')));
          await tester.pumpAndSettle();

          final saveButton = find.byKey(const Key('activity-save-button'));
          await tester.ensureVisible(saveButton);
          await tester.pumpAndSettle();
          await tester.tap(saveButton);
          await tester.pumpAndSettle();

          expect(
            find.byKey(const Key('activity-closed-journey-confirm-dialog')),
            findsOneWidget,
          );
          expect(repo.updated, isEmpty);
        },
      );

      testWidgets(
        'switching the activity type on edit detaches the stored journey '
        '(no auto-match surprises, #387 design)',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final journeysRepo = _FakeJourneysRepository(
            matches: [openJourney],
            journeysById: {'j1': openJourney},
          );
          final repo = _FakeActivitiesRepository(
            existing: existingHarvestWithJourney,
          );
          await goToEditForm(tester, repo, journeysRepo: journeysRepo);

          expect(find.text('Spring Harvest Round'), findsOneWidget);

          await tester.tap(find.byKey(const Key('activity-type-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Generic').last);
          await tester.pumpAndSettle();

          expect(find.text('Spring Harvest Round'), findsNothing);
          expect(find.text('No journey attached'), findsOneWidget);
        },
      );

      testWidgets(
        'saving without changing the journey attachment does not show the '
        'relink dialog',
        (tester) async {
          tester.view.physicalSize = const Size(1200, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final journeysRepo = _FakeJourneysRepository(
            matches: [openJourney],
            journeysById: {'j1': openJourney},
          );
          final repo = _FakeActivitiesRepository(
            existing: existingHarvestWithJourney,
          );
          await goToEditForm(tester, repo, journeysRepo: journeysRepo);

          final saveButton = find.byKey(const Key('activity-save-button'));
          await tester.ensureVisible(saveButton);
          await tester.pumpAndSettle();
          await tester.tap(saveButton);
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          await tester.pump(const Duration(milliseconds: 100));

          expect(repo.updated, hasLength(1));
          expect(repo.updated.single.journeyId, 'j1');
        },
      );
    });
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

        await tester.tap(
          find.byKey(const Key('activity-delete-confirm-cancel')),
        );
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
        await tester.tap(
          find.byKey(const Key('activity-delete-confirm-delete')),
        );
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

        await tester.tap(
          find.byKey(const Key('activity-delete-confirm-cancel')),
        );
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
