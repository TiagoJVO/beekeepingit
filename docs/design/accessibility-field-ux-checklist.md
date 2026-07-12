# Accessibility & field-first UX checklist

**Status: as-built baseline.** This is the one checklist other epics' feature stories reuse to
verify accessibility (`FR-AX-1`) and field-first UX (`FR-UX-1`) consistently, per `D-18` and
issues #79/#80. Intent lives in [`requirements/decisions.md`](../../requirements/decisions.md)
(`D-18`) and [`requirements/functional-requirements.md`](../../requirements/functional-requirements.md)
(`FR-AX-1`, `FR-UX-1`); this documents the concrete, checkable bar a screen must clear.

**Target standard: WCAG 2.2 AA.**

## Automated checklist (every feature screen)

Run these as part of the screen's own widget tests, not a one-off audit — a regression should
fail CI, not wait for a human pass.

- [ ] **Tap targets ≥ 44x44** for every interactive element (buttons, toggle segments, icon
      buttons, list-row actions). WCAG 2.2's own SC 2.5.8 minimum is 24x24 — this app targets
      44x44, and 56px tall for the one primary action per screen (save/sign-in/submit), for
      gloved field use. Use the shared `kMinTapTarget` constant
      (`client/lib/core/widgets/tap_target.dart`) and `PrimaryActionButton`/
      `SecondaryActionButton` (`client/lib/core/widgets/field_action_button.dart`) rather than
      hand-rolling a size. Verify with `tester.getSize(find.byKey(...))` — see
      `client/test/support/a11y_matchers.dart`'s `expectMinTapTarget` shared assertion, used by
      `client/test/core/widgets/field_action_button_test.dart` and the cross-screen sweep in
      `client/test/a11y_field_ux_test.dart` (which generalizes the original toggle-segment test
      in `client/test/apiaries_list_screen_test.dart`).
- [ ] **Semantics labels** on every interactive element and on content that isn't
      self-describing from its rendered text alone (icon-only buttons, status pills, map
      markers). Verify with `find.bySemanticsLabel(...)` or by inspecting the `SemanticsNode`
      tree (`tester.getSemantics(find.byKey(...))`).
- [ ] **Focus order & visible focus indicator.** Interactive elements must be reachable via
      `Tab`/`Shift+Tab` in a logical (visual, top-to-bottom/left-to-right) order, and the
      currently focused element must have a visible indicator (Flutter's default `Focus`/
      Material focus highlight is enough — don't suppress it). Verify with
      `tester.sendKeyEvent(LogicalKeyboardKey.tab)` and asserting `FocusManager.instance.primaryFocus`
      moves between the expected widgets in order.
- [ ] **Contrast ≥ 4.5:1** for body text against its background, for every color pair the theme
      defines (`client/lib/theming/app_theme.dart`, light and dark). Checked against the actual
      `ColorScheme` values in `client/test/theming/app_theme_contrast_test.dart` — a palette
      change that regresses contrast fails that test, not just a manual look.
- [ ] **Usable at increased text scale.** Widgets should not clip/overflow when
      `MediaQuery.textScaler` is scaled up (test at ~1.3x–2x) — wrap fixed-height text
      containers in a scroll view or let them grow, don't hard-clip.
- [ ] **Autofocus is purposeful**, not automatic on every screen — only the first empty field on
      a screen whose primary job is data entry (e.g. an empty create form) should autofocus;
      screens revisited with existing data should not steal focus/keyboard on open.

## Manual checklist (needs a human — see the pass protocol below)

- [ ] **Screen-reader pass**: with TalkBack (Android) or VoiceOver (iOS/macOS Safari) — or
      NVDA on desktop Chrome for the PWA — every control on the flow under test is announced
      with a meaningful label, its state changes are announced (loading, error, selected), and
      nothing is a silent dead end.
- [ ] **Keyboard-only pass**: unplug/ignore the mouse — complete the flow using only `Tab`,
      `Shift+Tab`, `Enter`/`Space`, and arrow keys where applicable. No control should be
      unreachable or require a pointer gesture with no keyboard equivalent.
- [ ] **Gloved-use pass**: with work gloves (or a reasonable stand-in — thick winter gloves),
      complete the flow on a touchscreen device. Mis-taps, missed targets, or the need to
      remove a glove to proceed are all findings.

See [Manual pass protocol](#manual-pass-protocol) below for how to run these and where results
are recorded.

## Field-first UX checklist (`FR-UX-1`, beyond pure accessibility)

- [ ] **One clear primary action per screen**, visually distinct (the app's honey/amber accent
      is reserved for it — see `docs/design/prototype.md`'s "Honey is the only primary action"
      rule) and full-width/56px tall via `PrimaryActionButton`.
- [ ] **Minimal steps** for field-critical flows (e.g. logging an activity) — don't add a
      confirmation screen/dialog for routine saves; reserve interruption for destructive or
      hard-to-undo actions (delete, logout).
- [ ] **Forgiving spacing** between adjacent tap targets — at least 8px between buttons/rows so
      a slightly-off tap doesn't land on the wrong control.
- [ ] **Consistent navigation** — the persistent app shell (bottom nav, header, contextual FAB;
      `FR-UX-2`) is the only navigation chrome; feature screens don't invent their own.

## Manual pass protocol

1. Pick the flow (e.g. "sign in", "create an apiary", "invite a member").
2. **Screen reader**: turn on the platform screen reader, put the device/browser in that mode,
   and complete the flow using only what's announced. Note anything unlabeled, mislabeled, or
   silently stuck.
3. **Keyboard-only**: on desktop Chrome (the PWA target), complete the same flow using only the
   keyboard. Note anything unreachable or with no visible focus indicator.
4. **Gloved use**: on a touchscreen device, with gloves on, complete the same flow. Note any
   mis-taps or targets that felt too small.
5. Record the result below (date, flow, tool/device, pass/fail + findings). A finding blocks
   the checklist item it maps to above until fixed.

### Pass log

| Date       | Flow                                     | Check           | Tool/device                          | Result                                                                                                                                             |
| ---------- | ----------------------------------------- | --------------- | ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| 2026-07-12 | Login, apiaries list/form, account/org/members | Automated tap-target + semantics + contrast + focus-order (see above) | `flutter test` (widget tests, no device) | **Pass** — see `client/test/core/widgets/`, `client/test/theming/app_theme_contrast_test.dart`, and the semantics/focus additions to each screen's own test file. |
| —          | Login, apiaries list/form, account/org/members | Screen reader (TalkBack/VoiceOver/NVDA) | _not yet run_ | **Needs a human pass.** No screen reader or physical/emulated device was available in this session — automated `Semantics` assertions confirm labels exist and are correct, not that a real screen reader announces them usably end-to-end. |
| —          | Login, apiaries list/form, account/org/members | Keyboard-only, real browser | _not yet run_ | **Needs a human pass.** Widget-test focus-order assertions (`FocusManager.instance.primaryFocus` after simulated Tab key events) confirm the order Flutter computes, not that a real browser's native Tab handling + visible focus ring matches — run in an actual Chrome window. |
| —          | Any field flow | Gloved use, physical touchscreen | _not yet run_ | **Needs a human pass.** Requires a physical device and gloves; cannot be verified from a CI/headless environment. |

**Honesty note:** rows marked "not yet run" are exactly that — no manual verification has been
claimed for them. Do not mark a row "Pass" without actually performing it on a real
device/screen reader/browser.
