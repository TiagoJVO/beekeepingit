import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/notifications/notification_checker.dart';
import 'package:beekeepingit_client/features/notifications/notification_dedup_store.dart';
import 'package:beekeepingit_client/features/notifications/notification_events.dart';
import 'package:beekeepingit_client/features/notifications/notification_preferences_repository.dart';
import 'package:beekeepingit_client/features/settings/notification_event_toggles_list.dart';
import 'package:beekeepingit_client/features/settings/notification_settings_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalPrefs] fake — same convention as
/// `notification_preferences_repository_test.dart`/
/// `notification_settings_section_test.dart`.
class _FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> _store = {};

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

Widget _buildList({LocalPrefs? prefs, Locale locale = const Locale('en')}) {
  final resolvedPrefs = prefs ?? _FakeLocalPrefs();
  return ProviderScope(
    overrides: [
      notificationPreferencesRepositoryProvider.overrideWithValue(
        NotificationPreferencesRepository(prefs: resolvedPrefs),
      ),
    ],
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      home: const Scaffold(body: NotificationEventTogglesList()),
    ),
  );
}

Key _toggleKey(String eventKey) =>
    Key('settings-notification-event-toggle-$eventKey');

Todo _overdueTodo(String id) => Todo(
  id: id,
  title: 'Feed hive $id',
  priority: 'medium',
  status: 'open',
  dueDate: '2020-01-01',
);

void main() {
  group('NotificationEventTogglesList (#288)', () {
    testWidgets(
      'renders one toggle per v1 catalog event, all defaulting to enabled',
      (tester) async {
        await tester.pumpWidget(_buildList());
        await tester.pumpAndSettle();

        for (final eventKey in knownNotificationEvents) {
          final toggle = tester.widget<SwitchListTile>(
            find.byKey(_toggleKey(eventKey)),
          );
          expect(
            toggle.value,
            isTrue,
            reason: '$eventKey should default to enabled',
          );
        }
      },
    );

    testWidgets('reflects a previously-persisted per-event preference', (
      tester,
    ) async {
      final prefs = _FakeLocalPrefs();
      NotificationPreferencesRepository(prefs: prefs)
          .setEnabled(notificationEventSyncFailure, false);

      await tester.pumpWidget(_buildList(prefs: prefs));
      await tester.pumpAndSettle();

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(_toggleKey(notificationEventSyncFailure)),
      );
      expect(toggle.value, isFalse);
      // Untouched events stay at their default.
      final other = tester.widget<SwitchListTile>(
        find.byKey(_toggleKey(notificationEventTodoDueReminder)),
      );
      expect(other.value, isTrue);
    });

    testWidgets('tapping a toggle persists the new value for that event only', (
      tester,
    ) async {
      final prefs = _FakeLocalPrefs();
      await tester.pumpWidget(_buildList(prefs: prefs));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(_toggleKey(notificationEventSyncSuccess)));
      await tester.pumpAndSettle();

      final repo = NotificationPreferencesRepository(prefs: prefs);
      expect(repo.isEnabled(notificationEventSyncSuccess), isFalse);
      expect(repo.isEnabled(notificationEventTodoDueReminder), isTrue);

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(_toggleKey(notificationEventSyncSuccess)),
      );
      expect(toggle.value, isFalse);
    });

    testWidgets(
      'a toggled-off preference survives a simulated app restart (fresh '
      'widget/provider tree reading the same underlying store)',
      (tester) async {
        final prefs = _FakeLocalPrefs();
        await tester.pumpWidget(_buildList(prefs: prefs));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(_toggleKey(notificationEventSyncConflict)));
        await tester.pumpAndSettle();

        // Simulate an app restart: tear down and rebuild an entirely new
        // widget/provider tree against the same durable store.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(_buildList(prefs: prefs));
        await tester.pumpAndSettle();

        final toggle = tester.widget<SwitchListTile>(
          find.byKey(_toggleKey(notificationEventSyncConflict)),
        );
        expect(toggle.value, isFalse);
      },
    );

    testWidgets('disabling an event via this toggle list stops it from the '
        'notification engine (#82) on the very next check — AC: "disabling '
        'an event type stops its notifications"', (tester) async {
      final prefs = _FakeLocalPrefs();
      await tester.pumpWidget(_buildList(prefs: prefs));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(_toggleKey(notificationEventTodoDueReminder)),
      );
      await tester.pumpAndSettle();

      // A brand-new engine instance (mirrors a fresh app-open check)
      // reading the SAME underlying store the widget just wrote to.
      final checker = NotificationChecker(
        dedupStore: NotificationDedupStore(prefs: prefs),
        preferences: NotificationPreferencesRepository(prefs: prefs),
        settings: NotificationSettingsRepository(prefs: prefs),
      );
      final result = checker.check(
        todos: [_overdueTodo('t1')],
        today: DateTime(2026, 7, 27),
        pendingCount: 0,
        rejectedOpIds: const {},
      );

      expect(result, isEmpty);
    });

    testWidgets(
      'each toggle has a distinct, non-empty accessible label and a tap '
      'action (WCAG 2.2 AA)',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(_buildList());
        await tester.pumpAndSettle();

        final labels = <String>{};
        for (final eventKey in knownNotificationEvents) {
          final node = tester.getSemantics(find.byKey(_toggleKey(eventKey)));
          expect(node.label, isNotEmpty);
          expect(
            node.getSemanticsData().hasAction(SemanticsAction.tap),
            isTrue,
          );
          labels.add(node.label);
        }
        // No two rows share a label — a screen-reader user can tell them
        // apart.
        expect(labels, hasLength(knownNotificationEvents.length));

        handle.dispose();
      },
    );

    testWidgets('renders localized Portuguese labels', (tester) async {
      await tester.pumpWidget(_buildList(locale: const Locale('pt')));
      await tester.pumpAndSettle();

      final context = tester.element(find.byType(NotificationEventTogglesList));
      final l10n = AppLocalizations.of(context);
      expect(find.text(l10n.notificationEventTodoDueLabel), findsOneWidget);
      expect(find.text(l10n.notificationEventSyncFailureLabel), findsOneWidget);
      expect(find.text(l10n.notificationEventSyncSuccessLabel), findsOneWidget);
      expect(
        find.text(l10n.notificationEventSyncConflictLabel),
        findsOneWidget,
      );
      // Sanity check this is genuinely Portuguese, not an English fallback.
      expect(l10n.localeName, 'pt_PT');
    });
  });
}
