import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/gen/app_localizations.dart';
import '../notifications/notification_events.dart';
import '../notifications/notification_preferences_repository.dart';

/// The per-event notification-toggle list (#288, FR-ST-1, FR-TD-1, D-24):
/// one [SwitchListTile] per entry in the notification engine's v1 event
/// catalog (`notification_events.dart`'s `knownNotificationEvents`, owned by
/// #82), reading/writing through the SAME [notificationPreferencesProvider]
/// the engine itself reads at every app-open/foreground check
/// (`notification_checker.dart`'s `NotificationChecker.check`). That method
/// re-reads the repository fresh on every call rather than caching a
/// snapshot, so a toggle flipped here takes effect on the very next check —
/// no extra wiring needed on this story's side for "the engine honors a
/// toggle change immediately".
///
/// Rendered as [NotificationSettingsSection]'s `eventTogglesSlot`
/// (`notification_settings_section.dart`, from `account_screen.dart`) — that
/// container already owns the section header and the master on/off switch
/// (including dimming/ignoring taps on this list while the master switch is
/// off), so this widget only owns the per-event rows themselves.
///
/// Reviewer note: the master switch
/// (`notification_settings_repository.dart`'s `kNotificationsEnabledKey`,
/// #81) and this per-event map (`kNotificationPreferencesKey`, #82) are
/// deliberately separate preferences — not merged here. Both
/// `NotificationChecker.check` and `app_shell.dart`'s real-time
/// sync-conflict toast listener consult the master switch in addition to
/// this per-event map (FR-ST-1, D-24, #500), so turning "Enable
/// notifications" off does stop delivery — see
/// `core/storage/local_prefs.dart`'s `kNotificationsEnabledKey` doc. This
/// widget still only owns rendering the per-event rows themselves; the
/// master-switch gate lives entirely in the engine/display sites above.
class NotificationEventTogglesList extends ConsumerWidget {
  const NotificationEventTogglesList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final prefs = ref.watch(notificationPreferencesProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final eventKey in knownNotificationEvents)
          _EventToggleRow(
            eventKey: eventKey,
            enabled: prefs[eventKey] ?? notificationEventDefaultEnabled,
            copy: _copyFor(l10n, eventKey),
            onChanged: (value) => ref
                .read(notificationPreferencesProvider.notifier)
                .setEnabled(eventKey, value),
          ),
      ],
    );
  }
}

/// The localized title + explanatory subtitle for one catalog event's row.
class _EventCopy {
  const _EventCopy(this.label, this.hint);

  final String label;
  final String hint;
}

/// Resolves an event key (`notification_events.dart`'s catalog) to its row
/// copy. A `switch` over plain string constants can't be exhaustiveness
/// checked by the compiler the way an enum can — the `_` case documents that
/// this must be kept in sync with `knownNotificationEvents` by hand; the
/// widget test that iterates the full catalog and asserts every row renders
/// is the guard against silent drift.
_EventCopy _copyFor(AppLocalizations l10n, String eventKey) =>
    switch (eventKey) {
      notificationEventTodoDueReminder => _EventCopy(
        l10n.notificationEventTodoDueLabel,
        l10n.notificationEventTodoDueHint,
      ),
      notificationEventSyncFailure => _EventCopy(
        l10n.notificationEventSyncFailureLabel,
        l10n.notificationEventSyncFailureHint,
      ),
      notificationEventSyncSuccess => _EventCopy(
        l10n.notificationEventSyncSuccessLabel,
        l10n.notificationEventSyncSuccessHint,
      ),
      notificationEventSyncConflict => _EventCopy(
        l10n.notificationEventSyncConflictLabel,
        l10n.notificationEventSyncConflictHint,
      ),
      _ => throw ArgumentError('Unknown notification event key: $eventKey'),
    };

/// One catalog event's row — mirrors the master switch's own
/// `SwitchListTile` shape (`notification_settings_section.dart`) for visual
/// consistency, and its default zero content padding so rows align with the
/// rest of the settings screen's edge-to-edge sections.
class _EventToggleRow extends StatelessWidget {
  const _EventToggleRow({
    required this.eventKey,
    required this.enabled,
    required this.copy,
    required this.onChanged,
  });

  final String eventKey;
  final bool enabled;
  final _EventCopy copy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      key: Key('settings-notification-event-toggle-$eventKey'),
      contentPadding: EdgeInsets.zero,
      title: Text(copy.label),
      subtitle: Text(copy.hint),
      value: enabled,
      onChanged: onChanged,
    );
  }
}
