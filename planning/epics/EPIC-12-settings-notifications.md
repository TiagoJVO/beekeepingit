# EPIC-12 — Settings & Notifications

- **Milestone:** M3
- **Phase:** PWA
- **Labels:** type/epic, area/offline-sync
- **Requirements:** FR-ST-1, NFR-TST-1
- **Depends on:** EPIC-05, EPIC-06
- **Spikes:** none
- **Summary:** Let users customize app settings — notification preferences, data-sync settings, and other options — and provide a notification system for relevant events (todo due, sync results) with a delivery channel to be decided. Builds on the offline/sync foundation and the todo model.

## Stories

### [Feature] App settings: notification prefs, sync settings, etc.
- **Labels:** type/feature, area/offline-sync, priority/medium
- **Requirements:** FR-ST-1, NFR-TST-1
- **Milestone:** M3
- **Depends on:** EPIC-06 (offline & sync)
- **Acceptance criteria:**
  - [ ] A settings screen lets users customize app settings, including notification preferences and data-sync settings (FR-ST-1)
  - [ ] Settings persist per user and survive app restarts, and sync-related preferences are honored by the EPIC-06 sync layer
  - [ ] Notification preferences set here are honored by the notification system (e.g. enabling/disabling event types)
  - [ ] The settings screen meets the EN+PT i18n and WCAG 2.2 AA accessibility baselines from EPIC-11
  - [ ] Changing a setting takes effect without requiring a reinstall, and invalid combinations are prevented or validated
  - [ ] Settings persistence and the effect of toggling preferences are covered by automated tests (NFR-TST-1)
- **Notes:** Customizable settings per FR-ST-1 (notification prefs, sync settings, other options). Sync settings tie into EPIC-06; i18n/a11y from EPIC-11. **Suggested label:** area/settings — no exact settings label exists in labels.yml; using area/offline-sync as the closest (sync settings) until a settings label is added.

### [Feature] Notification system: events (todo due, sync results) + channel decision
- **Labels:** type/feature, area/offline-sync, area/todos, priority/medium
- **Requirements:** FR-ST-1, FR-TD-1, NFR-TST-1
- **Milestone:** M3
- **Depends on:** EPIC-05 (Todos), EPIC-06 (offline & sync), EPIC-12 (app settings)
- **Acceptance criteria:**
  - [ ] The system generates notifications for defined events, at minimum todo due dates and sync results, per Q-NOTIF (FR-ST-1, FR-TD-1)
  - [ ] The delivery channel is implemented per the Q-NOTIF decision (e.g. in-app and/or push); the chosen channel(s) are documented (Q-NOTIF)
  - [ ] Notifications respect the user's notification preferences from the settings screen (a disabled event type produces no notification)
  - [ ] Todo-due notifications fire relative to the todo's due date and priority, and sync-result notifications reflect success/failure/conflict outcomes from EPIC-06
  - [ ] Notification content is localized (EN+PT) and accessible, consistent with EPIC-11
  - [ ] Notification generation and preference-gating are covered by automated tests (NFR-TST-1)
- **Notes:** Events and delivery channel are open under Q-NOTIF (what events exist, in-app vs. push, whether push needs a backend + store registration) — resolve before finalizing. Todo-due events depend on the EPIC-05 todo model (due date/priority, Q-TODO); sync-result events depend on EPIC-06. **Suggested label:** area/notifications — no notifications label exists in labels.yml; using area/offline-sync (sync-result events) + area/todos (todo-due events) as the closest until a notifications label is added.
