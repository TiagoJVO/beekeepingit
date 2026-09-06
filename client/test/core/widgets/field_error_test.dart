// Unit coverage for the shared announced-field-error building block (#750,
// FR-AX-1, FR-UX-1, D-18) that every error-capable form field in the app now
// wires into `errorBuilder`, paired with `forceErrorText:` wherever a server
// 422 message has to be shown. Each screen's own test file still asserts its
// concrete behaviour (which message, when it clears); this file pins the
// CONTRACT in isolation, on the exact `LabeledField` + `TextFormField` +
// `Form` shape the call sites use:
//
//  1. the message node is a LIVE REGION — the whole point: an assistive
//     technology speaks it when it appears;
//  2. the message node announces ONLY the message, and the field node ONLY
//     its label — so the fix cannot re-announce the field's name a second
//     time (#629);
//  3. the field node is NOT a live region — a live region there would
//     re-read the whole field on every keystroke;
//  4. the field is marked `SemanticsValidationResult.invalid`, for a
//     validator error AND for a server one;
//  5. a SERVER-supplied message with no `Form.validate()` call at all is
//     announced too — the case the SDK never covered, and the core of #750;
//  6. the two deliberate consequences of `forceErrorText`: it overrides the
//     validator, and it keeps `Form.validate()` false while it stands;
//  7. the accepted double-announcement of a blocked save's FIRST error,
//     measured on the real platform channel so an SDK change cannot make it
//     quietly worse.
//
// Assertions read the REAL `SemanticsNode` and compare labels with `==`,
// never `contains`: #662 established that discipline after a `contains`
// matcher hid a duplicate-announcement defect.

import 'package:beekeepingit_client/core/widgets/field_error.dart';
import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/a11y_matchers.dart';

const _label = 'Name';
const _message = 'Enter your name.';
const _fieldKey = Key('field-under-test');

/// A validator-driven field, in the app's own `LabeledField` wrapper, with a
/// [GlobalKey] on the [Form] so a test can trigger validation the way a
/// blocked save does.
Widget _validatorHarness(GlobalKey<FormState> formKey) => MaterialApp(
  home: Scaffold(
    body: Form(
      key: formKey,
      child: LabeledField(
        label: _label,
        child: TextFormField(
          key: _fieldKey,
          errorBuilder: announcedFieldError,
          validator: (v) => (v == null || v.trim().isEmpty) ? _message : null,
        ),
      ),
    ),
  ),
);

/// A field carrying a SERVER message only, the way the four server-error
/// screens do: `forceErrorText:` plus `errorBuilder:`, no `Form.validate()`
/// call anywhere. [validator] is optional so a test can prove the override.
///
/// [supportsAnnounce] is `null` for "leave the platform value alone"; setting
/// it wraps the harness in a [MediaQuery] override so the CONTROL case can
/// pin what happens when the SDK's own `InputDecorator` live region switches
/// itself back on.
Widget _serverErrorHarness(
  String? message, {
  FormFieldValidator<String>? validator,
  bool? supportsAnnounce,
}) {
  Widget field = LabeledField(
    label: _label,
    child: TextFormField(
      key: _fieldKey,
      forceErrorText: message,
      errorBuilder: announcedFieldError,
      validator: validator,
    ),
  );
  if (supportsAnnounce != null) {
    final wrapped = field;
    field = Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(supportsAnnounce: supportsAnnounce),
        child: wrapped,
      ),
    );
  }
  return MaterialApp(home: Scaffold(body: field));
}

/// The messages that reached the platform's own accessibility channel — the
/// `SemanticsService.sendAnnouncement` half of the behaviour, which is
/// separate from, and additional to, the live region.
List<String> _captureAnnouncements(WidgetTester tester) {
  final announced = <String>[];
  tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
    SystemChannels.accessibility,
    (dynamic message) async {
      final event = message! as Map<dynamic, dynamic>;
      if (event['type'] != 'announce') return null;
      final data = event['data']! as Map<dynamic, dynamic>;
      announced.add(data['message']! as String);
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger
        .setMockDecodedMessageHandler<dynamic>(
          SystemChannels.accessibility,
          null,
        ),
  );
  return announced;
}

