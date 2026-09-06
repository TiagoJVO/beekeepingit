import 'dart:async';

import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/shell/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/a11y_matchers.dart';

/// A no-op [LocalStoreEngine] — [_FakeTodosRepository] overrides every method
/// exercised, mirroring the sibling todos/activities/journeys test fixtures.
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

/// A fake [TodosRepository] whose [complete]/[reopen] push a new [Todo] onto
/// a broadcast stream — the detail screen watches [todoByIdProvider] (a LIVE
/// per-id provider, mirrors [ActivityDetailScreen]'s own `activityByIdProvider`
/// watch), so exercising its in-place toggle needs a genuinely live stream
/// rather than a fixed `Stream.value(...)`, the same technique
/// sync_needs_fix_screen_test.dart's `_FakeRejectedStore` already uses to
/// prove a write is reflected by the SAME live query a real PowerSync-backed
/// store would re-emit through.
class _FakeTodosRepository extends TodosRepository {
  _FakeTodosRepository(
    Todo? initial, {
    this.throwOnComplete = false,
    this.throwOnReopen = false,
  }) : current = initial,
       super(_NoopLocalStore());

  Todo? current;
  final bool throwOnComplete;
  final bool throwOnReopen;
  final _controller = StreamController<Todo?>.broadcast();

  final List<String> completed = [];
  final List<String> reopened = [];

  /// Yields [current] immediately on listen, then forwards every subsequent
  /// write — the fixture-level equivalent of a live PowerSync watch query.
  Stream<Todo?> get liveStream async* {
    yield current;
    yield* _controller.stream;
  }

  /// Used by the edit form's own one-shot `_loadExisting()` (reached via the
  /// detail screen's Edit action, #633) — the base [TodosRepository.getById]
  /// would otherwise always resolve null against [_NoopLocalStore], leaving
  /// the form blank instead of pre-filled.
  @override
  Future<Todo?> getById(String id) async => current;

  @override
  Future<void> complete(String id) async {
    if (throwOnComplete) throw Exception('boom-complete');
    final t = current!;
    current = Todo(
      id: t.id,
      title: t.title,
      description: t.description,
      dueDate: t.dueDate,
      priority: t.priority,
      status: 'done',
      completedAt: '2026-07-18T00:00:00Z',
      assigneeId: t.assigneeId,
      apiaryId: t.apiaryId,
      organizationId: t.organizationId,
    );
    completed.add(id);
    _controller.add(current);
  }

