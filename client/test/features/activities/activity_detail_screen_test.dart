import 'dart:async';

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/history/history_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/a11y_matchers.dart';

/// Fixtures mirroring the sibling activity/apiary widget tests (file-private
/// there, so re-declared here).
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

const _apiaries = [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)];

/// A no-op [LocalStoreEngine], mirroring the sibling tests' fixture — the spy
/// repository below overrides every method it exercises.
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

/// Records the ids passed to [delete] so the delete flow can be asserted
/// end-to-end without a real PowerSync-backed store.
class _SpyActivitiesRepository extends ActivitiesRepository {
  _SpyActivitiesRepository() : super(_NoopLocalStore());

  final List<String> deleted = [];

  @override
  Future<void> delete(String id) async => deleted.add(id);
}

/// Holds [delete] pending on a caller-controlled [Completer] so a test can
/// observe the screen's in-flight (busy) state deterministically.
class _BlockingDeleteRepository extends ActivitiesRepository {
  _BlockingDeleteRepository() : super(_NoopLocalStore());

  final Completer<void> gate = Completer<void>();

  @override
  Future<void> delete(String id) => gate.future;
}

Activity _harvest({
  String id = 'act1',
  String apiaryId = 'a1',
  String? performedBy = 'test-user',
}) => Activity(
  id: id,
  apiaryId: apiaryId,
  type: 'harvest',
  occurredAt: '2026-06-01',
  attributes: const {'honey_supers': 4, 'notes': 'Great flow this year.'},
  performedBy: performedBy,
  organizationId: 'test-org',
);

Widget _buildApp({
  required Activity activity,
  Activity? byId,
  ActivitiesRepository? repo,
  Stream<Activity?> Function()? detailStream,
}) {
  final detail = byId ?? activity;
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(_apiaries)),
      // Tasks is the app's landing screen now (#427, D-29) — stub its stream
      // so booting the app renders the Todos tab without hanging on the real,
      // never-resolving todos repository chain.
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      apiaryByIdProvider.overrideWith(
        (ref, apiaryId) => Stream.value(
          _apiaries.cast<Apiary?>().firstWhere(
            (a) => a!.id == apiaryId,
            orElse: () => null,
          ),
        ),
      ),
      apiaryCountersProvider.overrideWith(
        (ref, apiaryId) => Stream.value(const <ApiaryCounter>[]),
      ),
      // Per-apiary section (#42) and all-apiaries tab (#43) both list this
      // activity; the detail screen watches the per-id family provider.
      activitiesByApiaryProvider.overrideWith(
        (ref, apiaryId) => Stream.value([activity]),
      ),
      activitiesStreamProvider.overrideWith((ref) => Stream.value([activity])),
      // [detailStream] lets the layout group below hold the detail in its
      // `loading` / `error` branch (#787) without duplicating this whole
      // override list; every other test leaves it null and resolves by id.
      activityByIdProvider.overrideWith(
        (ref, id) =>
            detailStream?.call() ??
            Stream.value(id == detail.id ? detail : null),
      ),
      if (repo != null)
        activitiesRepositoryProvider.overrideWith((ref) async => repo),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      // The detail screen's history section (#60) watches this; left
      // un-overridden it would hang on the un-resolvable powerSyncProvider
      // chain, same reason every other provider here is stubbed. Empty is
      // the honest default — these fixtures record no history.
      entityHistoryProvider.overrideWith(
        (ref, target) => Stream.value(const <HistoryEntry>[]),
      ),
    ],
    child: const BeekeepingitApp(),
  );
}

