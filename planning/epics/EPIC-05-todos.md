# EPIC-05 — Todos

- **Milestone:** M2
- **Phase:** PWA
- **Labels:** type/epic, area/todos
- **Requirements:** FR-TD-1, NFR-TST-1
- **Depends on:** EPIC-02
- **Spikes:** none
- **Summary:** Lightweight task management for beekeepers — create todos with title, description, due date, and priority, manage their lifecycle, associate them with an apiary or area, and access them quickly from the main screen, apiaries list, and apiary detail. Works offline like the rest of the field app.

## Stories

### [Feature] Todo model + lifecycle (create/complete/reopen/edit/delete)
- **Labels:** type/feature, area/todos, area/offline-sync, priority/high
- **Requirements:** FR-TD-1, FR-TEN-2
- **Milestone:** M2
- **Depends on:** EPIC-02 (Apiary CRUD)
- **Acceptance criteria:**
  - [ ] A todo has title, description, due date, and priority level (FR-TD-1)
  - [ ] A user can create, complete, reopen, edit, and delete a todo (Q-TODO lifecycle)
  - [ ] Completing and reopening a todo toggle its status and preserve the rest of the todo's data
  - [ ] Todos are organization-scoped and shared across the organization's members (FR-TEN-2)
  - [ ] Create, edit, complete/reopen, and delete each record the change in the todo's history (actor + timestamp) (FR-HIS-1)
  - [ ] All lifecycle operations work offline and are queued for sync when connectivity returns
- **Notes:** Lifecycle (complete/reopen/edit/delete) and optional assignment to a user are governed by Q-TODO — only create + list are specified in the original FR-TD-1. Offline behavior per EPIC-06; concurrent edits resolved by server-authoritative last-write-wins + conflict log (Q-SYNC).

### [Feature] Associations to apiary/area
- **Labels:** type/feature, area/todos, area/offline-sync, priority/medium
- **Requirements:** FR-TD-1
- **Milestone:** M2
- **Depends on:** EPIC-05 (Todo model), EPIC-02 (Apiary CRUD)
- **Acceptance criteria:**
  - [ ] A todo can be associated with a specific apiary (Q-TODO)
  - [ ] A todo can be associated with an area (the grouping needed for the AI example "todos pending for the area of apiary X") (Q-TODO)
  - [ ] A todo may also exist with no association (general todo)
  - [ ] Deleting an apiary leaves associated todos in a well-defined state (e.g., association cleared, not silently lost) and the change is recorded in history (FR-HIS-1)
  - [ ] Associations are settable offline and survive sync
- **Notes:** The exact definition of "area" and whether assignment-to-user is included are open under Q-TODO. This association is a prerequisite for the AI assistant example in FR-AI-1 ("todos pending for the area of apiary X") delivered later in EPIC-08. Offline behavior per EPIC-06.

### [Feature] Quick-create from main screen, apiaries list, apiary detail
- **Labels:** type/feature, area/todos, area/offline-sync, priority/high
- **Requirements:** FR-TD-1, FR-UX-1
- **Milestone:** M2
- **Depends on:** EPIC-05 (Todo model), EPIC-02 (Apiaries list, Apiary detail)
- **Acceptance criteria:**
  - [ ] A todo can be quick-created from the main screen (FR-TD-1)
  - [ ] A todo can be quick-created from the apiaries list (FR-TD-1)
  - [ ] A todo can be quick-created from the apiary detail page, pre-associating that apiary (FR-TD-1)
  - [ ] Quick-create uses large, gloves-friendly tap targets and a minimal field set suitable for field use (FR-UX-1)
  - [ ] A quick-created todo is recorded in history on creation (actor + timestamp) (FR-HIS-1)
  - [ ] Quick-create works offline and the new todo appears immediately in the local store
- **Notes:** Field-first UX (FR-UX-1) — minimize taps. Offline behavior per EPIC-06.

### [Feature] Todo list + filters (due date, priority)
- **Labels:** type/feature, area/todos, area/offline-sync, priority/medium
- **Requirements:** FR-TD-1
- **Milestone:** M2
- **Depends on:** EPIC-05 (Todo model)
- **Acceptance criteria:**
  - [ ] A list of all todos is available (FR-TD-1)
  - [ ] The list is filterable by due date (FR-TD-1)
  - [ ] The list is filterable by priority level (FR-TD-1)
  - [ ] The list distinguishes open, completed, and overdue todos (overdue supports the later FR-AI-1 "overdue todos" example)
  - [ ] The list renders offline from the on-device store, including todos created offline before sync
- **Notes:** "Overdue" and "due in the next week" views feed the AI examples in FR-AI-1 (delivered in EPIC-08). Offline behavior per EPIC-06.
