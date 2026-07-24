import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/powersync_schema.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/history/history_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixtures mirroring apiary_detail_screen_test.dart's own (file-private
/// there, so re-declared here — this suite's own convention).
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

const _apiary = Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3);

HistoryEntry _entry({
  required String id,
  HistoryEventKind kind = HistoryEventKind.updated,
  String? actor = 'test-user',
  List<String> changedFields = const ['name'],
  required DateTime recordedAt,
}) => HistoryEntry(
  id: id,
  entityType: apiaryEntityType,
  entityId: 'a1',
  kind: kind,
  actorUserId: actor,
  recordedAt: recordedAt,
  changedFields: changedFields,
);

Widget _buildApp({
  required List<HistoryEntry> history,
  Map<String, String> memberNames = const {},
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith(
        (ref) => Stream.value(const [_apiary]),
      ),
      // Tasks is the app's landing screen now (#427, D-29) — stub its stream
      // so booting the app renders the Todos tab without hanging on the real,
      // never-resolving todos repository chain.
      todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
      apiaryByIdProvider.overrideWith((ref, id) => Stream.value(_apiary)),
      apiaryCountersProvider.overrideWith(
        (ref, id) => Stream.value(const <ApiaryCounter>[]),
      ),
      activitiesByApiaryProvider.overrideWith(
        (ref, apiaryId) => Stream.value(const <Activity>[]),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
      memberNamesProvider.overrideWith((ref) async => memberNames),
      entityHistoryProvider.overrideWith(
        (ref, target) => Stream.value(history),
      ),
    ],
    child: const BeekeepingitApp(),
  );
}

Future<void> _openDetail(
  WidgetTester tester, {
  required List<HistoryEntry> history,
  Map<String, String> memberNames = const {},
}) async {
  await tester.pumpWidget(
    _buildApp(history: history, memberNames: memberNames),
  );
  await tester.pumpAndSettle();
  // The app now lands on the Tasks tab (#427, D-29); switch to the Apiaries
  // tab before interacting with the apiaries list.
  await tester.tap(find.byKey(const Key('shell-tab-apiaries')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('apiary-a1')));
  await tester.pumpAndSettle();
}

/// Scrolls the history section into view — it sits below the activities
/// section at the bottom of the detail page's scroll view.
Future<void> _scrollToHistory(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('history-section')));
  await tester.pumpAndSettle();
}

void main() {
  group('per-entity history timeline (#60, FR-HIS-1, history.md §8)', () {
    testWidgets('renders on the entity detail screen, newest entry first', (
      tester,
    ) async {
      await _openDetail(
        tester,
        history: [
          _entry(id: 'h2', recordedAt: DateTime.utc(2026, 7, 19, 10)),
          _entry(
            id: 'h1',
            kind: HistoryEventKind.created,
            changedFields: const [],
            recordedAt: DateTime.utc(2026, 7, 18, 10),
          ),
        ],
      );
      await _scrollToHistory(tester);

      expect(find.byKey(const Key('history-section')), findsOneWidget);
      expect(find.text('History'), findsOneWidget);
      expect(find.text('Updated'), findsOneWidget);
      expect(find.text('Created'), findsOneWidget);
      // The update entry names which fields changed, under their localized
      // labels rather than raw column names.
      expect(find.text('Changed: Name'), findsOneWidget);
    });

    testWidgets('attributes each entry to its actor and time', (tester) async {
      await _openDetail(
        tester,
        history: [
          _entry(
            id: 'h1',
            actor: 'test-user',
            recordedAt: DateTime.utc(2026, 7, 19, 10),
          ),
          _entry(
            id: 'h2',
            actor: 'other',
            recordedAt: DateTime.utc(2026, 7, 18, 10),
          ),
        ],
        memberNames: const {'other': 'Ana Silva'},
      );
      await _scrollToHistory(tester);

      // The signed-in user reads as "You"; a roster hit reads as the real
      // name (#44's resolution, reused here).
      expect(find.textContaining('You ·'), findsOneWidget);
      expect(find.textContaining('Ana Silva ·'), findsOneWidget);
    });

    testWidgets('shows a superseded LWW loss rather than hiding it', (
      tester,
    ) async {
      await _openDetail(
        tester,
        history: [
          _entry(
            id: 'c1',
            kind: HistoryEventKind.superseded,
            changedFields: const [],
            recordedAt: DateTime.utc(2026, 7, 19, 10),
          ),
        ],
      );
      await _scrollToHistory(tester);

      // history.md §6: "LWW losers ... surfaced as a superseded timeline
      // event, not silently overwritten".
      expect(find.text('Superseded'), findsOneWidget);
      expect(
        find.text('Replaced by a newer version from another device'),
        findsOneWidget,
      );
    });

    testWidgets('empty history reads as empty, not as an error', (
      tester,
    ) async {
      // Also the offline/never-synced case: no local slice and no reachable
      // fallback is a legitimately empty timeline.
      await _openDetail(tester, history: const []);
      await _scrollToHistory(tester);

      expect(find.byKey(const Key('history-empty')), findsOneWidget);
      expect(find.text('No changes recorded yet'), findsOneWidget);
      expect(find.byKey(const Key('history-view-all-button')), findsNothing);
    });

    testWidgets('caps the embedded preview and links to the full timeline', (
      tester,
    ) async {
      await _openDetail(
        tester,
        history: [
          for (var i = 0; i < 8; i++)
            _entry(
              id: 'h$i',
              recordedAt: DateTime.utc(
                2026,
                7,
                19,
                10,
              ).subtract(Duration(days: i)),
            ),
        ],
      );
      await _scrollToHistory(tester);

      // A shrink-wrapped list can't virtualize, so the preview caps at 5 and
      // defers the rest — same constraint as the activities section above it.
      expect(find.text('Updated'), findsNWidgets(5));
      expect(find.byKey(const Key('history-view-all-button')), findsOneWidget);
    });

    testWidgets('view-all opens the full, uncapped history screen', (
      tester,
    ) async {
      // A taller viewport than the 800x600 default: at 600 the view-all
      // link lands in the bottom strip the detail screen's FAB column
      // occupies, so the tap resolves to a FAB instead of the link. Real
      // devices scroll it clear; the test just needs the room.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await _openDetail(
        tester,
        history: [
          for (var i = 0; i < 8; i++)
            _entry(
              id: 'h$i',
              recordedAt: DateTime.utc(
                2026,
                7,
                19,
                10,
              ).subtract(Duration(days: i)),
            ),
        ],
      );
      await _scrollToHistory(tester);
      await tester.tap(find.byKey(const Key('history-view-all-button')));
      await tester.pumpAndSettle();

      // The full screen virtualizes, so it isn't capped at the preview limit.
      expect(find.text('History'), findsWidgets);
      expect(find.byKey(const Key('history-section')), findsNothing);
      expect(find.text('Updated'), findsNWidgets(8));
    });

    testWidgets('announces each entry as one sentence to a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _openDetail(
        tester,
        history: [
          _entry(
            id: 'h1',
            kind: HistoryEventKind.created,
            changedFields: const [],
            recordedAt: DateTime.utc(2026, 7, 19, 10),
          ),
        ],
      );
      await _scrollToHistory(tester);

      // WCAG 2.2 AA: the visually-separate event/actor/time lines collapse
      // into a single announcement instead of three orphaned fragments.
      expect(
        find.bySemanticsLabel(RegExp(r'^Created by You, .+')),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
