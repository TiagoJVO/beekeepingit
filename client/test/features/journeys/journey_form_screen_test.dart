import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/journey_status.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/a11y_matchers.dart';

/// A no-op [LocalStoreEngine] — [_FakeJourneysRepository] overrides every
/// method the form touches, mirroring add_activity_screen_test.dart's
/// identical `_NoopLocalStore` fixture.
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

class _CreatedJourney {
  _CreatedJourney(
    this.name,
    this.mainActivityType,
    this.apiaryIds,
    this.defaultAttributes,
  );
  final String name;
  final String mainActivityType;
  final List<String> apiaryIds;
  final Map<String, dynamic> defaultAttributes;
}

class _UpdatedJourney {
  _UpdatedJourney(
    this.id,
    this.name,
    this.mainActivityType,
    this.status,
    this.apiaryIds,
    this.defaultAttributes,
  );
  final String id;
  final String name;
  final String mainActivityType;
  final String status;
  final List<String> apiaryIds;
  final Map<String, dynamic> defaultAttributes;
}

/// Records create()/update()/close()/delete() calls so the form's flows can
/// be asserted without a real PowerSync backend — mirrors
/// add_activity_screen_test.dart's `_FakeActivitiesRepository`, including its
/// `throwOn*` flags (the same HIGH-finding precedent: a test drives a
/// failing write without a real backend to prove the form catches the error
/// and resets `_busy` rather than hanging or crashing).
class _FakeJourneysRepository extends JourneysRepository {
  _FakeJourneysRepository({
    this.throwOnCreate = false,
    this.throwOnUpdate = false,
    this.throwOnClose = false,
    this.throwOnDelete = false,
    this.throwOnGetById = false,
    this.existing,
  }) : super(_NoopLocalStore());

  final bool throwOnCreate;
  final bool throwOnUpdate;
  final bool throwOnClose;
  final bool throwOnDelete;
  final bool throwOnGetById;
  final Journey? existing;

  final List<_CreatedJourney> created = [];
  final List<_UpdatedJourney> updated = [];
  bool closeCalled = false;
  bool deleteCalled = false;

  @override
  Future<Journey?> getById(String id) async {
    if (throwOnGetById) throw Exception('boom-load');
    return existing;
  }

  @override
  Future<String> create({
    required String name,
    required String mainActivityType,
    required List<String> apiaryIds,
    Map<String, dynamic> defaultAttributes = const {},
  }) async {
    if (throwOnCreate) throw Exception('boom-create');
    created.add(
      _CreatedJourney(name, mainActivityType, apiaryIds, defaultAttributes),
    );
    return 'fake-${created.length - 1}';
  }

  @override
  Future<void> update(
    String id, {
    required String name,
    required String mainActivityType,
    required String status,
    required List<String> apiaryIds,
    required Map<String, dynamic> defaultAttributes,
  }) async {
    if (throwOnUpdate) throw Exception('boom-update');
    updated.add(
      _UpdatedJourney(
        id,
        name,
        mainActivityType,
        status,
        apiaryIds,
        defaultAttributes,
      ),
    );
  }

