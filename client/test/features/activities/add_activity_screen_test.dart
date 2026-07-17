import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// Records `create()` calls so the save path can be asserted without a real
/// PowerSync backend, mirroring apiary_form_screen_test.dart's
/// `_FakeApiariesRepository`.
class _FakeActivitiesRepository extends ActivitiesRepository {
  _FakeActivitiesRepository({this.throwOnCreate = false})
    : super(_NoopLocalStore());

  final bool throwOnCreate;
  final List<_CreatedActivity> created = [];

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
}