  @override
  Future<void> reopen(String id) async {
    if (throwOnReopen) throw Exception('boom-reopen');
    final t = current!;
    current = Todo(
      id: t.id,
      title: t.title,
      description: t.description,
      dueDate: t.dueDate,
      priority: t.priority,
      status: 'open',
      completedAt: null,
      assigneeId: t.assigneeId,
      apiaryId: t.apiaryId,
      organizationId: t.organizationId,
    );
    reopened.add(id);
    _controller.add(current);
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

const _apiaries = [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)];
const _memberNames = {'m1': 'Maria Silva'};

Widget _buildApp({
  required _FakeTodosRepository repo,
  Stream<Todo?> Function()? detailStream,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(_apiaries)),
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      // [detailStream] lets the layout group at the foot of this file hold
      // the detail in its `loading` / `error` branch (#787) without
      // duplicating this whole override list; every other test leaves it null
      // and watches the fake repository's live stream.
      todoByIdProvider.overrideWith(
        (ref, id) => detailStream?.call() ?? repo.liveStream,
      ),
      memberNamesProvider.overrideWith((ref) async => _memberNames),
      todosRepositoryProvider.overrideWith((ref) async => repo),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

/// The todo detail screen's content (header, status, description, due date,
/// priority, assignee, apiary, completed-at) exceeds the default 800x600 test
/// viewport, pushing the complete/reopen toggle button off-screen — mirrors
/// todo_form_screen_test.dart's own identical `_useTallViewport` fix.
void _useTallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(1200, 3600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _openDetail(
  WidgetTester tester, {
  required _FakeTodosRepository repo,
  String todoId = 't1',
}) async {
  _useTallViewport(tester);
  await tester.pumpWidget(_buildApp(repo: repo));
  await tester.pumpAndSettle();
  final router = GoRouter.of(tester.element(find.byType(AppShell)));
  router.go('/todos/$todoId');
  await tester.pumpAndSettle();
}

Todo _todo({
  String id = 't1',
  String title = 'Inspect hive 3',
  String? description,
  String priority = 'medium',
  String status = 'open',
  String? dueDate,
  String? completedAt,
  String? assigneeId,
  String? apiaryId,
}) => Todo(
  id: id,
  title: title,
  description: description,
  priority: priority,
  status: status,
  dueDate: dueDate,
  completedAt: completedAt,
  assigneeId: assigneeId,
  apiaryId: apiaryId,
  organizationId: 'test-org',
);

void main() {
  group('todo detail screen (#293, FR-TD-1)', () {
    testWidgets('renders every field read-only', (tester) async {
      final repo = _FakeTodosRepository(
        _todo(
          description: 'Check for mites',
          priority: 'high',
          dueDate: '2026-08-01',
          assigneeId: 'm1',
          apiaryId: 'a1',
        ),
      );
      await _openDetail(tester, repo: repo);

      expect(find.byKey(const Key('todo-detail-header')), findsOneWidget);
      expect(find.text('Inspect hive 3'), findsOneWidget);
      expect(find.text('Check for mites'), findsOneWidget);
      expect(find.text('High'), findsOneWidget);
      expect(find.text('Maria Silva'), findsOneWidget);
      expect(find.text('Serra Norte'), findsOneWidget);
      expect(find.text('Status: Open'), findsOneWidget);
      // No edit controls on this read-focused screen (edit lives on the
      // form, reached via the pinned action bar).
      expect(find.byType(TextFormField), findsNothing);
    });

    testWidgets(
      'an unset description/due date/assignee/apiary show their fallback '
      'text, not blank',
      (tester) async {
        final repo = _FakeTodosRepository(_todo());
        await _openDetail(tester, repo: repo);

        expect(find.text('No description'), findsOneWidget);
        expect(find.text('No due date'), findsOneWidget);
        expect(find.text('Unassigned'), findsOneWidget);
        expect(find.text('No apiary'), findsOneWidget);
      },
    );

    testWidgets(
      'an assignee id not in the roster falls back to a short id, not a '
      'blank row',
      (tester) async {
        final repo = _FakeTodosRepository(
          _todo(assigneeId: 'abcdefgh99999999'),
        );
        await _openDetail(tester, repo: repo);

        expect(find.text('Member 99999999'), findsOneWidget);
      },
    );

    testWidgets(
      'an apiary id no longer in the locally-synced set falls back to '
      'Unknown apiary',
      (tester) async {
        final repo = _FakeTodosRepository(_todo(apiaryId: 'gone'));
        await _openDetail(tester, repo: repo);

        expect(find.text('Unknown apiary'), findsOneWidget);
      },
    );

    testWidgets('a done todo shows the completed status and timestamp', (
      tester,
    ) async {
      final repo = _FakeTodosRepository(
        _todo(status: 'done', completedAt: '2026-07-01T10:00:00Z'),
      );
      await _openDetail(tester, repo: repo);

      expect(find.text('Status: Completed'), findsOneWidget);
      expect(find.text('Completed at'), findsOneWidget);
      // The complete/reopen action offers Reopen, not Mark as complete.
      expect(find.text('Reopen'), findsOneWidget);
    });

    group('complete/reopen toggle (in place, no navigation)', () {
      testWidgets('tapping the toggle on an open todo calls complete() and '
          'updates the screen in place', (tester) async {
        final repo = _FakeTodosRepository(_todo());
        await _openDetail(tester, repo: repo);

        expect(find.text('Mark as complete'), findsOneWidget);
        await tester.tap(
          find.byKey(const Key('todo-detail-complete-toggle-button')),
        );
        await tester.pumpAndSettle();

        expect(repo.completed, ['t1']);
        // Still on the detail screen (no navigation) — status flipped live.
        expect(find.byKey(const Key('todo-detail-header')), findsOneWidget);
        expect(find.text('Status: Completed'), findsOneWidget);
        expect(find.text('Reopen'), findsOneWidget);
      });

      testWidgets('tapping the toggle on a done todo calls reopen() and '
          'updates the screen in place', (tester) async {
        final repo = _FakeTodosRepository(
          _todo(status: 'done', completedAt: '2026-07-01T10:00:00Z'),
        );
        await _openDetail(tester, repo: repo);

        await tester.tap(
          find.byKey(const Key('todo-detail-complete-toggle-button')),
        );
        await tester.pumpAndSettle();

        expect(repo.reopened, ['t1']);
        expect(find.text('Status: Open'), findsOneWidget);
        expect(find.text('Mark as complete'), findsOneWidget);
      });

      testWidgets('a failing toggle shows an error and stays in place', (
        tester,
      ) async {
        final repo = _FakeTodosRepository(_todo(), throwOnComplete: true);
        await _openDetail(tester, repo: repo);

        await tester.tap(
          find.byKey(const Key('todo-detail-complete-toggle-button')),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('boom-complete'), findsOneWidget);
        expect(find.byKey(const Key('todo-detail-header')), findsOneWidget);
      });

      testWidgets('a failing reopen toggle shows an error and stays in place', (
        tester,
      ) async {
        final repo = _FakeTodosRepository(
          _todo(status: 'done', completedAt: '2026-07-01T10:00:00Z'),
          throwOnReopen: true,
        );
        await _openDetail(tester, repo: repo);

        await tester.tap(
          find.byKey(const Key('todo-detail-complete-toggle-button')),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('boom-reopen'), findsOneWidget);
        expect(find.byKey(const Key('todo-detail-header')), findsOneWidget);
      });
    });

    // #633 replaced the floating action button with an OutlinedButton
    // (SecondaryActionButton) in the pinned bar — it taps the same way, and
    // the key is deliberately reused, so this test's behaviour is unchanged.
    testWidgets('the edit action navigates to the edit form', (tester) async {
      final repo = _FakeTodosRepository(_todo());
      await _openDetail(tester, repo: repo);

      expect(find.byKey(const Key('todo-detail-edit-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('todo-detail-edit-button')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
      final titleField = tester.widget<TextFormField>(
        find.byKey(const Key('todo-title-field')),
      );
      expect(titleField.controller!.text, 'Inspect hive 3');
    });

    testWidgets('a deleted/unknown todo bounces back to the Todos tab', (
      tester,
    ) async {
      final repo = _FakeTodosRepository(null);
      await _openDetail(tester, repo: repo);

      expect(find.byKey(const Key('todo-detail-header')), findsNothing);
      expect(find.text('No todos yet.'), findsOneWidget);
    });
  });

  _pinnedActionTests();
  _layoutTests();
}

/// Sizes the test view to [viewport] at a 1:1 device pixel ratio and
/// restores it afterwards — copied from todo_form_screen_test.dart's own
/// `_useViewport` rather than reused, and deliberately NOT
/// `_useTallViewport` above: that helper's 1200x3600 viewport is precisely
/// what hides the defect this group reproduces (#633) — at that height the
/// completed state's extra `todo-detail-completed-at` row never pushes
/// content anywhere near the FAB's band.
void _useViewport(WidgetTester tester, Size viewport) {
  tester.view.physicalSize = viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Reproduces #633 (FR-TD-1, FR-UX-1, D-18): on a completed todo, the
/// full-width honey "Reabrir"/Reopen [PrimaryActionButton] and the honey
/// "Editar tarefa"/Edit [FloatingActionButton] occupy the same band with the
/// FAB on top, clipping the button's label and stealing roughly the right
/// 45% of its tap area — a tap there opens the edit form instead of
/// reopening the todo.
///
/// The screen already carries `BrandDimens.scrollBottomInset` as its scroll
/// bottom padding, and that inset is larger than the FAB's band — but an
/// inset only guarantees clearance at MAXIMUM scroll extent. The completed
/// state adds the `todo-detail-completed-at` row, pushing content one row
/// past the viewport, so AT REST (no scrolling) the button renders inside
/// the FAB's band. That asymmetry is exactly why the defect doesn't appear
/// before completion: the open state's content is one row shorter and
/// doesn't reach the FAB.
///
/// The fix (mirroring #357's pinned-action pattern, already used by
/// todo_form_screen.dart) is to pin the primary action in a bar OUTSIDE the
/// scroll view and drop the FAB entirely, replacing it with a demoted
/// secondary action in the same bar — which is what turns every assertion
/// below from red to green.
void _pinnedActionTests() {
  group('the primary action does not collide with the edit FAB (#633, '
      'FR-TD-1, FR-UX-1, D-18)', () {
    // The handset #766 tested the sibling form screen's own pinned-action
    // fix at — short enough that the completed state's extra row overflows
    // the viewport and collides with the FAB's band.
    const shortViewport = Size(400, 640);

    Future<void> openAt(
      WidgetTester tester, {
      required _FakeTodosRepository repo,
      Size viewport = shortViewport,
    }) async {
      _useViewport(tester, viewport);
      await tester.pumpWidget(_buildApp(repo: repo));
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(AppShell)));
      router.go('/todos/t1');
      await tester.pumpAndSettle();
    }

    testWidgets(
      'the toggle button is fully on-screen with no scrolling, open and '
      'completed alike',
      (tester) async {
        final open = _FakeTodosRepository(_todo());
        await openAt(tester, repo: open);

        final toggle = find.byKey(
          const Key('todo-detail-complete-toggle-button'),
        );
        expectFullyOnScreen(
          tester,
          toggle,
          reason:
              'the complete toggle must be reachable without scrolling on '
              'a $shortViewport viewport (open state)',
        );
        expectMinTapTarget(tester, toggle);

        final done = _FakeTodosRepository(
          _todo(status: 'done', completedAt: '2026-07-01T10:00:00Z'),
        );
        await openAt(tester, repo: done);

        expectFullyOnScreen(
          tester,
          toggle,
          reason:
              'the reopen toggle must be reachable without scrolling on a '
              '$shortViewport viewport (completed state, one row taller)',
        );
        expectMinTapTarget(tester, toggle);
      },
    );

    testWidgets(
      'tapping the trailing edge of the Reopen button reopens the todo, '
      'it does not open the edit form',
      (tester) async {
        final repo = _FakeTodosRepository(
          _todo(status: 'done', completedAt: '2026-07-01T10:00:00Z'),
        );
        await openAt(tester, repo: repo);

        // Derive the drag from geometry rather than a fixed offset, so the
        // reproduction is deterministic rather than a viewport lottery:
        // drag the fields card until the toggle button's centre lines up
        // with the FAB's centre, i.e. maximum overlap. Guarded on the FAB
        // still existing so this same test keeps working once the fix
        // removes it — the pinned button is then never dragged and a plain
        // trailing-edge tap must still reopen without navigating, which is
        // the regression this test protects going forward.
        final fabFinder = find.byType(FloatingActionButton);
        if (fabFinder.evaluate().isNotEmpty) {
          final fabRect = tester.getRect(fabFinder);
          final buttonRect = tester.getRect(
            find.byKey(const Key('todo-detail-complete-toggle-button')),
          );
          await tester.drag(
            find.byKey(const Key('todo-detail-fields')),
            Offset(0, fabRect.center.dy - buttonRect.center.dy),
          );
          await tester.pumpAndSettle();
        }

        final r = tester.getRect(
          find.byKey(const Key('todo-detail-complete-toggle-button')),
        );
        // tapAt, not tap: tap's `warnIfMissed` would turn a real overlap
        // into a mere console warning instead of actually hitting whatever
        // widget is topmost at that point, so it could mask the defect.
        await tester.tapAt(r.centerRight - const Offset(2, 0));
        await tester.pumpAndSettle();

        expect(
          repo.reopened,
          ['t1'],
          reason:
              'tapping the trailing edge of the Reopen button must reopen '
              'the todo — today the FAB steals that tap and this fails',
        );
        expect(
          find.byKey(const Key('todo-title-field')),
          findsNothing,
          reason:
              'the tap must not have navigated to the edit form (the exact '
              'reported symptom of #633)',
        );
      },
    );

    testWidgets(
      'no floating action button ever overlaps the primary action, even '
      'mid-scroll',
      (tester) async {
        // Written as an invariant, not "the FAB is gone": vacuously true
        // once the FAB is removed by this fix, and still meaningful if a
        // FAB is ever reintroduced on this screen.
        final repo = _FakeTodosRepository(
          _todo(status: 'done', completedAt: '2026-07-01T10:00:00Z'),
        );
        await openAt(tester, repo: repo);

        // Unconditional: this fix removes the FAB entirely, so the guarded
        // loop below over `find.byType(FloatingActionButton)` would
        // otherwise run zero iterations and assert nothing — passing
        // whether the fix is present, reverted, or broken. This fails
        // immediately if a FAB ever reappears on this screen.
        expect(find.byType(FloatingActionButton), findsNothing);

        final fabs = find.byType(FloatingActionButton);
        if (fabs.evaluate().isNotEmpty) {
          final fabRect = tester.getRect(fabs.first);
          final buttonRect = tester.getRect(
            find.byKey(const Key('todo-detail-complete-toggle-button')),
          );
          await tester.drag(
            find.byKey(const Key('todo-detail-fields')),
            Offset(0, fabRect.center.dy - buttonRect.center.dy),
          );
          await tester.pumpAndSettle();
        }

        final primaryRect = tester.getRect(
          find.byKey(const Key('todo-detail-complete-toggle-button')),
        );
        for (final element in find.byType(FloatingActionButton).evaluate()) {
          final fabRect = tester.getRect(find.byWidget(element.widget));
          expect(
            fabRect.overlaps(primaryRect),
            isFalse,
            reason:
                'a FloatingActionButton must never overlap the primary '
                'complete/reopen action ($fabRect vs $primaryRect)',
          );
        }
      },
    );
  });
}

/// #787 (FR-UX-1): the top-align sweep #630/#769 started, applied to this
/// screen's own content wrapper.
///
/// This screen sizes its own view rather than reusing `_useTallViewport`
/// above: at 1200x3600 there is no leftover height question to ask.
void _layoutTests() {
  group('TodoDetailScreen — layout at 1024x1366 (#787, FR-UX-1)', () {
    Future<void> openAt(
      WidgetTester tester, {
      _FakeTodosRepository? repo,
      Stream<Todo?> Function()? detail,
      bool settle = true,
    }) async {
      _useViewport(tester, kTabletViewport);
      await tester.pumpWidget(
        _buildApp(
          repo: repo ?? _FakeTodosRepository(_todo()),
          detailStream: detail,
        ),
      );
      await tester.pumpAndSettle();
      final router = GoRouter.of(tester.element(find.byType(AppShell)));
      router.go('/todos/t1');
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
      // ignore: avoid_print
      print(
        'PROBE pinned column: ${tester.getRect(find.ancestor(of: find.byKey(const Key("todo-detail-complete-toggle-button")), matching: find.byType(LayoutBuilder)).first)}',
      );

      expectStartsAtContentTop(
        tester,
        find.ancestor(
          of: find.byKey(const Key('todo-detail-header')),
          matching: find.byType(SingleChildScrollView),
        ),
        // Anchored on the navigation shell, not an AppBar: this screen has
        // none of its own — the shell owns the header and hands the route the
        // region below it (and stacks the offline/needs-fix banners in
        // between, so the assertion keeps meaning something if one shows).
        anchor: find.byType(StatefulNavigationShell),
        from: ContentTopAnchor.inside,
        label: "the to-do's detail card stack",
      );
    });

    // The other half of the change: only the `data` branch top-aligns. These
    // two fail if the alignment wrapper is ever hoisted above
    // `todoAsync.when` — the mistake #630 had to undo on the journey stats
    // screen.
    testWidgets('the loading spinner stays vertically centred', (tester) async {
      await openAt(tester, detail: pendingStream<Todo?>, settle: false);

      expectVerticallyCentredIn(
        tester,
        find.byType(CircularProgressIndicator),
        region: tester.getRect(find.byType(StatefulNavigationShell)),
      );
    });

    testWidgets('the error message stays vertically centred', (tester) async {
      await openAt(
        tester,
        detail: () => Stream<Todo?>.error(Exception('boom')),
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
