/// Shared field-first/accessibility sizing constants (FR-UX-1, FR-AX-1, #79,
/// #80). WCAG 2.2 AA's own target-size success criterion (2.5.8) requires
/// only 24x24 CSS px; this app deliberately targets a larger 44x44 minimum
/// for gloved/field use, matching the platform convention (iOS HIG, Material
/// touch target guidance) this app already builds icon buttons/toggles to
/// (see `apiaries_list_screen.dart`'s view toggle, `app_shell.dart`'s sync
/// pill). [PrimaryActionButton]/[SecondaryActionButton]
/// (`field_action_button.dart`) go further still, at 56px tall, for the
/// single most important action on a screen.
///
/// See the checklist this implements:
/// `docs/design/accessibility-field-ux-checklist.md`.
const double kMinTapTarget = 44;
