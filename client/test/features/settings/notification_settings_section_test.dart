import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/settings/notification_settings_repository.dart';
import 'package:beekeepingit_client/features/settings/notification_settings_section.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalPrefs] fake — same convention as the repository tests.
class _FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> _store = {};

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

Widget _buildSection({LocalPrefs? prefs, Widget? eventTogglesSlot}) {
  return ProviderScope(
    overrides: [
      notificationSettingsRepositoryProvider.overrideWithValue(
        NotificationSettingsRepository(prefs: prefs ?? _FakeLocalPrefs()),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      home: Scaffold(
        body: NotificationSettingsSection(eventTogglesSlot: eventTogglesSlot),
      ),
    ),
  );
}

void main() {
  group('NotificationSettingsSection (#81)', () {
    testWidgets('shows the master switch, defaulting to enabled', (
      tester,
    ) async {
      await tester.pumpWidget(_buildSection());
      await tester.pumpAndSettle();

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('settings-notifications-enabled-toggle')),
      );
      expect(toggle.value, isTrue);
    });

    testWidgets('reflects a previously-persisted disabled preference', (
      tester,
    ) async {
      final prefs = _FakeLocalPrefs();
      NotificationSettingsRepository(
        prefs: prefs,
      ).setNotificationsEnabled(false);

      await tester.pumpWidget(_buildSection(prefs: prefs));
      await tester.pumpAndSettle();

      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('settings-notifications-enabled-toggle')),
      );
      expect(toggle.value, isFalse);
    });

    testWidgets('tapping the switch persists the new value', (tester) async {
      final prefs = _FakeLocalPrefs();
      await tester.pumpWidget(_buildSection(prefs: prefs));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('settings-notifications-enabled-toggle')),
      );
      await tester.pumpAndSettle();

      expect(
        NotificationSettingsRepository(prefs: prefs).isNotificationsEnabled(),
        isFalse,
      );
      final toggle = tester.widget<SwitchListTile>(
        find.byKey(const Key('settings-notifications-enabled-toggle')),
      );
      expect(toggle.value, isFalse);
    });

    testWidgets(
      'shows a placeholder in the events slot before #288 supplies one',
      (tester) async {
        await tester.pumpWidget(_buildSection());
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('settings-notification-events-slot')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'renders the given eventTogglesSlot inside the container (#288\'s '
      'insertion point)',
      (tester) async {
        await tester.pumpWidget(
          _buildSection(
            eventTogglesSlot: const Text(
              'fake per-event toggle list',
              key: Key('fake-event-toggles'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('fake-event-toggles')), findsOneWidget);
      },
    );

    testWidgets(
      'disables (ignores taps on) the events slot while the master switch '
      'is off — AC: invalid combinations are prevented',
      (tester) async {
        await tester.pumpWidget(
          _buildSection(
            eventTogglesSlot: const Text(
              'fake per-event toggle list',
              key: Key('fake-event-toggles'),
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('settings-notifications-enabled-toggle')),
        );
        await tester.pumpAndSettle();

        final ignorePointer = tester.widget<IgnorePointer>(
          find.byKey(const Key('settings-notification-events-slot')),
        );
        expect(ignorePointer.ignoring, isTrue);
      },
    );

    testWidgets('the master switch has an accessible label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_buildSection());
      await tester.pumpAndSettle();

      final node = tester.getSemantics(
        find.byKey(const Key('settings-notifications-enabled-toggle')),
      );
      expect(node.label, isNotEmpty);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

      handle.dispose();
    });
  });
}
