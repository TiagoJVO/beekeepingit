import 'package:flutter/material.dart';

/// Renders a form field's inline validation error as a screen-reader LIVE
/// REGION, so the message is SPOKEN when it appears instead of only being
/// painted in red under the field (#750, FR-AX-1, FR-UX-1, D-18 — WCAG 2.2
/// AA). Wire it into every field that can show an error:
///
/// ```dart
/// TextFormField(
///   errorBuilder: announcedFieldError,
///   validator: (v) => ...,
/// )
/// ```
///
/// The signature matches [FormFieldErrorBuilder] exactly, which is why call
/// sites read `errorBuilder: announcedFieldError` with no closure. Both
/// [TextFormField] and [DropdownButtonFormField] support it.
///
/// **Server-supplied (422) messages go through [FormField.forceErrorText],
/// not the decoration.** A field that shows a server verdict pairs the two:
///
/// ```dart
/// TextFormField(
///   forceErrorText: _fieldErrors['name'],   // null = no server error
///   errorBuilder: announcedFieldError,
///   validator: (v) => ...,
/// )
/// ```
///
/// `forceErrorText` sets `FormFieldState._errorText`, so the message flows
/// through this same `errorBuilder` (it keeps the live region) AND
/// `FormFieldState.hasError` becomes true. That second half is the reason
/// it is not `InputDecoration.error:` or `errorText:`: the field's
/// `Semantics(validationResult:)` is derived from `hasError`, and neither
/// decoration property touches it. A server error pushed in through the
/// decoration therefore leaves the field marked
/// `SemanticsValidationResult.valid` — on web, `aria-invalid="false"` under
/// a visibly red error, which is worse for an assistive technology than the
/// plain `errorText` this replaced.
///
/// Two consequences of `forceErrorText`, both deliberate:
///
///  1. it OVERRIDES the validator — `validator` is not called at all while
///     it is non-null (`FormFieldState._validate`). The server has seen the
///     value and rejected it; its verdict is the more specific one.
///  2. `Form.validate()` returns FALSE while it stands, so pressing Save
///     again WITHOUT editing the field is blocked client-side instead of
///     re-issuing a request the server has already refused for that exact
///     value. Every screen that sets `forceErrorText` therefore MUST also
///     drop the verdict when the user edits the field (#649's
///     `onChanged: _clearFieldError`), or the button is dead for the rest
///     of the session.
///
/// **Why the SDK does not already do this.** `InputDecorator` DOES wrap the
/// error in `Semantics(container: true, liveRegion:
/// !MediaQuery.supportsAnnounceOf(context))` — but `supportsAnnounce` is
/// true on web and iOS, so on this app's own target (a Flutter Web PWA,
/// D-10) that live region is switched OFF. In its place the SDK relies on
/// `FormState.validate()` calling `SemanticsService.sendAnnouncement`, and
/// that path covers only the FIRST error, and only when `Form.validate()` is
/// explicitly called. It therefore misses exactly the cases #750 reported:
///
///  - a server-side 422 error (profile, organization, account, members) —
///    it never passes through `Form.validate()` at all;
///  - the 2nd..nth error of a single blocked save;
///  - an error raised by per-field `AutovalidateMode.onUserInteraction`
///    (#649), which is not a `validate()` call either.
///
/// **Why this is not `LabeledField`'s job.** The label wrapper cannot know
/// the error string — that lives in the `FormFieldState` created BELOW it —
/// and the field's accessible NAME is already correct (#629). The live
/// region has to sit on the MESSAGE node, not on the field node: a live
/// region on the field would make an assistive technology re-read the whole
/// field (name, value, error) on every keystroke.
///
/// **Accepted trade-off 1: the field node loses the `hint` copy.** Supplying
/// a custom error widget leaves `decoration.errorText` null, so the field's
/// own semantics node no longer mirrors the message into its `hint`. That is
/// a duplicate of what the live region now speaks;
/// `validationResult: invalid` still marks the field as failing, and the
/// message node still sits inside the field's subtree.
/// `input_decorator.dart` acknowledges the same gap in its own TODO about
/// custom error widgets.
///
/// **Accepted trade-off 2: a blocked save speaks its FIRST error twice.**
/// `FormState._validate` sends an ASSERTIVE
/// `SemanticsService.sendAnnouncement` of the first invalid field's message
/// whenever `MediaQuery.supportsAnnounce` is true (web/iOS — our target),
/// and this live region then announces it politely. Net effect of a blocked
/// save: error #1 is spoken twice, errors #2..n once each — versus, before
/// #750, error #1 once and every other error silent. The only lever that
/// would suppress the SDK's half is overriding `MediaQueryData
/// .supportsAnnounce` to false, which would misrepresent a platform
/// capability app-wide and break any legitimate future
/// `SemanticsService.sendAnnouncement`; a duplicate is strictly better than
/// a silence, so this is accepted rather than suppressed. It is pinned by a
/// test in `client/test/core/widgets/field_error_test.dart` that captures
/// `SystemChannels.accessibility`, so an SDK change cannot quietly make it
/// worse.
///
/// **Constraint on call sites: no `errorMaxLines`, no custom `textAlign`.**
/// `InputDecorator` forwards `textAlign` and `errorMaxLines` only to the
/// DEFAULT `Text` it builds from `errorText`; a custom error widget receives
/// neither. A field wired to `announcedFieldError` must therefore not set
/// `errorMaxLines:` or a non-default `textAlign:`, or the setting will be
/// silently ignored on its error line. No field in `client/lib` does today —
/// there is no `errorMaxLines` anywhere, and the one field with a custom
/// `textAlign` (`apiary-counter-edit-field`, a bare `TextField`) shows no
/// error at all.
///
/// No style or colour is set here on purpose: `_HelperError` wraps whatever
/// this returns in `DefaultTextStyle(style: errorStyle)`, so the existing
/// red error styling — and the fade/slide transition and the red field
/// border — are unchanged.
Widget announcedFieldError(BuildContext context, String errorText) {
  return Semantics(
    liveRegion: true,
    child: Text(errorText, overflow: TextOverflow.ellipsis),
  );
}