/// Taps the detail screen's delete action, scrolling it into view first.
///
/// The button sits at the bottom of a `SingleChildScrollView` whose content
/// grew past one viewport once the history section (#60) landed below the
/// attributes card — a bare `tap()` then resolves to a coordinate the edit
/// FAB overlays, silently navigating to the edit form instead of opening the
/// confirm dialog.
Future<void> _tapDelete(WidgetTester tester) async {
  final button = find.byKey(const Key('activity-detail-delete-button'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
}

void main() {
  group('activity detail screen (#310, FR-AC-3/5/6, FR-TEN-2)', () {
    testWidgets(
      'tapping a row in the main all-apiaries Activities tab opens the detail',
      (tester) async {
        await tester.pumpWidget(_buildApp(activity: _harvest()));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-tab-activities')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('activity-act1')));
        await tester.pumpAndSettle();

        // Detail renders: type, date, all attributes, and the performer.
        expect(find.byKey(const Key('activity-detail-header')), findsOneWidget);
        expect(find.text('Honey harvest'), findsWidgets);
        expect(find.textContaining('Date'), findsWidgets);
        expect(
          find.byKey(const Key('activity-detail-attributes')),
          findsOneWidget,
        );
        expect(find.text('Honey supers harvested'), findsOneWidget);
        expect(find.text('4'), findsOneWidget);
        expect(find.text('Great flow this year.'), findsOneWidget);
        // Attribution is shown read-only (FR-TEN-2) — "You" for the caller,
        // via the dedicated visible label (not the screen-reader template).
        expect(find.text('Performed by: You'), findsOneWidget);

        // Cross-branch navigation (approved at Gate 1): the detail lives under
        // the Apiaries branch, so opening it from the Activities tab enters
        // that branch's stack — Back lands on the owning apiary's detail, not
        // the Activities list. Locked in so the behavior can't silently
        // regress.
        expect(find.byKey(const Key('shell-back-button')), findsOneWidget);
        await tester.tap(find.byKey(const Key('shell-back-button')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('apiary-detail-header')), findsOneWidget);
      },
    );

    testWidgets(
      'tapping a row in the per-apiary Activities section opens the detail',
      (tester) async {
        await tester.pumpWidget(_buildApp(activity: _harvest()));
        await tester.pumpAndSettle();
        // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
        // tab before interacting with the apiaries list.
        await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
        await tester.pumpAndSettle();

        // Open the apiary detail (the per-apiary section lives here).
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('apiary-detail-header')), findsOneWidget);

        await tester.ensureVisible(find.byKey(const Key('activity-act1')));
        await tester.tap(find.byKey(const Key('activity-act1')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('activity-detail-header')), findsOneWidget);
        expect(
          find.byKey(const Key('activity-detail-attributes')),
          findsOneWidget,
        );
      },
    );

    testWidgets('the Edit action navigates to the edit form', (tester) async {
      await tester.pumpWidget(_buildApp(activity: _harvest()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-tab-activities')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('activity-act1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('activity-detail-edit-button')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('activity-detail-edit-button')));
      // Bounded pumps, not pumpAndSettle: the edit form's initState kicks off
      // a real activitiesRepositoryProvider load (add_activity_screen.dart's
      // _loadExisting) that never resolves in this PowerSync-less environment,
      // leaving its own busy spinner — the same pattern
      // apiary_detail_screen_test.dart's edit-navigation test documents.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      // The header title switched to the edit form's and its busy spinner
      // shows — the activity detail's own Edit FAB is gone.
      expect(find.text('Edit activity'), findsWidgets);
      expect(find.byKey(const Key('shell-back-button')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      expect(
        find.byKey(const Key('activity-detail-edit-button')),
        findsNothing,
      );
    });

    testWidgets(
      'the Delete action shows the existing confirm dialog, then deletes',
      (tester) async {
        final repo = _SpyActivitiesRepository();
        await tester.pumpWidget(_buildApp(activity: _harvest(), repo: repo));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-tab-activities')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('activity-act1')));
        await tester.pumpAndSettle();

        // Cancel first: the existing confirmation step must gate the delete.
        await _tapDelete(tester);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('activity-delete-confirm-dialog')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('activity-delete-confirm-cancel')),
        );
        await tester.pumpAndSettle();
        expect(repo.deleted, isEmpty);

        // Confirming actually deletes the activity via the repository.
        await _tapDelete(tester);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('activity-delete-confirm-delete')),
        );
        await tester.pumpAndSettle();

        expect(repo.deleted, ['act1']);
      },
    );

    testWidgets(
      'the Edit action is disabled while a delete is in flight (no edit of a '
      'row being removed)',
      (tester) async {
        final repo = _BlockingDeleteRepository();
        await tester.pumpWidget(_buildApp(activity: _harvest(), repo: repo));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shell-tab-activities')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('activity-act1')));
        await tester.pumpAndSettle();

        // Edit is enabled before any delete is started.
        final fabFinder = find.byKey(const Key('activity-detail-edit-button'));
        expect(
          tester.widget<FloatingActionButton>(fabFinder).onPressed,
          isNotNull,
        );

        // Start the delete; it stays pending on the completer.
        await _tapDelete(tester);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('activity-delete-confirm-delete')),
        );
        await tester.pump(); // let setState(_busy = true) rebuild

        // The Edit FAB is now disabled — it can't open the edit form for the
        // row currently being deleted.
        expect(
          tester.widget<FloatingActionButton>(fabFinder).onPressed,
          isNull,
        );

        // Let the delete finish so the widget tree tears down cleanly.
        repo.gate.complete();
        await tester.pumpAndSettle();
      },
    );

    testWidgets('a deleted/unknown activity bounces back to its apiary', (
      tester,
    ) async {
      // The row exists in the list, but the per-id watch resolves to null
      // (already deleted / stale deep link) — the detail must not render a
      // blank page; it bounces to the owning apiary detail.
      await tester.pumpWidget(
        _buildApp(
          activity: _harvest(),
          byId: const Activity(
            id: 'missing',
            apiaryId: 'a1',
            type: 'harvest',
            occurredAt: '2026-06-01',
            attributes: {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('shell-tab-activities')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('activity-act1')));
      await tester.pumpAndSettle();

      // activityByIdProvider('act1') returns null (only 'missing' matches) —
      // the screen bounced to the apiary detail rather than showing a blank
      // activity-detail-header.
      expect(find.byKey(const Key('activity-detail-header')), findsNothing);
      expect(find.byKey(const Key('apiary-detail-header')), findsOneWidget);
    });
  });

  _layoutTests();
}

