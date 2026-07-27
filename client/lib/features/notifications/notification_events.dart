/// The v1 in-app notification event catalog (#82, D-24, FR-ST-1) — the
/// **preference-key contract** this story owns: the stable string keys the
/// per-event toggle list (#288, rendered inside the #81 settings screen)
/// reads/writes against, and this engine gates delivery on. Mirrors
/// `todo_priority.dart`'s own convention (top-level string constants +
/// callers switch on them) rather than a Dart `enum` — the enum equivalent
/// would still need a stable wire-format string for local persistence
/// (notification_preferences_repository.dart's JSON blob), so a plain string
/// avoids maintaining two parallel vocabularies for the same four values.
///
/// Two `sync_*` families exist because D-24 names them as **separate**
/// events a user can individually mute: a push failure that needs fixing
/// (FR-OF-2's notify-and-fix rule) is a distinct concern from a plain
/// completion notice, and this issue's own acceptance criteria additionally
/// calls out "conflict" (an offline edit superseded by a newer write,
/// sync.md §4.2/§8) as its own event — already delivered today as a
/// real-time toast (`shell/sync_status.dart`'s `supersededNotificationProvider`,
/// #58); this catalog just adds the missing preference gate for it rather
/// than re-detecting something the sync engine already surfaces live.
const notificationEventTodoDueReminder = 'todo_due_reminder';
const notificationEventSyncFailure = 'sync_failure';
const notificationEventSyncSuccess = 'sync_success';
const notificationEventSyncConflict = 'sync_conflict';

/// Every known v1 event key, in catalog order — what #288's toggle list
/// iterates to render one row per event.
const knownNotificationEvents = [
  notificationEventTodoDueReminder,
  notificationEventSyncFailure,
  notificationEventSyncSuccess,
  notificationEventSyncConflict,
];

/// v1 default for an event absent from stored preferences (first run, or a
/// newer event this client version didn't know about when the value was
/// last written): **enabled**. The toggle list is an opt-OUT control — a
/// user who never opens Settings still gets due-date reminders and sync
/// results, matching D-24's framing of these as the app's default in-app
/// notification behavior, not an opt-in feature.
const notificationEventDefaultEnabled = true;
