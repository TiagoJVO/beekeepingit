import 'dart:io';

import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/features/todos/todo_filters.dart';
import 'package:beekeepingit_client/features/todos/todo_list_widgets.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Layout regression tests for the Todos filter bar (#626, NFR-I18N-1,
/// FR-UX-1, FR-TD-1).
///
/// The defect: at a 375 CSS px viewport `Estado` and `Prioridade` shared one
/// row (~155 px each), which is not wide enough for the Portuguese
/// `Todas as prioridades` — the value soft-wrapped and the second line was
/// clipped by the dropdown's fixed-height button, so the filter read
/// `Todas as`: a dangling article, with no ellipsis to signal truncation.
/// English (`All priorities`) happens to fit, so nothing caught it.
///
/// These tests assert the invariant directly on the rendered text, in `pt`:
/// the selected value gets enough horizontal room to lay out on ONE line, and
/// at large text scales it degrades to a single ellipsized line rather than a
/// clipped mid-phrase one. Mirrors the "wrap the widget directly" convention
/// of journey_stats_section_test.dart rather than booting the whole app.

/// A 375 CSS px-wide viewport — the narrowest phone width the PWA targets,
/// and the width the issue reproduces at.
const _narrowViewport = Size(375, 812);

/// A tablet-width viewport, wide enough for the two-up filter row.
const _wideViewport = Size(900, 1200);

/// Loads the app's real text fonts into the test binding.
///
/// Mandatory for this suite specifically: the default test font draws every
/// glyph as a full em square, so measured text comes out roughly twice as
/// wide as what a user sees, and a width assertion made against it would be
/// about a layout nobody ships. Both families are needed — a dropdown's
/// selected value inherits `textTheme.titleMedium`, which `AppTheme` puts on
/// Playfair Display, while the rest of the bar is Archivo. Read from disk
/// rather than `rootBundle` so the test does not depend on the tool's asset
/// bundle.
Future<void> _loadAppFonts() async {
  Future<void> load(String family, String path) async {
    final bytes = await File(path).readAsBytes();
    await (FontLoader(family)..addFont(
          Future.value(ByteData.sublistView(Uint8List.fromList(bytes))),
        ))
        .load();
  }

  await load(AppTheme.bodyFontFamily, 'fonts/Archivo/Archivo-Regular.ttf');
  await load(
    AppTheme.displayFontFamily,
    'fonts/PlayfairDisplay/PlayfairDisplay-SemiBold.ttf',
  );
}

Widget _buildBar({
  required Locale locale,
  TodoStatusFilter status = TodoStatusFilter.all,
  String? priority,
  TodoDueFilter due = TodoDueFilter.any,
  TodoSortField sortField = TodoSortField.priority,
  double textScale = 1.0,
}) {
  return MaterialApp(
    locale: locale,
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: kSupportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(
      body: TodoFilterBar(
        status: status,
        priority: priority,
        due: due,
        sortField: sortField,
        sortDirection: SortDirection.descending,
        onStatusChanged: (_) {},
        onPriorityChanged: (_) {},
        onDueChanged: (_) {},
        onSortFieldChanged: (_) {},
        onSortDirectionToggle: () {},
        onClearFilters: () {},
      ),
    ),
  );
}

/// The single [RenderParagraph] rendering [value] inside the field keyed
/// [fieldKey] — i.e. the dropdown's currently *shown* selection.
RenderParagraph _shownValue(WidgetTester tester, Key fieldKey, String value) {
  final finder = find.descendant(
    of: find.byKey(fieldKey),
    matching: find.text(value),
  );
  expect(
    finder,
    findsOneWidget,
    reason: '"$value" should be the shown selection of $fieldKey',
  );
  return tester.renderObject<RenderParagraph>(finder);
}

/// Fails when [value] does not have room to render on one line inside its
/// field — the #626 defect (clipped mid-phrase, no ellipsis).
void _expectValueFitsOnOneLine(
  WidgetTester tester,
  Key fieldKey,
  String value,
) {
  final paragraph = _shownValue(tester, fieldKey, value);
  final painter = TextPainter(
    text: paragraph.text,
    textDirection: TextDirection.ltr,
    textScaler: paragraph.textScaler,
  )..layout();
  expect(
    paragraph.size.width,
    greaterThanOrEqualTo(painter.width - 0.5),
    reason:
        '"$value" needs ${painter.width.toStringAsFixed(1)}px but the '
        '$fieldKey field gives it only '
        '${paragraph.size.width.toStringAsFixed(1)}px, so it is truncated',
  );
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason: '"$value" is truncated inside $fieldKey',
  );
  expect(
    paragraph.size.height,
    lessThan(paragraph.preferredLineHeight * 1.5),
    reason: '"$value" wrapped onto a second line inside $fieldKey',
  );
}