/// #787 (FR-UX-1): the body hung its 480px column off a plain `Center`, which
/// splits the leftover height into equal bands and leaves a dead gap between
/// the shell's header and the first card.
///
/// The viewport matters more here than on the screens #630/#769 fixed. At
/// [kHandsetViewport] this screen's header card, attributes card and history
/// block already overflow the body, so the scroll view fills it and the
/// `Center` is inert — 0px, before and after. The band only appears once the
/// body is taller than the content, which on this fixture starts around a
/// tablet: [kTabletViewport] measured 261.5px on `main`. A guard written at
/// 375x812 would have asserted nothing at all.
void _layoutTests() {
  group('ActivityDetailScreen — layout at 1024x1366 (#787, FR-UX-1)', () {
    Future<void> openAt(
      WidgetTester tester, {
      Stream<Activity?> Function()? detail,
      bool settle = true,
    }) async {
      useViewport(tester, size: kTabletViewport);
      await tester.pumpWidget(
        _buildApp(activity: _harvest(), detailStream: detail),
      );
      await tester.pumpAndSettle();
      // The same two taps every test above uses to reach this screen — the
      // Activities tab lists `act1` off activitiesStreamProvider, which
      // [detailStream] does not touch.
      await tester.tap(find.byKey(const Key('shell-tab-activities')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('activity-act1')));
      // The loading branch renders a CircularProgressIndicator, which never
      // stops animating — `pumpAndSettle` would time out rather than fail on
      // an assertion, so that case pumps a fixed frame instead.
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
      }
    }

    testWidgets('the content starts at the top of the content area', (
      tester,
    ) async {
      await openAt(tester);

      expectStartsAtContentTop(
        tester,
        find.ancestor(
          of: find.byKey(const Key('activity-detail-header')),
          matching: find.byType(SingleChildScrollView),
        ),
        // Anchored on the navigation shell, not an AppBar: this screen has
        // none of its own — the shell owns the header and hands the route
        // the region below it (and stacks the offline/needs-fix banners in
        // between, so the assertion keeps meaning something if one shows).
        anchor: find.byType(StatefulNavigationShell),
        from: ContentTopAnchor.inside,
        label: "the activity's detail card stack",
      );
    });

    // The other half of the change: only the `data` branch top-aligns. These
    // two fail if the alignment wrapper is ever hoisted above
    // `activityAsync.when` — the mistake #630 had to undo on the journey
    // stats screen.
    testWidgets('the loading spinner stays vertically centred', (tester) async {
      await openAt(tester, detail: pendingStream<Activity?>, settle: false);

      expectVerticallyCentredIn(
        tester,
        find.byType(CircularProgressIndicator),
        region: tester.getRect(find.byType(StatefulNavigationShell)),
      );
    });

    testWidgets('the error message stays vertically centred', (tester) async {
      await openAt(
        tester,
        detail: () => Stream<Activity?>.error(Exception('boom')),
      );
      expectVerticallyCentredIn(
        tester,
        find.textContaining('boom'),
        region: tester.getRect(find.byType(StatefulNavigationShell)),
        label: 'a lone error message',
      );
    });
  });
}

