import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_widgets.dart';
import 'notification_settings_repository.dart';

/// The account/settings screen's "Notifications" section (FR-ST-1, D-24,
/// #81): a master "Enable notifications" switch, and the container the
/// per-event notification-toggle list renders into.
///
/// [eventTogglesSlot] is that container's content — `null` until #288 lands
/// (shown as a short placeholder instead), then the real per-event toggle
/// list once that story wires one in. This story doesn't build the toggle
/// list or the per-event preference-key contract (#82 owns that); it only
/// builds the one preference it does own — the master switch — and the slot
/// #288 needs to exist inside.
///
/// AC "invalid combinations are prevented": while the master switch is off,
/// the slot is visually dimmed and its taps are ignored — individual event
/// toggles (once #288 adds them) can't be meaningfully turned on while
/// notifications overall are off, so this container prevents that
/// inconsistent state by construction rather than leaving it to #288 to
/// re-implement.
class NotificationSettingsSection extends ConsumerWidget {
  const NotificationSettingsSection({super.key, this.eventTogglesSlot});

  final Widget? eventTogglesSlot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final enabled = ref.watch(notificationsEnabledProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.accountNotificationsSectionTitle),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('settings-notifications-enabled-toggle'),
          contentPadding: EdgeInsets.zero,
          title: Text(l10n.settingsNotificationsEnabledLabel),
          subtitle: Text(l10n.settingsNotificationsEnabledHint),
          value: enabled,
          onChanged: (value) =>
              ref.read(notificationsEnabledProvider.notifier).setEnabled(value),
        ),
        Semantics(
          container: true,
          enabled: enabled,
          child: IgnorePointer(
            key: const Key('settings-notification-events-slot'),
            ignoring: !enabled,
            child: AnimatedOpacity(
              opacity: enabled ? 1 : 0.5,
              duration: const Duration(milliseconds: 150),
              child:
                  eventTogglesSlot ??
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      l10n.settingsNotificationEventsComingSoon,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
            ),
          ),
        ),
      ],
    );
  }
}
