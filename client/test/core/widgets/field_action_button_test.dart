import 'dart:async';

import 'package:beekeepingit_client/core/widgets/field_action_button.dart';
import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:beekeepingit_client/theming/brand_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

    testWidgets(
      'tapping twice while an async onPressed is in flight only invokes it '
      'once, self-disabling without the caller passing busy (#380)',
      (tester) async {
        var invocations = 0;
        final completer = Completer<void>();
        await tester.pumpWidget(
          _host(
            PrimaryActionButton(
              key: const Key('primary'),
              label: 'Save',
              onPressed: () async {
                invocations++;
                await completer.future;
              },
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('primary')));
        await tester.pump();
        // Self-disabled while in flight — but NOT the busy spinner, since the
        // caller never passed busy: a handler that opens a confirm dialog
        // and awaits the user's choice is legitimately "in flight" for as
        // long as the user takes to decide, and a spinner during that wait
        // would misleadingly suggest network activity (and would never let
        // pumpAndSettle converge in a widget test).
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final button = tester.widget<FilledButton>(find.byType(FilledButton));
        expect(button.onPressed, isNull);
        await tester.tap(find.byKey(const Key('primary')), warnIfMissed: false);
        await tester.pump();
        expect(invocations, 1);

        completer.complete();
        await tester.pumpAndSettle();
        expect(invocations, 1);
        // Re-enabled once the handler completes.
        final reEnabled = tester.widget<FilledButton>(
          find.byType(FilledButton),
        );
        expect(reEnabled.onPressed, isNotNull);
        await tester.tap(find.byKey(const Key('primary')), warnIfMissed: false);
        await tester.pump();
        expect(invocations, 2);
      },
    );
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

    testWidgets(
      'tapping twice while an async onPressed is in flight only invokes it '
      'once, self-disabling without the caller passing busy (#380)',
      (tester) async {
        var invocations = 0;
        final completer = Completer<void>();
        await tester.pumpWidget(
          _host(
            SecondaryActionButton(
              key: const Key('secondary'),
              label: 'Delete',
              onPressed: () async {
                invocations++;
                await completer.future;
              },
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('secondary')));
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final button = tester.widget<OutlinedButton>(
          find.byType(OutlinedButton),
        );
        expect(button.onPressed, isNull);
        await tester.tap(
          find.byKey(const Key('secondary')),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(invocations, 1);

        completer.complete();
        await tester.pumpAndSettle();
        expect(invocations, 1);
        final reEnabled = tester.widget<OutlinedButton>(
          find.byType(OutlinedButton),
        );
        expect(reEnabled.onPressed, isNotNull);
      },
    );
  });

  // "Honey is the only primary action. Secondary = outlined plum."
  // (docs/design/prototype.md, docs/design/melargil-flutter-style.md). #627:
  // in light mode the secondary button had been drawing its label in honey on
  // cream (1.84:1). These assert the colors the buttons actually *render*,
  // under the real AppTheme, in both brightnesses.
  group('primary/secondary color roles (#627, FR-AX-1, FR-UX-1, D-18)', () {
    Widget themed(ThemeData theme, Widget child) => MaterialApp(
      theme: theme,
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(8), child: child),
      ),
    );

    Color? labelColor(WidgetTester tester, String text) =>
        tester.renderObject<RenderParagraph>(find.text(text)).text.style?.color;

    Color? iconColor(WidgetTester tester, IconData icon) =>
        IconTheme.of(tester.element(find.byIcon(icon))).color;

    ShapeBorder? buttonShape(WidgetTester tester, Type buttonType) => tester
        .widget<Material>(
          find.descendant(
            of: find.byType(buttonType),
            matching: find.byType(Material),
          ),
        )
        .shape;

    for (final (name, theme) in <(String, ThemeData)>[
      ('light', AppTheme.light()),
      ('dark', AppTheme.dark()),
    ]) {
      testWidgets('$name: the primary action keeps the honey fill', (
        tester,
      ) async {
        await tester.pumpWidget(
          themed(theme, PrimaryActionButton(label: 'Save', onPressed: () {})),
        );

        final material = tester.widget<Material>(
          find.descendant(
            of: find.byType(FilledButton),
            matching: find.byType(Material),
          ),
        );
        expect(material.color, BrandTokens.honey);
        expect(labelColor(tester, 'Save'), BrandTokens.onHoney);
      });

      testWidgets('$name: the secondary action is outlined, never honey', (
        tester,
      ) async {
        await tester.pumpWidget(
          themed(
            theme,
            SecondaryActionButton(label: 'Cancel', onPressed: () {}),
          ),
        );

        final label = labelColor(tester, 'Cancel');
        final shape = buttonShape(tester, OutlinedButton) as OutlinedBorder;
        expect(label, isNot(BrandTokens.honey));
        expect(shape.side.color, isNot(BrandTokens.honey));
        expect(shape.side.width, greaterThan(0));
        if (theme.brightness == Brightness.light) {
          // Outlined plum on cream: label and border are both plum 700.
          expect(label, BrandTokens.plum700);
          expect(shape.side.color, BrandTokens.plum700);
        } else {
          // Plum *is* the dark ground, so the label takes the body cream and
          // the border the scheme's plum-500 outline.
          expect(label, BrandTokens.cream);
          expect(shape.side.color, BrandTokens.plum500);
        }
      });

      // Material's own button defaults define `iconColor` separately from
      // `foregroundColor` (FilledButton -> onPrimary, OutlinedButton ->
      // primary), and a style that pins only the foreground leaves the icon
      // on that default — a white icon beside a dark-brown label on the honey
      // primary, and a honey icon beside a cream label on the dark secondary.
      // The icon must always match the label it sits next to.
      testWidgets('$name: an icon matches its label on both button kinds', (
        tester,
      ) async {
        await tester.pumpWidget(
          themed(
            theme,
            Column(
              children: [
                PrimaryActionButton(
                  label: 'Save',
                  icon: Icons.check,
                  onPressed: () {},
                ),
                SecondaryActionButton(
                  label: 'Cancel',
                  icon: Icons.close,
                  onPressed: () {},
                ),
              ],
            ),
          ),
        );

        expect(iconColor(tester, Icons.check), BrandTokens.onHoney);
        expect(iconColor(tester, Icons.check), labelColor(tester, 'Save'));
        expect(iconColor(tester, Icons.close), isNot(BrandTokens.honey));
        expect(iconColor(tester, Icons.close), labelColor(tester, 'Cancel'));
      });

      // `busy` also disables the button, and a disabled FilledButton drops the
      // honey fill for Material's `onSurface @ 12%` grey — so the spinner must
      // read on THAT ground, not on honey. Pinning it to the on-honey ink
      // would leave it at 1.15:1 in dark mode.
      testWidgets('$name: the busy spinner reads on the disabled ground', (
        tester,
      ) async {
        await tester.pumpWidget(
          themed(
            theme,
            PrimaryActionButton(label: 'Save', busy: true, onPressed: () {}),
          ),
        );

        final indicator = tester.widget<CircularProgressIndicator>(
          find.byType(CircularProgressIndicator),
        );
        expect(indicator.color, theme.colorScheme.onSurface);
      });
    }

    testWidgets('destructive secondary still overrides to the error color, '
        'icon included', (tester) async {
      final theme = AppTheme.light();
      await tester.pumpWidget(
        themed(
          theme,
          SecondaryActionButton(
            label: 'Delete',
            icon: Icons.delete_outline,
            destructive: true,
            onPressed: () {},
          ),
        ),
      );

      expect(labelColor(tester, 'Delete'), theme.colorScheme.error);
      expect(iconColor(tester, Icons.delete_outline), theme.colorScheme.error);
    });
  });
}
