import 'dart:ui' show Tristate;

import 'package:beekeepingit_client/core/widgets/option_row.dart';
import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/a11y_matchers.dart';

/// Unit coverage for the shared picker row (#762, D-18) — the skeleton four
/// hand-rolled tiles (`todo_apiary_picker_field.dart`,
/// `todo_assignee_picker_field.dart`, `apiary_multi_select_field.dart`,
/// `new_activity_flow_screen.dart`) used to duplicate. Each call site's own
/// existing widget test still asserts its concrete behaviour (labels, tap
/// wiring, colors); this file only asserts the skeleton contract every mode
/// shares: exactly one [Icon] under the row's key, a `Semantics(button:,
/// label:)` with `selected` present/absent per [OptionRowMode], an
/// [ExcludeSemantics] hiding the inner content from the semantics tree, a
/// >=44x44 tap target (D-18), and — unlike `lib/core/widgets/`, this test
/// file is free to import `theming/` — that every row's text still RESOLVES
/// to the app's own body font via [AppTheme]'s ambient `Material` style
/// rather than a pin `option_row.dart` cannot take (see that file's own doc
/// comment, and #628).
Widget _harness(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Like [_harness], but under the app's REAL [AppTheme] rather than
/// Flutter's own default `ThemeData` — needed for the `fontFamily`
/// resolution checks below, since the default `ThemeData` has no opinion on
/// `fontFamily` at all and would pass those checks for the wrong reason.
Widget _harnessWithAppTheme(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: child),
);

