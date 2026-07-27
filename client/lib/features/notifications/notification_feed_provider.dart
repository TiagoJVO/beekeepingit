import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'notification_models.dart';

/// The queue of in-app notifications produced by app-open/foreground checks
/// (#82, D-24), waiting to be shown. A queue (append, not replace) — not a
/// single "latest batch" — so that if the app-open check and a foreground-
/// resume check both publish before `shell/app_shell.dart`'s toast listener
/// has drained the previous batch, nothing is silently overwritten and
/// lost; every queued notification is still delivered once
/// `app_shell.dart` next has a chance to show it.
class NotificationFeedController extends Notifier<List<AppNotification>> {
  @override
  List<AppNotification> build() => const [];

  /// Adds [notifications] to the pending queue. A no-op for an empty list —
  /// callers run this after every check regardless of whether anything new
  /// was detected, and an empty publish must not spuriously notify listeners
  /// with a new (if content-equal) list instance.
  void publish(List<AppNotification> notifications) {
    if (notifications.isEmpty) return;
    state = [...state, ...notifications];
  }

  /// Marks every currently-queued notification as delivered — called by the
  /// one place that actually renders them (`app_shell.dart`'s toast
  /// listener) right after showing each, so the same batch is never shown
  /// twice.
  void drain() => state = const [];
}

final notificationFeedProvider =
    NotifierProvider<NotificationFeedController, List<AppNotification>>(
      NotificationFeedController.new,
    );