/// Fails when [value] renders on more than one line — at a large text scale
/// a value may legitimately no longer fit, but it must then ellipsize on a
/// single line, never wrap into a line the dropdown button clips away.
void _expectValueStaysOnOneLine(
  WidgetTester tester,
  Key fieldKey,
  String value,
) {
  final paragraph = _shownValue(tester, fieldKey, value);
  expect(
    paragraph.maxLines,
    1,
    reason: '$fieldKey\'s selected value must be capped at one line',
  );
  expect(
    paragraph.overflow,
    TextOverflow.ellipsis,
    reason: '$fieldKey\'s selected value must ellipsize when it cannot fit',
  );
  expect(
    paragraph.size.height,
    lessThan(paragraph.preferredLineHeight * 1.5),
    reason: '"$value" wrapped onto a second line inside $fieldKey',
  );
}

void main() {
  setUpAll(_loadAppFonts);

  group('TodoFilterBar values are never clipped mid-phrase (#626)', () {
    void useViewport(WidgetTester tester, Size size) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    void useNarrowViewport(WidgetTester tester) =>
        useViewport(tester, _narrowViewport);

    testWidgets(
      'the Portuguese priority filter shows "Todas as prioridades" in full, '
      'not clipped to "Todas as"',
      (tester) async {
        useNarrowViewport(tester);
        await tester.pumpWidget(_buildBar(locale: const Locale('pt')));
        await tester.pumpAndSettle();

        _expectValueFitsOnOneLine(
          tester,
          const Key('todo-filter-priority-field'),
          'Todas as prioridades',
        );
      },
    );

    testWidgets('every Portuguese filter value fits on one line', (
      tester,
    ) async {
      useNarrowViewport(tester);
      await tester.pumpWidget(
        _buildBar(
          locale: const Locale('pt'),
          // The longest option of each filter, so the assertion covers the
          // worst case a user can select — not just the default.
          status: TodoStatusFilter.done,
          priority: todoPriorityMedium,
          due: TodoDueFilter.thisWeek,
          sortField: TodoSortField.priority,
        ),
      );
      await tester.pumpAndSettle();

      _expectValueFitsOnOneLine(
        tester,
        const Key('todo-filter-status-field'),
        'Concluída',
      );
      _expectValueFitsOnOneLine(
        tester,
        const Key('todo-filter-priority-field'),
        'Média',
      );
      _expectValueFitsOnOneLine(
        tester,
        const Key('todo-filter-due-field'),
        'Vence esta semana',
      );
      _expectValueFitsOnOneLine(
        tester,
        const Key('todo-sort-field-field'),
        'Prioridade',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('English filter values fit on one line too', (tester) async {
      useNarrowViewport(tester);
      await tester.pumpWidget(
        _buildBar(locale: const Locale('en'), due: TodoDueFilter.thisMonth),
      );
      await tester.pumpAndSettle();

      _expectValueFitsOnOneLine(
        tester,
        const Key('todo-filter-priority-field'),
        'All priorities',
      );
      _expectValueFitsOnOneLine(
        tester,
        const Key('todo-filter-due-field'),
        'Due this month',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'the two-up status + priority row still fits at a tablet width',
      (tester) async {
        useViewport(tester, _wideViewport);
        await tester.pumpWidget(
          _buildBar(
            locale: const Locale('pt'),
            status: TodoStatusFilter.done,
            due: TodoDueFilter.thisWeek,
          ),
        );
        await tester.pumpAndSettle();

        // Guards the stack-below breakpoint from the other side: above it
        // both filters share one row, and both must still fit.
        _expectValueFitsOnOneLine(
          tester,
          const Key('todo-filter-status-field'),
          'Concluída',
        );
        _expectValueFitsOnOneLine(
          tester,
          const Key('todo-filter-priority-field'),
          'Todas as prioridades',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'at 2x text scale the Portuguese values ellipsize on one line instead '
      'of clipping mid-phrase',
      (tester) async {
        useNarrowViewport(tester);
        await tester.pumpWidget(
          _buildBar(
            locale: const Locale('pt'),
            due: TodoDueFilter.thisWeek,
            textScale: 2.0,
          ),
        );
        await tester.pumpAndSettle();

        _expectValueStaysOnOneLine(
          tester,
          const Key('todo-filter-priority-field'),
          'Todas as prioridades',
        );
        _expectValueStaysOnOneLine(
          tester,
          const Key('todo-filter-due-field'),
          'Vence esta semana',
        );
        expect(tester.takeException(), isNull);
      },
    );
  });
}
