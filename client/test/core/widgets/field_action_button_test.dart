import 'package:beekeepingit_client/core/widgets/field_action_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/a11y_matchers.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(8), child: child),
  ),
);

void main() {
  group('PrimaryActionButton (#79, #80)', () {
    testWidgets(
      'meets the 44x44 minimum tap target and is 56 tall by default',
      (tester) async {
        await tester.pumpWidget(
          _host(
            PrimaryActionButton(
              key: const Key('primary'),
              label: 'Save',
              onPressed: () {},
            ),
          ),
        );

        expectMinTapTarget(tester, find.byKey(const Key('primary')));
        final size = tester.getSize(find.byKey(const Key('primary')));
        expect(size.height, kFieldActionButtonHeight);
      },
    );

    testWidgets(
      'fullWidth: false still meets the height floor but shrink-wraps '
      'width',
      (tester) async {
        await tester.pumpWidget(
          _host(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PrimaryActionButton(
                  key: const Key('primary'),
                  label: 'Invite',
                  fullWidth: false,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        );

        final size = tester.getSize(find.byKey(const Key('primary')));
        expect(size.height, greaterThanOrEqualTo(kFieldActionButtonHeight));
        expect(size.width, lessThan(400));
      },
    );

    testWidgets('exposes a semantics label matching the visible text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          PrimaryActionButton(
            key: const Key('primary'),
            label: 'Save',
            onPressed: () {},
          ),
        ),
      );

      expectHasSemanticsLabel(tester, const Key('primary'));
      final semantics = tester.getSemantics(find.byKey(const Key('primary')));
      expect(semantics.label, 'Save');
    });

    testWidgets('busy disables the button without shrinking it', (
      tester,
    ) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          PrimaryActionButton(
            key: const Key('primary'),
            label: 'Save',
            busy: true,
            onPressed: () => tapped = true,
          ),
        ),
      );

      final size = tester.getSize(find.byKey(const Key('primary')));
      expect(size.height, kFieldActionButtonHeight);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.tap(find.byKey(const Key('primary')), warnIfMissed: false);
      await tester.pump();
      expect(tapped, isFalse);
    });

    testWidgets('tapping invokes onPressed', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          PrimaryActionButton(
            key: const Key('primary'),
            label: 'Save',
            onPressed: () => tapped = true,
          ),
        ),
      );

      await tester.tap(find.byKey(const Key('primary')));
      await tester.pump();
      expect(tapped, isTrue);
    });
  });

  group('SecondaryActionButton (#79, #80)', () {
    testWidgets('meets the 44x44 minimum tap target and is 56 tall', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SecondaryActionButton(
            key: const Key('secondary'),
            label: 'Delete',
            onPressed: () {},
          ),
        ),
      );

      expectMinTapTarget(tester, find.byKey(const Key('secondary')));
      final size = tester.getSize(find.byKey(const Key('secondary')));
      expect(size.height, kFieldActionButtonHeight);
    });

    testWidgets('destructive uses the theme error color', (tester) async {
      await tester.pumpWidget(
        _host(
          SecondaryActionButton(
            key: const Key('secondary'),
            label: 'Delete',
            destructive: true,
            onPressed: () {},
          ),
        ),
      );

      final outlined = tester.widget<OutlinedButton>(
        find.byType(OutlinedButton),
      );
      final theme = Theme.of(tester.element(find.byType(OutlinedButton)));
      final foreground = outlined.style?.foregroundColor?.resolve({});
      expect(foreground, theme.colorScheme.error);
    });

    testWidgets('exposes a semantics label matching the visible text', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          SecondaryActionButton(
            key: const Key('secondary'),
            label: 'Delete',
            onPressed: () {},
          ),
        ),
      );

      expectHasSemanticsLabel(tester, const Key('secondary'));
    });
  });
}