  @override
  Future<void> close(String id) async {
    if (throwOnClose) throw Exception('boom-close');
    closeCalled = true;
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

const _apiaryA = Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4);
const _apiaryB = Apiary(id: 'a2', name: 'Serra Norte', hiveCount: 2);

Widget _buildApp({
  required _FakeJourneysRepository repo,
  List<Apiary> apiaries = const [_apiaryA, _apiaryB],
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      // Tasks is the app's landing screen now (#427, D-29) — stub its stream
      // so booting the app renders the Todos tab without hanging on the real,
      // never-resolving todos repository chain.
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      // Switching to the Journeys tab renders JourneysListScreen first (its
      // tab root), which watches journeysStreamProvider — overridden here
      // (mirrors app_shell_test.dart's identical fix) so it resolves
      // immediately instead of hanging on the real, never-resolving
      // Stream.empty() a NoopLocalStore-backed watchAll() would otherwise
      // produce (an indeterminate CircularProgressIndicator that never
      // settles, timing out every pumpAndSettle in this file).
      journeysStreamProvider.overrideWith(
        (ref) => Stream.value(const <Journey>[]),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      journeysRepositoryProvider.overrideWith((ref) async => repo),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openNewJourneyForm(
  WidgetTester tester, {
  _FakeJourneysRepository? repo,
}) async {
  _useTallViewport(tester);
  await tester.pumpWidget(_buildApp(repo: repo ?? _FakeJourneysRepository()));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('shell-tab-journeys')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('shell-fab')));
  await tester.pumpAndSettle();
}

/// The journey form's fields (name + type dropdown + defaults section +
/// apiary picker) exceed the default 800x600 test viewport, which would
/// otherwise leave the lower ones off-screen for tap() — mirrors
/// add_activity_screen_test.dart's own fix for its similarly-tall Treatment
/// form. Called at the start of every test in this file.
///
/// The ACTIONS need no such help since #357 pinned them outside the scroll
/// view; `_pinnedActionTests` below deliberately uses a short viewport
/// instead, which is where that matters.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'the Journeys tab has a "New journey" entry point (#45, FR-JO-4)',
    (tester) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildApp(repo: _FakeJourneysRepository()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-tab-journeys')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('shell-fab')), findsOneWidget);
      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('journey-name-field')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  group('create (#45, FR-JO-4)', () {
    testWidgets('saving without a name is blocked', (tester) async {
      final repo = _FakeJourneysRepository();
      await _openNewJourneyForm(tester, repo: repo);

      await tester.tap(find.byKey(const Key('journey-save-button')));
      await tester.pumpAndSettle();

      expect(repo.created, isEmpty);
      expect(find.text('Name is required'), findsOneWidget);
    });

    testWidgets(
      'saving with no apiary selected is allowed — the plan may be empty and '
      'apiaries added later via edit (D-30, #428, FR-JO-4)',
      (tester) async {
        final repo = _FakeJourneysRepository();
        await _openNewJourneyForm(tester, repo: repo);

        await tester.enterText(
          find.byKey(const Key('journey-name-field')),
          'Colheita de Primavera',
        );
        // No apiary selected.
        await tester.tap(find.byKey(const Key('journey-save-button')));
        await tester.pumpAndSettle();

        // The journey is created with an empty plan; the old
        // "Select at least one apiary" gate no longer blocks the save.
        expect(repo.created, hasLength(1));
        expect(repo.created.single.name, 'Colheita de Primavera');
        expect(repo.created.single.apiaryIds, isEmpty);
        expect(find.text('Select at least one apiary'), findsNothing);
        // Navigated back to the list on success.
        expect(find.byKey(const Key('journey-name-field')), findsNothing);
      },
    );

    testWidgets(
      'a selected apiary checkbox uses the accent (tertiary) color, not the '
      'muted secondary color that reads as disabled (#381)',
      (tester) async {
        final repo = _FakeJourneysRepository();
        await _openNewJourneyForm(tester, repo: repo);

        await tester.tap(find.byKey(const Key('journey-apiary-option-a1')));
        await tester.pumpAndSettle();

        final scheme = AppTheme.light().colorScheme;
        final icon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const Key('journey-apiary-option-a1')),
            matching: find.byIcon(Icons.check_box),
          ),
        );
        expect(icon.color, scheme.tertiary);
        expect(icon.color, isNot(scheme.secondary));
      },
    );

    testWidgets(
      'a valid create calls create() with the name/type/selected apiaries',
      (tester) async {
        final repo = _FakeJourneysRepository();
        await _openNewJourneyForm(tester, repo: repo);

        await tester.enterText(
          find.byKey(const Key('journey-name-field')),
          'Colheita de Primavera',
        );
        await tester.tap(find.byKey(const Key('journey-apiary-option-a1')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('journey-save-button')));
        await tester.pumpAndSettle();

        expect(repo.created, hasLength(1));
        expect(repo.created.single.name, 'Colheita de Primavera');
        expect(repo.created.single.mainActivityType, 'harvest'); // default
        expect(repo.created.single.apiaryIds, ['a1']);
        // Navigated back to the list on success.
        expect(find.byKey(const Key('journey-name-field')), findsNothing);
      },
    );

    testWidgets('selecting multiple apiaries includes them all', (
      tester,
    ) async {
      final repo = _FakeJourneysRepository();
      await _openNewJourneyForm(tester, repo: repo);

      await tester.enterText(
        find.byKey(const Key('journey-name-field')),
        'Journey',
      );
      await tester.tap(find.byKey(const Key('journey-apiary-option-a1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('journey-apiary-option-a2')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('journey-save-button')));
      await tester.pumpAndSettle();

      expect(repo.created.single.apiaryIds.toSet(), {'a1', 'a2'});
    });

    testWidgets(
      'a failing create() keeps the form open and shows an error, not an '
      'indefinite spinner',
      (tester) async {
        final repo = _FakeJourneysRepository(throwOnCreate: true);
        await _openNewJourneyForm(tester, repo: repo);

        await tester.enterText(
          find.byKey(const Key('journey-name-field')),
          'Journey',
        );
        await tester.tap(find.byKey(const Key('journey-apiary-option-a1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('journey-save-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('journey-name-field')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining('boom-create'), findsOneWidget);
      },
    );
  });

  group('default attributes section (#385)', () {
    testWidgets(
      'the harvest (default type) create form shows the lot/batch field, '
      'and a valid create includes it',
      (tester) async {
        final repo = _FakeJourneysRepository();
        await _openNewJourneyForm(tester, repo: repo);

        expect(
          find.byKey(const Key('journey-default-lot-batch-field')),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('journey-name-field')),
          'Journey',
        );
        await tester.tap(find.byKey(const Key('journey-apiary-option-a1')));
        await tester.enterText(
          find.byKey(const Key('journey-default-lot-batch-field')),
          'LOTE-2026-07',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('journey-save-button')));
        await tester.pumpAndSettle();

        expect(repo.created.single.defaultAttributes, {
          'lot_batch': 'LOTE-2026-07',
        });
      },
    );

    testWidgets('switching the main activity type swaps the defaults '
        'fields shown', (tester) async {
      final repo = _FakeJourneysRepository();
      await _openNewJourneyForm(tester, repo: repo);

      expect(
        find.byKey(const Key('journey-default-lot-batch-field')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('journey-main-activity-type-field')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Feeding').last);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('journey-default-lot-batch-field')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('journey-default-feed-type-field')),
        findsOneWidget,
      );
    });

    testWidgets('switching the main activity type clears previously-entered '
        'defaults (#385: the old type\'s keys are invalid for the new type)', (
      tester,
    ) async {
      final repo = _FakeJourneysRepository();
      await _openNewJourneyForm(tester, repo: repo);

      await tester.enterText(
        find.byKey(const Key('journey-default-lot-batch-field')),
        'LOTE-2026-07',
      );
      await tester.pumpAndSettle();

      // Switch away, then back to harvest.
      await tester.tap(
        find.byKey(const Key('journey-main-activity-type-field')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Feeding').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('journey-main-activity-type-field')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Honey harvest').last);
      await tester.pumpAndSettle();

      final lotBatchField = tester.widget<TextFormField>(
        find.byKey(const Key('journey-default-lot-batch-field')),
      );
      expect(lotBatchField.controller!.text, isEmpty);
    });
  });

  group('edit (#45, FR-JO-4, D-21)', () {
    Journey existingJourney({
      String status = journeyStatusOpen,
      Map<String, dynamic> defaultAttributes = const {},
    }) => Journey(
      id: 'j1',
      name: 'Existing Journey',
      mainActivityType: 'feeding',
      status: status,
      apiaryIds: const ['a1'],
      defaultAttributes: defaultAttributes,
    );

    /// Reaches the edit form by pushing its route directly (mirrors
    /// add_activity_screen_test.dart's own `goToEditForm` — the list
    /// screen's own read path isn't exercised by these fakes, which only
    /// implement getById/create/update/close/delete).
    Future<void> goToEditForm(
      WidgetTester tester,
      _FakeJourneysRepository repo,
    ) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildApp(repo: repo));
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(AppShell)));
      router.go('/journeys/j1/edit');
      await tester.pumpAndSettle();
    }

    testWidgets('pre-fills the form with the journey\'s current state', (
      tester,
    ) async {
      final repo = _FakeJourneysRepository(existing: existingJourney());
      await goToEditForm(tester, repo);

      final nameField = tester.widget<TextFormField>(
        find.byKey(const Key('journey-name-field')),
      );
      expect(nameField.controller!.text, 'Existing Journey');
      expect(find.text('Feeding'), findsOneWidget);
      // A delete affordance is present in edit mode.
      expect(find.byKey(const Key('journey-delete-button')), findsOneWidget);
      // An open journey shows the close action.
      expect(find.byKey(const Key('journey-close-button')), findsOneWidget);
    });

    testWidgets('pre-fills the defaults section from the journey\'s stored '
        'default_attributes (#385)', (tester) async {
      final repo = _FakeJourneysRepository(
        existing: existingJourney(
          defaultAttributes: const {'feed_type': 'Xarope 1:1'},
        ),
      );
      await goToEditForm(tester, repo);

      // The stored value is 'Xarope 1:1'; English renders '1:1 syrup'
      // (#625, NFR-I18N-1). The resubmit test below pins that the STORED
      // value is unaffected.
      expect(find.text('1:1 syrup'), findsOneWidget);
      expect(find.text('Xarope 1:1'), findsNothing);
    });

    testWidgets('an edit that resubmits the name unchanged still resubmits the '
        'existing default_attributes unchanged (never silently wiped)', (
      tester,
    ) async {
      final repo = _FakeJourneysRepository(
        existing: existingJourney(
          defaultAttributes: const {'feed_type': 'Xarope 1:1'},
        ),
      );
      await goToEditForm(tester, repo);

      await tester.tap(find.byKey(const Key('journey-save-button')));
      await tester.pumpAndSettle();

      expect(repo.updated.single.defaultAttributes, {
        'feed_type': 'Xarope 1:1',
      });
    });

    testWidgets('a closed journey does not show the close action again', (
      tester,
    ) async {
      final repo = _FakeJourneysRepository(
        existing: existingJourney(status: journeyStatusClosed),
      );
      await goToEditForm(tester, repo);

      expect(find.byKey(const Key('journey-close-button')), findsNothing);
      expect(find.text('Closed'), findsWidgets);
    });

    testWidgets(
      'a valid edit calls update() with the new values, not create()',
      (tester) async {
        final repo = _FakeJourneysRepository(existing: existingJourney());
        await goToEditForm(tester, repo);

        await tester.enterText(
          find.byKey(const Key('journey-name-field')),
          'Renamed Journey',
        );
        await tester.tap(find.byKey(const Key('journey-save-button')));
        await tester.pumpAndSettle();

        expect(repo.created, isEmpty);
        expect(repo.updated, hasLength(1));
        expect(repo.updated.single.id, 'j1');
        expect(repo.updated.single.name, 'Renamed Journey');
        expect(repo.updated.single.apiaryIds, ['a1']);
      },
    );

    testWidgets(
      'a failing update() keeps the form open and shows an error, not an '
      'indefinite spinner',
      (tester) async {
        final repo = _FakeJourneysRepository(
          existing: existingJourney(),
          throwOnUpdate: true,
        );
        await goToEditForm(tester, repo);

        await tester.enterText(
          find.byKey(const Key('journey-name-field')),
          'Renamed Journey',
        );
        await tester.tap(find.byKey(const Key('journey-save-button')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('journey-name-field')), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining('boom-update'), findsOneWidget);
      },
    );

    testWidgets(
      'a failing load resets busy and shows an error, not an indefinite '
      'spinner',
      (tester) async {
        final repo = _FakeJourneysRepository(throwOnGetById: true);
        await goToEditForm(tester, repo);

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.textContaining('boom-load'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping close calls close() and reflects the new status without '
      'navigating away (D-21)',
      (tester) async {
        final repo = _FakeJourneysRepository(existing: existingJourney());
        await goToEditForm(tester, repo);

        await tester.tap(find.byKey(const Key('journey-close-button')));
        await tester.pumpAndSettle();

        expect(repo.closeCalled, isTrue);
        expect(find.byKey(const Key('journey-close-button')), findsNothing);
        expect(find.textContaining('Journey closed'), findsOneWidget);
      },
    );

    testWidgets('a failing close() keeps the form open and shows an error', (
      tester,
    ) async {
      final repo = _FakeJourneysRepository(
        existing: existingJourney(),
        throwOnClose: true,
      );
      await goToEditForm(tester, repo);

      await tester.tap(find.byKey(const Key('journey-close-button')));
      await tester.pumpAndSettle();

      expect(find.textContaining('boom-close'), findsOneWidget);
      // Still open — the close action is still offered.
      expect(find.byKey(const Key('journey-close-button')), findsOneWidget);
    });
  });

  group('delete (#45, FR-JO-4)', () {
    Journey existingJourney() => const Journey(
      id: 'j1',
      name: 'Existing Journey',
      mainActivityType: 'feeding',
      status: journeyStatusOpen,
      apiaryIds: ['a1'],
    );

    Future<void> goToEditForm(
      WidgetTester tester,
      _FakeJourneysRepository repo,
    ) async {
      _useTallViewport(tester);
      await tester.pumpWidget(_buildApp(repo: repo));
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(AppShell)));
      router.go('/journeys/j1/edit');
      await tester.pumpAndSettle();
    }

    testWidgets('tapping delete opens a confirmation dialog; cancel is a '
        'no-op', (tester) async {
      final repo = _FakeJourneysRepository(existing: existingJourney());
      await goToEditForm(tester, repo);

      await tester.tap(find.byKey(const Key('journey-delete-button')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('journey-delete-confirm-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('journey-delete-confirm-cancel')));
      await tester.pumpAndSettle();

      expect(repo.deleteCalled, isFalse);
      expect(find.byKey(const Key('journey-name-field')), findsOneWidget);
    });

    testWidgets('confirming delete calls delete() and navigates away', (
      tester,
    ) async {
      final repo = _FakeJourneysRepository(existing: existingJourney());
      await goToEditForm(tester, repo);

      await tester.tap(find.byKey(const Key('journey-delete-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('journey-delete-confirm-delete')));
      await tester.pumpAndSettle();

      expect(repo.deleteCalled, isTrue);
      expect(find.byKey(const Key('journey-name-field')), findsNothing);
    });

    testWidgets('a failing delete() keeps the form open and shows an error', (
      tester,
    ) async {
      final repo = _FakeJourneysRepository(
        existing: existingJourney(),
        throwOnDelete: true,
      );
      await goToEditForm(tester, repo);

      await tester.tap(find.byKey(const Key('journey-delete-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('journey-delete-confirm-delete')));
      await tester.pumpAndSettle();

      expect(find.textContaining('boom-delete'), findsOneWidget);
      expect(find.byKey(const Key('journey-name-field')), findsOneWidget);
    });
  });

  group(
    'accessibility (D-18, docs/design/accessibility-field-ux-checklist.md)',
    () {
      testWidgets(
        'the apiary picker rows and the save/close/delete buttons all meet '
        'the 44x44 minimum tap target',
        (tester) async {
          final repo = _FakeJourneysRepository(
            existing: const Journey(
              id: 'j1',
              name: 'Existing Journey',
              mainActivityType: 'feeding',
              status: journeyStatusOpen,
              apiaryIds: ['a1'],
            ),
          );
          _useTallViewport(tester);
          await tester.pumpWidget(_buildApp(repo: repo));
          await tester.pumpAndSettle();
          final router = GoRouter.of(tester.element(find.byType(AppShell)));
          router.go('/journeys/j1/edit');
          await tester.pumpAndSettle();

          expectMinTapTarget(
            tester,
            find.byKey(const Key('journey-apiary-option-a1')),
          );
          expectMinTapTarget(
            tester,
            find.byKey(const Key('journey-apiary-option-a2')),
          );
          expectHasSemanticsLabel(
            tester,
            const Key('journey-apiary-option-a1'),
          );
        },
      );
    },
  );

  /// Save-time validation parity (#597, FR-OF-2, D-12, sync.md §9): the same
  /// evaluator and the same shared description the pre-push check runs, moved
  /// to the moment the beekeeper presses Save.
  group('save-time validation parity (#597)', () {
    /// 150 'ç' are 150 characters — inside the field's 200-character
    /// `maxLength` — and 300 UTF-8 bytes, over `journey.name`'s 200-**byte**
    /// cap.
    final overlongName = 'ç' * 150;

    testWidgets(
      'a name the server would reject is caught in the form — the journey is '
      'never created',
      (tester) async {
        final repo = _FakeJourneysRepository();
        await _openNewJourneyForm(tester, repo: repo);
        await tester.enterText(
          find.byKey(const Key('journey-name-field')),
          overlongName,
        );
        await tester.tap(find.byKey(const Key('journey-save-button')));
        await tester.pumpAndSettle();

        expect(repo.created, isEmpty);
        expect(find.text('Name: this text is too long.'), findsOneWidget);
        expect(
          tester.getSemantics(find.text('Name: this text is too long.')).label,
          contains('too long'),
        );
      },
    );

    testWidgets(
      'a journey with default attributes still saves — the bag reaches the '
      'check DECODED, the shape the wire op carries, not as JSON text',
      (tester) async {
        // Regression guard for the one way this seam could reject every save:
        // `default_attributes` is stored locally as JSON-encoded TEXT and only
        // decoded on its way to the wire (#385). Validating the encoded string
        // would fail the description's `jsonObject` rule every time.
        final repo = _FakeJourneysRepository();
        await _openNewJourneyForm(tester, repo: repo);
        await tester.enterText(
          find.byKey(const Key('journey-name-field')),
          'Colheita de Primavera',
        );
        await tester.enterText(
          find.byKey(const Key('journey-default-lot-batch-field')),
          'L-2026-01',
        );
        await tester.tap(find.byKey(const Key('journey-save-button')));
        await tester.pumpAndSettle();

        expect(repo.created, hasLength(1));
        expect(repo.created.single.defaultAttributes, {
          'lot_batch': 'L-2026-01',
        });
      },
    );

    testWidgets('a valid journey still saves — no false positive', (
      tester,
    ) async {
      final repo = _FakeJourneysRepository();
      await _openNewJourneyForm(tester, repo: repo);
      await tester.enterText(
        find.byKey(const Key('journey-name-field')),
        'Colheita de Primavera',
      );
      await tester.tap(find.byKey(const Key('journey-save-button')));
      await tester.pumpAndSettle();

      expect(repo.created, hasLength(1));
      expect(repo.created.single.name, 'Colheita de Primavera');
    });
  });

  _pinnedActionTests();
}

/// Opens the create form at an explicit [viewport] rather than
/// [_useTallViewport]'s — the pinning tests below need the form laid out at
/// a height a real phone in the field actually has.
Future<void> _openNewJourneyFormAt(
  WidgetTester tester,
  Size viewport, {
  required _FakeJourneysRepository repo,
}) async {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_buildApp(repo: repo));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('shell-tab-journeys')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('shell-fab')));
  await tester.pumpAndSettle();
}

/// #357 — the actions live in a bar pinned OUTSIDE the scroll view, so they
/// are on screen at every scroll offset. The hazard here is the milder
/// sibling of #341's: this form embeds no gesture-swallowing map, but its
/// apiary multi-select is a bounded, inner-scrollable list that traps a drag
/// started over it, so an action parked at the end of the outer scrollable
/// is a fight to reach on a short viewport (FR-UX-1, FR-AX-1, D-18).
void _pinnedActionTests() {
  group('the primary action stays pinned at a short viewport '
      '(FR-UX-1, FR-AX-1, D-18, #357)', () {
    // A 400x640 phone held at arm's length in a bee suit — shorter than this
    // form's content, which is exactly the case the pinning exists for.
    const shortViewport = Size(400, 640);

    testWidgets(
      'Save is on-screen and actually creates the journey without scrolling',
      (tester) async {
        final repo = _FakeJourneysRepository();
        await _openNewJourneyFormAt(tester, shortViewport, repo: repo);

        await tester.enterText(
          find.byKey(const Key('journey-name-field')),
          'Colheita de Primavera',
        );
        await tester.pump();

        // Deliberately NO ensureVisible before any of this — that is the
        // whole point of a pinned action bar.
        final save = find.byKey(const Key('journey-save-button'));
        expectFullyOnScreen(
          tester,
          save,
          reason: 'Save must be fully on-screen on a short viewport',
        );
        expectMinTapTarget(tester, save);
        expectHasSemanticsLabel(tester, const Key('journey-save-button'));

        await tester.tap(save);
        await tester.pumpAndSettle();

        expect(
          repo.created,
          hasLength(1),
          reason:
              'tapping the pinned Save must create the journey, not silently '
              'no-op',
        );
        expect(repo.created.single.name, 'Colheita de Primavera');
      },
    );

    testWidgets(
      'Save stays on-screen mid-scroll, with the drag that would reach it '
      'swallowed by the apiary multi-select',
      (tester) async {
        final repo = _FakeJourneysRepository();
        await _openNewJourneyFormAt(tester, shortViewport, repo: repo);

        await tester.enterText(
          find.byKey(const Key('journey-name-field')),
          'Colheita de Primavera',
        );
        await tester.pump();

        // Park the form mid-scroll, then keep dragging — but over the
        // multi-select's own bounded list, which consumes the gesture
        // instead of passing it to the form. That is the trap: the user
        // swipes up and the form does not move, so a trailing action never
        // arrives.
        //
        // The pre-scroll is measured, not a fixed offset, and it scrolls the
        // MINIMUM that still sets the trap: just far enough to bring a sliver
        // of the picker in from the bottom edge. Two things have to hold at
        // once and they pull against each other — the picker must be visible
        // enough to start a drag on, while Save must still be below the fold,
        // because a Save already scrolled into view would let this test pass
        // against the very layout it exists to reject. A hardcoded offset
        // cannot hold both: it encodes today's field heights, and the first
        // field added above the picker slides the window past one or other
        // end of it.
        final apiaryList = find.byKey(const Key('journey-apiaries-list'));
        final formScrollView = find
            .ancestor(
              of: apiaryList,
              matching: find.byType(SingleChildScrollView),
            )
            .first;
        const exposedPickerSliver = 60.0;
        await tester.drag(
          find.byKey(const Key('journey-name-field')),
          Offset(
            0,
            tester.getRect(formScrollView).bottom -
                exposedPickerSliver -
                tester.getRect(apiaryList).top,
          ),
        );
        await tester.pumpAndSettle();
        // The drag has to genuinely START over the picker, on the part of it
        // actually visible inside the form's scroll view. `tester.drag` would
        // aim at the picker's geometric centre, which may sit below the
        // visible area — the gesture would miss the trap entirely and this
        // test would pass for the wrong reason.
        final visiblePicker = tester
            .getRect(apiaryList)
            .intersect(tester.getRect(formScrollView));
        expect(
          visiblePicker.height,
          greaterThan(24),
          reason:
              'the picker must be visibly on screen for this drag to be the '
              'one a user would actually make',
        );
        await tester.dragFrom(visiblePicker.center, const Offset(0, -400));
        await tester.pumpAndSettle();

        final save = find.byKey(const Key('journey-save-button'));
        expectFullyOnScreen(
          tester,
          save,
          reason:
              'Save must stay on-screen when the drag that would reach it is '
              'swallowed by the inner picker',
        );
        expectMinTapTarget(tester, save);

        await tester.tap(save);
        await tester.pumpAndSettle();

        expect(repo.created, hasLength(1));
      },
    );

    testWidgets('the edit form pins Close and Delete alongside Save', (
      tester,
    ) async {
      final repo = _FakeJourneysRepository(
        existing: const Journey(
          id: 'j1',
          name: 'Existing Journey',
          mainActivityType: 'feeding',
          status: journeyStatusOpen,
          apiaryIds: ['a1'],
        ),
      );
      tester.view.physicalSize = shortViewport;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_buildApp(repo: repo));
      await tester.pumpAndSettle();
      GoRouter.of(tester.element(find.byType(AppShell)))
          .go('/journeys/j1/edit');
      await tester.pumpAndSettle();

      for (final key in const [
        Key('journey-save-button'),
        Key('journey-close-button'),
        Key('journey-delete-button'),
      ]) {
        final finder = find.byKey(key);
        expectFullyOnScreen(
          tester,
          finder,
          reason: '$key must be pinned on-screen on a short viewport',
        );
        expectMinTapTarget(tester, finder);
      }
    });

    testWidgets(
      'the three-action edit bar fits a short landscape body instead of '
      'overflowing and clipping Delete',
      (tester) async {
        // A handset in landscape leaves the shell body shorter than the
        // edit-mode bar's own height. A fixed-height bar in a Column would
        // hand the scroll view 0px, overflow the Column, and paint the
        // destructive Delete clipped under the navigation bar — below the
        // 44x44 floor (D-18) this very pinning is meant to protect.
        final repo = _FakeJourneysRepository(
          existing: const Journey(
            id: 'j1',
            name: 'Existing Journey',
            mainActivityType: 'feeding',
            status: journeyStatusOpen,
            apiaryIds: ['a1'],
          ),
        );
        tester.view.physicalSize = const Size(740, 360);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_buildApp(repo: repo));
        await tester.pumpAndSettle();
        GoRouter.of(tester.element(find.byType(AppShell)))
            .go('/journeys/j1/edit');
        await tester.pumpAndSettle();

        expect(
          tester.takeException(),
          isNull,
          reason: 'the pinned bar must not overflow its Column',
        );

        // Save is what the user came for — it stays reachable without
        // scrolling even here.
        expectFullyOnScreen(
          tester,
          find.byKey(const Key('journey-save-button')),
          reason: 'Save must stay on-screen in a short landscape body',
        );
        for (final key in const [
          Key('journey-save-button'),
          Key('journey-close-button'),
          Key('journey-delete-button'),
        ]) {
          expectMinTapTarget(tester, find.byKey(key));
        }
      },
    );
  });
}