void main() {
  group('OptionRow (#762, D-18)', () {
    for (final mode in OptionRowMode.values) {
      testWidgets('$mode renders exactly one Icon under its key', (
        tester,
      ) async {
        const key = Key('option-row-under-test');
        await tester.pumpWidget(
          _harness(
            OptionRow(
              key: key,
              label: 'Serra Norte',
              mode: mode,
              selected: mode == OptionRowMode.navigate ? null : false,
              onTap: () {},
            ),
          ),
        );

        expect(
          find.descendant(of: find.byKey(key), matching: find.byType(Icon)),
          findsOneWidget,
        );
      });
    }

    testWidgets(
      'selected is present (true) for singleSelect/multiSelect when supplied',
      (tester) async {
        const key = Key('option-row-selected-true');
        await tester.pumpWidget(
          _harness(
            OptionRow(
              key: key,
              label: 'Serra Norte',
              mode: OptionRowMode.singleSelect,
              selected: true,
              onTap: () {},
            ),
          ),
        );

        final data = tester.getSemantics(find.byKey(key)).getSemanticsData();
        expect(data.flagsCollection.isSelected, Tristate.isTrue);
      },
    );

    testWidgets(
      'selected is present (false) for singleSelect/multiSelect when supplied',
      (tester) async {
        const key = Key('option-row-selected-false');
        await tester.pumpWidget(
          _harness(
            OptionRow(
              key: key,
              label: 'Serra Norte',
              mode: OptionRowMode.multiSelect,
              selected: false,
              onTap: () {},
            ),
          ),
        );

        final data = tester.getSemantics(find.byKey(key)).getSemanticsData();
        expect(data.flagsCollection.isSelected, Tristate.isFalse);
      },
    );

    testWidgets('selected is absent (null) for the navigate mode', (
      tester,
    ) async {
      const key = Key('option-row-navigate');
      await tester.pumpWidget(
        _harness(
          OptionRow(
            key: key,
            label: 'Serra Norte',
            mode: OptionRowMode.navigate,
            selected: null,
            onTap: () {},
          ),
        ),
      );

      // Omitting `selected` altogether means the semantics node carries
      // neither an isTrue NOR an isFalse selected state — unlike an
      // explicit `selected: false`, which resolves to `Tristate.isFalse`.
      final data = tester.getSemantics(find.byKey(key)).getSemanticsData();
      expect(data.flagsCollection.isSelected, Tristate.none);
    });

    testWidgets('carries a Semantics(button: true, label:) node', (
      tester,
    ) async {
      const key = Key('option-row-semantics-label');
      await tester.pumpWidget(
        _harness(
          OptionRow(
            key: key,
            label: 'Serra Norte',
            mode: OptionRowMode.singleSelect,
            selected: false,
            onTap: () {},
          ),
        ),
      );

      final node = tester.getSemantics(find.byKey(key));
      final data = node.getSemanticsData();
      expect(data.flagsCollection.isButton, isTrue);
      // Exactly the row's own label — proves ExcludeSemantics stopped the
      // inner Text from ALSO merging its own label up (the duplicate-
      // announcement defect #662 fixed elsewhere).
      expect(node.label, 'Serra Norte');
    });

    testWidgets('meets the 44x44 minimum tap target for every mode', (
      tester,
    ) async {
      for (final mode in OptionRowMode.values) {
        final key = Key('option-row-tap-target-$mode');
        await tester.pumpWidget(
          _harness(
            OptionRow(
              key: key,
              label: 'Serra Norte',
              mode: mode,
              selected: mode == OptionRowMode.navigate ? null : false,
              onTap: () {},
            ),
          ),
        );
        expectMinTapTarget(tester, find.byKey(key));
      }
    });

    testWidgets('invokes onTap when tapped', (tester) async {
      var tapped = false;
      const key = Key('option-row-tap');
      await tester.pumpWidget(
        _harness(
          OptionRow(
            key: key,
            label: 'Serra Norte',
            mode: OptionRowMode.singleSelect,
            selected: false,
            onTap: () => tapped = true,
          ),
        ),
      );

      await tester.tap(find.byKey(key));
      expect(tapped, isTrue);
    });

    testWidgets('renders an optional subtitle line (navigate mode)', (
      tester,
    ) async {
      const key = Key('option-row-subtitle');
      await tester.pumpWidget(
        _harness(
          OptionRow(
            key: key,
            label: 'Serra Norte',
            subtitle: '4 hives',
            mode: OptionRowMode.navigate,
            onTap: () {},
          ),
        ),
      );

      expect(find.text('4 hives'), findsOneWidget);
    });

    group('fontFamily resolves to AppTheme.bodyFontFamily via the ambient '
        'Material style, not a pin (#628)', () {
      for (final mode in OptionRowMode.values) {
        testWidgets('$mode label resolves to AppTheme.bodyFontFamily', (
          tester,
        ) async {
          await tester.pumpWidget(
            _harnessWithAppTheme(
              OptionRow(
                label: 'Serra Norte',
                mode: mode,
                selected: mode == OptionRowMode.navigate ? null : false,
                onTap: () {},
              ),
            ),
          );

          // The RESOLVED style a RenderParagraph actually paints with —
          // Text.build() already merges its own TextStyle with
          // DefaultTextStyle.of(context) before handing it to RichText, so
          // this is what a `fontFamily:` PIN would also have to agree
          // with. Asserting the resolved value (rather than a value
          // `OptionRow` itself declares) is what would have caught #628's
          // failure mode — a theme-level change silently repointing the
          // font — where a pin on this widget alone would not.
          final paragraph = tester.renderObject<RenderParagraph>(
            find.text('Serra Norte'),
          );
          expect(paragraph.text.style?.fontFamily, AppTheme.bodyFontFamily);
        });
      }

      testWidgets(
        'navigate mode subtitle also resolves to AppTheme.bodyFontFamily',
        (tester) async {
          await tester.pumpWidget(
            _harnessWithAppTheme(
              OptionRow(
                label: 'Serra Norte',
                subtitle: '4 hives',
                mode: OptionRowMode.navigate,
                onTap: () {},
              ),
            ),
          );

          final paragraph = tester.renderObject<RenderParagraph>(
            find.text('4 hives'),
          );
          expect(paragraph.text.style?.fontFamily, AppTheme.bodyFontFamily);
        },
      );
    });
  });
}
