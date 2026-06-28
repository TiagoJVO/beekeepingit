# EPIC-11 — i18n & Accessibility

- **Milestone:** M0
- **Phase:** cross-cutting
- **Labels:** type/epic, area/i18n-a11y
- **Requirements:** NFR-I18N-1, FR-AX-1, FR-UX-1, NFR-TST-1
- **Depends on:** EPIC-00
- **Spikes:** none
- **Summary:** Cross-cutting internationalization and accessibility foundation for the client: English + Portuguese with locale-aware date/number formatting, a translation extraction workflow, WCAG 2.2 AA accessibility (screen reader, keyboard navigation), and a field-first UX with large, gloves-friendly tap targets. Established at M0 and applied across all subsequent features.

## Stories

### [Task] i18n framework EN + PT; locale date/number formats
- **Labels:** type/task, area/i18n-a11y, priority/high
- **Requirements:** NFR-I18N-1
- **Milestone:** M0
- **Depends on:** EPIC-00 (Flutter app skeleton, i18n scaffold)
- **Acceptance criteria:**
  - [ ] The app supports English and Portuguese, with a user-selectable/locale-detected language and full UI translation for both (NFR-I18N-1)
  - [ ] Dates, times, and numbers render using locale-specific formats (e.g. Portuguese decimal/date conventions) via Flutter `intl` (NFR-I18N-1)
  - [ ] Units and formats follow the agreed metric defaults (kg/L) and PT locale defaults, consistent across the app (Units & formats open item)
  - [ ] The framework is structured so additional languages can be added later without code changes to feature screens (NFR-I18N-1)
  - [ ] A missing translation falls back predictably (e.g. to English) rather than showing a key or blank
  - [ ] Locale formatting and fallback behavior are covered by automated tests for both EN and PT (NFR-TST-1)
- **Notes:** EN + PT focus now, designed to extend later, per NFR-I18N-1 and tech-stack.md (Flutter `intl`). Metric units (kg/L) and PT date/number defaults per the "Units & formats" open item. Builds on the i18n scaffold from EPIC-00.

### [Task] Translation extraction/workflow
- **Labels:** type/task, area/i18n-a11y, priority/medium
- **Requirements:** NFR-I18N-1, NFR-MNT-1
- **Milestone:** M0
- **Depends on:** EPIC-11 (i18n framework)
- **Acceptance criteria:**
  - [ ] A documented workflow extracts translatable strings from the codebase into resource files (e.g. ARB) for translation (NFR-I18N-1)
  - [ ] Hard-coded user-facing strings are detectable/flagged so new strings are externalized by default (NFR-MNT-1)
  - [ ] Adding or updating a translation is a documented, repeatable step that does not require touching feature logic
  - [ ] The extraction/build step is wired into CI so missing or malformed translation resources fail the build
  - [ ] The workflow is documented for contributors (how to add a string, how to translate it) (NFR-MNT-1)
- **Notes:** Supports the EN+PT framework (NFR-I18N-1) and keeps strings externalized from the start (consistent with the EPIC-00 scaffold). Maintainability aligns with NFR-MNT-1.

### [Feature] Accessibility: WCAG 2.2 AA, screen reader, keyboard nav
- **Labels:** type/feature, area/i18n-a11y, priority/high
- **Requirements:** FR-AX-1, NFR-TST-1
- **Milestone:** M0
- **Depends on:** EPIC-00 (Flutter app skeleton)
- **Acceptance criteria:**
  - [ ] The app targets WCAG 2.2 AA as the accessibility standard, documented as the project baseline (FR-AX-1, Q-AX)
  - [ ] Interactive elements are reachable and operable by keyboard with a visible focus indicator and a logical focus order (FR-AX-1)
  - [ ] Screens expose proper semantics/labels so a screen reader announces controls, state, and content meaningfully (FR-AX-1)
  - [ ] Color contrast and text sizing meet WCAG 2.2 AA, and the UI remains usable at increased text scale (FR-AX-1)
  - [ ] Accessibility acceptance checks (automated a11y/semantics tests plus a documented manual screen-reader + keyboard pass) are part of the definition of done for feature screens (NFR-TST-1)
  - [ ] An accessibility checklist is available for reuse by other epics' feature stories so a11y is verified consistently
- **Notes:** Target standard WCAG 2.2 AA resolves Q-AX (recommended default). This is cross-cutting: other epics' UI stories consume the checklist/baseline established here (FR-AX-1).

### [Feature] Field-first UX: large tap targets, gloves-friendly
- **Labels:** type/feature, area/i18n-a11y, priority/high
- **Requirements:** FR-UX-1, FR-AX-1, NFR-TST-1
- **Milestone:** M0
- **Depends on:** EPIC-00 (Flutter app skeleton, theming)
- **Acceptance criteria:**
  - [ ] Primary field actions use large tap targets sized for gloved use, meeting at least the WCAG 2.2 AA target-size guidance (FR-UX-1, FR-AX-1)
  - [ ] Field-critical flows are designed for limited time/attention: minimal steps, clear primary actions, and forgiving spacing to reduce mis-taps (FR-UX-1)
  - [ ] Navigation is clear and consistent, with intuitive controls that work without precise pointing (FR-UX-1)
  - [ ] The field-first UX patterns are captured as reusable components/guidelines so feature epics apply them consistently
  - [ ] Tap-target sizing and key field interactions are verified by automated checks and a documented manual gloved-use pass (NFR-TST-1)
- **Notes:** Field-first, gloves-friendly UX per FR-UX-1, reinforced by WCAG 2.2 AA target-size guidance (FR-AX-1). Cross-cutting: apiary/activity/journey/todo field flows in M1–M2 build on these patterns.