void main() {
  // Every `isLiveRegion: true` assertion below is only MEANINGFUL because
  // the platform reports `supportsAnnounce == true`, which is what switches
  // the SDK's own `InputDecorator` live region OFF
  // (`liveRegion: !MediaQuery.supportsAnnounceOf(context)`). If a future
  // toolchain flipped that default, `InputDecorator` would supply the flag
  // itself and every assertion here would pass with the fix reverted — the
  // suite would go vacuous instead of failing. So pin the premise first.
  testWidgets('the test platform reports supportsAnnounce == true, which is '
      'what makes the rest of this file meaningful', (tester) async {
    expect(
      tester.platformDispatcher.accessibilityFeatures.supportsAnnounce,
      isTrue,
      reason:
          'with supportsAnnounce false the SDK\'s InputDecorator supplies '
          'liveRegion: true itself, so every live-region assertion in this '
          'file would pass even with announcedFieldError reverted to a bare '
          'Text — they would be vacuous, not failing. This also mirrors the '
          'app\'s real target (web/iOS, D-10).',
    );
  });

  group('announcedFieldError — validator errors (#750, FR-AX-1, D-18)', () {
    testWidgets('the message node is a live region labelled with the message '
        'and nothing else', (tester) async {
      final handle = tester.ensureSemantics();
      final formKey = GlobalKey<FormState>();
      await tester.pumpWidget(_validatorHarness(formKey));

      expect(formKey.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();

      expect(find.text(_message), findsOneWidget);
      expectLiveRegion(tester, find.text(_message));
      expect(tester.getSemantics(find.text(_message)).label, _message);
      handle.dispose();
    });

    testWidgets('the field node keeps its label, is not a live region, and '
        'is still marked invalid', (tester) async {
      final handle = tester.ensureSemantics();
      final formKey = GlobalKey<FormState>();
      await tester.pumpWidget(_validatorHarness(formKey));

      expect(formKey.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();

      final field = find.byKey(_fieldKey);
      // `==`, not `contains`: LabeledField hands the field its accessible
      // name (#629), and the error must not be folded in on top of it.
      expect(tester.getSemantics(field).label, _label);
      expectLiveRegion(tester, field, isLiveRegion: false);
      // The property that SURVIVES supplying a custom error widget. The
      // field's `hint` does not — `decoration.errorText` is null once
      // `errorBuilder` owns the message — which is the accepted trade-off
      // documented in field_error.dart.
      expect(
        tester.getSemantics(field).getSemanticsData().validationResult,
        SemanticsValidationResult.invalid,
      );
      handle.dispose();
    });

    testWidgets('changing the message replaces the one node\'s label, and it '
        'stays a live region', (tester) async {
      final handle = tester.ensureSemantics();
      const messageB = 'Name must be at most 200 characters.';
      var message = _message;
      final formKey = GlobalKey<FormState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: formKey,
              child: StatefulBuilder(
                builder: (context, setState) => Column(
                  children: [
                    LabeledField(
                      label: _label,
                      child: TextFormField(
                        key: _fieldKey,
                        errorBuilder: announcedFieldError,
                        validator: (_) => message,
                      ),
                    ),
                    TextButton(
                      key: const Key('swap-message'),
                      onPressed: () => setState(() => message = messageB),
                      child: const Text('swap'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      expect(formKey.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();
      expectLiveRegion(tester, find.text(_message));

      await tester.tap(find.byKey(const Key('swap-message')));
      await tester.pumpAndSettle();
      expect(formKey.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();

      // One node, now carrying B — a live region announces on CHANGE, so a
      // second node left behind carrying A would both be stale and be read.
      expect(find.text(_message), findsNothing);
      expect(find.text(messageB), findsOneWidget);
      expect(tester.getSemantics(find.text(messageB)).label, messageB);
      expectLiveRegion(tester, find.text(messageB));
      handle.dispose();
    });
  });

  group('forceErrorText — server errors (#750, FR-AX-1)', () {
    // The case the SDK never covered: a 422 message never passes through
    // `Form.validate()`, so the SDK's announcement path
    // (`FormState._validate`) is never even reached.
    testWidgets('a server message with no Form.validate() call at all is '
        'still a live region announcing only the message', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_serverErrorHarness('Server says no'));
      await tester.pumpAndSettle();

      expect(find.text('Server says no'), findsOneWidget);
      expectLiveRegion(tester, find.text('Server says no'));
      expect(
        tester.getSemantics(find.text('Server says no')).label,
        'Server says no',
      );
      expect(tester.getSemantics(find.byKey(_fieldKey)).label, _label);
      handle.dispose();
    });

    // The reason this is `forceErrorText:` and not `InputDecoration.error:`.
    // `Semantics(validationResult:)` is driven by `FormFieldState.hasError`,
    // i.e. by `_errorText`, which only `forceErrorText` sets. Through the
    // decoration the field would read as VALID — on web,
    // `aria-invalid="false"` under a visibly red error.
    testWidgets('a server message marks the field invalid, not just red', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_serverErrorHarness('Server says no'));
      await tester.pumpAndSettle();

      expect(
        tester
            .getSemantics(find.byKey(_fieldKey))
            .getSemanticsData()
            .validationResult,
        SemanticsValidationResult.invalid,
      );
      handle.dispose();
    });

    testWidgets('a null message means no error at all', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_serverErrorHarness(null));
      await tester.pumpAndSettle();

      final decorator = tester.widget<InputDecorator>(
        find.byType(InputDecorator),
      );
      expect(decorator.decoration.error, isNull);
      expect(decorator.decoration.errorText, isNull);
      expect(
        tester
            .getSemantics(find.byKey(_fieldKey))
            .getSemanticsData()
            .validationResult,
        SemanticsValidationResult.valid,
      );
      handle.dispose();
    });

    // DELIBERATE behaviour change (a), pinned. `FormFieldState._validate`
    // returns early when `forceErrorText != null`, so the validator is never
    // called. Before #750 the server message rode in the decoration and the
    // validator's message won; now the server's more specific verdict does.
    testWidgets('a server message overrides the validator, which is not even '
        'called', (tester) async {
      final handle = tester.ensureSemantics();
      var validatorCalls = 0;
      await tester.pumpWidget(
        _serverErrorHarness(
          'Server says no',
          validator: (_) {
            validatorCalls++;
            return 'Validator says no';
          },
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Server says no'), findsOneWidget);
      expect(find.text('Validator says no'), findsNothing);
      expect(
        validatorCalls,
        0,
        reason:
            'FormFieldState._validate returns early while forceErrorText is '
            'non-null — the validator must not run at all',
      );
      handle.dispose();
    });

    // DELIBERATE behaviour change (b), pinned. The field is genuinely
    // invalid while the server's verdict stands, so a save that gates on
    // `Form.validate()` is blocked client-side rather than re-issuing a
    // request the server already refused for that exact value. Screens that
    // use this MUST clear the verdict on edit (#649) — see the
    // screen-level tests in organization/account/members.
    testWidgets('Form.validate() stays false while a server message stands, '
        'even with a validator that passes', (tester) async {
      final formKey = GlobalKey<FormState>();
      Widget build(String? serverMessage) => MaterialApp(
        home: Scaffold(
          body: Form(
            key: formKey,
            child: LabeledField(
              label: _label,
              child: TextFormField(
                key: _fieldKey,
                forceErrorText: serverMessage,
                errorBuilder: announcedFieldError,
                validator: (_) => null,
              ),
            ),
          ),
        ),
      );

      await tester.pumpWidget(build('Server says no'));
      await tester.pumpAndSettle();
      expect(formKey.currentState!.validate(), isFalse);

      // ...and clearing it (what #649's onChanged does) releases the block.
      await tester.pumpWidget(build(null));
      await tester.pumpAndSettle();
      expect(formKey.currentState!.validate(), isTrue);
    });
  });

  group('the SDK\'s own announcement, measured (#750)', () {
    // ACCEPTED trade-off 2, pinned rather than suppressed. `FormState
    // ._validate` sends an ASSERTIVE announcement of the FIRST invalid
    // field's message whenever `supportsAnnounce` is true, and our live
    // region then announces the same message politely. So a blocked save
    // speaks error #1 twice and errors #2..n once — versus, before #750,
    // error #1 once and everything else silent. Suppressing the SDK's half
    // would mean lying about `MediaQueryData.supportsAnnounce` app-wide,
    // which would also break any legitimate future
    // `SemanticsService.sendAnnouncement`. This test measures the real
    // platform channel so an SDK change cannot make the total worse
    // unnoticed.
    testWidgets('a blocked save sends exactly ONE platform announcement — the '
        'first field\'s message — while every message is a live region', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final announced = _captureAnnouncements(tester);
      final formKey = GlobalKey<FormState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: formKey,
              child: Column(
                children: [
                  LabeledField(
                    label: 'First',
                    child: TextFormField(
                      key: const Key('first-field'),
                      errorBuilder: announcedFieldError,
                      validator: (_) => 'First is wrong.',
                    ),
                  ),
                  LabeledField(
                    label: 'Second',
                    child: TextFormField(
                      key: const Key('second-field'),
                      errorBuilder: announcedFieldError,
                      validator: (_) => 'Second is wrong.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(formKey.currentState!.validate(), isFalse);
      await tester.pumpAndSettle();

      // The SDK's half: assertive, first error only.
      expect(
        announced,
        ['First is wrong.'],
        reason:
            'FormState._validate announces only the first invalid field. If '
            'this ever grows to both messages, the total for field #1 '
            'becomes three announcements and the trade-off documented in '
            'field_error.dart needs revisiting.',
      );
      // Our half: BOTH messages are live regions, which is what makes error
      // #2 audible at all.
      expectLiveRegion(tester, find.text('First is wrong.'));
      expectLiveRegion(tester, find.text('Second is wrong.'));
      handle.dispose();
    });

    // CONTROL case for the whole file. On a platform that does NOT support
    // announcements the SDK switches its own `Semantics(container: true,
    // liveRegion: true)` back on around the error — so this pins that our
    // `Semantics(liveRegion: true)` MERGES into that container rather than
    // creating a nested duplicate node. One node, labelled exactly the
    // message, either way.
    testWidgets('with supportsAnnounce false the message is still exactly ONE '
        'live-region node labelled exactly the message', (tester) async {
      final handle = tester.ensureSemantics();
      final announced = _captureAnnouncements(tester);
      await tester.pumpWidget(
        _serverErrorHarness('Server says no', supportsAnnounce: false),
      );
      await tester.pumpAndSettle();

      final matches = find
          .bySemanticsLabel('Server says no')
          .evaluate()
          .map((e) => tester.getSemantics(find.byWidget(e.widget)))
          .where((node) => node.getSemanticsData().flagsCollection.isLiveRegion)
          .toList();
      expect(
        matches,
        hasLength(1),
        reason:
            'exactly one live-region node must carry the message — a nested '
            'duplicate would be read twice by an assistive technology',
      );
      expect(matches.single.label, 'Server says no');
      expect(
        announced,
        isEmpty,
        reason:
            'no Form.validate() call happened, so nothing reaches the '
            'platform announcement channel either way',
      );
      handle.dispose();
    });
  });
}
