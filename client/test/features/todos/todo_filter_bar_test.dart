import 'dart:io';

import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/features/todos/todo_filter_bar.dart';
import 'package:beekeepingit_client/features/todos/todo_filters.dart';
import 'package:beekeepingit_client/features/todos/todo_priority.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Layout regression tests for the compacted Todos filter bar (#635,
/// NFR-I18N-1, FR-UX-1, FR-TD-1) — the successor to the #626 suite this file
/// replaces.
///
/// #626's own defect (a `DropdownButtonFormField`'s selected value soft-
/// wrapping and getting clipped by the field's fixed height) cannot recur
/// here: there are no more dropdown fields. The four filters are now a
/// horizontally-scrollable [BrandChip] row (status) plus three menu chips
/// that open a bottom sheet (priority/due/sort field), per #635's own
/// design. The invariant this suite restates for the new shape:
///
///  * Every CHIP's own label — status word, or a menu chip's composed
///    `category: value` (`todoFilterChipLabel`) — renders in full on ONE
///    line, in `pt` (the longer locale), at default text scale AND at 2x. A
///    chip lives in an unbounded horizontal scroll row (this file's own
///    `SingleChildScrollView` + `Row`, not a `ListView` — see
///    todo_filter_bar.dart's own doc), so it is never width-constrained and
///    therefore never NEEDS to wrap or ellipsize: this suite asserts that
///    directly, which is the concrete, checkable form of "never clipped
///    mid-phrase" for a scrollable chip row.
///  * Every SHEET OPTION (a fixed-width `ListTile`, unlike a chip) renders
///    in full on one line at default scale and ellipsizes — never wraps
///    mid-phrase — if it no longer fits at 2x.
///
/// Mirrors the retired suite's own conventions: real fonts loaded (text
/// metrics are the whole subject here) and the widget wrapped directly
/// rather than booting the whole app.

/// A 375 CSS px-wide viewport — the narrowest phone width the PWA targets,
/// and the width the issue reproduces at.
const _narrowViewport = Size(375, 812);

/// A wide/tablet viewport, to prove the bar never needs a stacked/2-up
/// breakpoint (#626's own `_kStackFiltersBelowWidth`, retired by #635): a
/// scrollable chip row has nothing to stack.
const _wideViewport = Size(900, 1200);

/// Loads the app's real text fonts into the test binding.
///
/// Mandatory for this suite specifically: the default test font draws every
/// glyph as a full em square, so measured text comes out roughly twice as
/// wide as what a user sees, and a width assertion made against it would be
/// about a layout nobody ships. Both families are loaded so the measurement
/// holds whichever tier a widget here resolves — the bar itself is all
/// Archivo (#628). Read from disk rather than `rootBundle` so the test does
/// not depend on the tool's asset bundle.
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
  Size viewport = _narrowViewport,
}) {
  return MaterialApp(
    locale: locale,
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: kSupportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale), size: viewport),
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

void _useViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The single [RenderParagraph] rendering [value] as a chip's OWN label
/// (found by ancestor [BrandChip] rather than a fixed field key, since a
/// chip's key is per-value, e.g. `todo-filter-status-chip-overdue`).
RenderParagraph _chipText(WidgetTester tester, Key chipKey, String value) {
  final finder = find.descendant(
    of: find.byKey(chipKey),
    matching: find.text(value),
  );
  expect(
    finder,
    findsOneWidget,
    reason: '"$value" should be the $chipKey chip\'s own label',
  );
  return tester.renderObject<RenderParagraph>(finder);
}

/// Fails when [value] does not render as one, unwrapped, un-ellipsized line
/// inside the chip keyed [chipKey] — a chip lives in an unbounded horizontal
/// scroll row, so it should never need to wrap or truncate at all.
void _expectChipRendersFullyOnOneLine(
  WidgetTester tester,
  Key chipKey,
  String value,
) {
  final paragraph = _chipText(tester, chipKey, value);
  expect(
    paragraph.didExceedMaxLines,
    isFalse,
    reason: '"$value" is truncated inside $chipKey',
  );
  expect(
    paragraph.size.height,
    lessThan(paragraph.preferredLineHeight * 1.5),
    reason: '"$value" wrapped onto a second line inside $chipKey',
  );
  // No overflow set at all — an unbounded-width chip never needs one; a
  // maxLines/overflow appearing here would mean the chip started rendering
  // inside a WIDTH-CONSTRAINED context, and this suite's whole premise (a
  // chip can never be #626-style clipped) would need re-checking.
  expect(paragraph.text.toPlainText(), value);
}

/// Opens the bottom sheet keyed [chipKey] and returns the [ListTile] option
/// text keyed [optionKey]'s [RenderParagraph].
Future<RenderParagraph> _openSheetAndFindOption(
  WidgetTester tester,
  Key chipKey,
  Key optionKey,
) async {
  await tester.tap(find.byKey(chipKey));
  await tester.pumpAndSettle();
  final finder = find.descendant(
    of: find.byKey(optionKey),
    matching: find.byType(Text),
  );
  expect(finder, findsOneWidget, reason: '$optionKey should render one Text');
  return tester.renderObject<RenderParagraph>(finder);
}

void main() {
  setUpAll(_loadAppFonts);

  group('status chip row renders every value on one line (#635, pt)', () {
    testWidgets(
      'Concluída (the longest status word) fits on one line at default '
      'scale',
      (tester) async {
        _useViewport(tester, _narrowViewport);
        await tester.pumpWidget(
          _buildBar(locale: const Locale('pt'), status: TodoStatusFilter.done),
        );
        await tester.pumpAndSettle();

        _expectChipRendersFullyOnOneLine(
          tester,
          const Key('todo-filter-status-chip-done'),
          'Concluída',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('every status chip stays on one line at 2x text scale', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildBar(locale: const Locale('pt'), textScale: 2.0),
      );
      await tester.pumpAndSettle();

      for (final (key, label) in const [
        ('todo-filter-status-chip-all', 'Todas'),
        ('todo-filter-status-chip-open', 'Em aberto'),
        ('todo-filter-status-chip-overdue', 'Atrasada'),
        ('todo-filter-status-chip-done', 'Concluída'),
      ]) {
        _expectChipRendersFullyOnOneLine(tester, Key(key), label);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('menu chips compose "category: value" on one line (#635, pt)', () {
    testWidgets('Prioridade: Média fits on one line at default scale', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildBar(locale: const Locale('pt'), priority: todoPriorityMedium),
      );
      await tester.pumpAndSettle();

      _expectChipRendersFullyOnOneLine(
        tester,
        const Key('todo-filter-priority-chip'),
        'Prioridade: Média',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Prazo: Vence esta semana fits on one line at default scale', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildBar(locale: const Locale('pt'), due: TodoDueFilter.thisWeek),
      );
      await tester.pumpAndSettle();

      _expectChipRendersFullyOnOneLine(
        tester,
        const Key('todo-filter-due-chip'),
        'Prazo: Vence esta semana',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Ordenar por: Prioridade fits on one line at default scale', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(_buildBar(locale: const Locale('pt')));
      await tester.pumpAndSettle();

      _expectChipRendersFullyOnOneLine(
        tester,
        const Key('todo-sort-field-chip'),
        'Ordenar por: Prioridade',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('every menu chip stays on one line at 2x text scale', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildBar(
          locale: const Locale('pt'),
          priority: todoPriorityMedium,
          due: TodoDueFilter.thisWeek,
          textScale: 2.0,
        ),
      );
      await tester.pumpAndSettle();

      _expectChipRendersFullyOnOneLine(
        tester,
        const Key('todo-filter-priority-chip'),
        'Prioridade: Média',
      );
      _expectChipRendersFullyOnOneLine(
        tester,
        const Key('todo-filter-due-chip'),
        'Prazo: Vence esta semana',
      );
      _expectChipRendersFullyOnOneLine(
        tester,
        const Key('todo-sort-field-chip'),
        'Ordenar por: Prioridade',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('English chip labels fit on one line too (#635)', () {
    testWidgets('the default (cleared) menu chips show their bare category '
        'labels', (tester) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(_buildBar(locale: const Locale('en')));
      await tester.pumpAndSettle();

      _expectChipRendersFullyOnOneLine(
        tester,
        const Key('todo-filter-priority-chip'),
        'Priority',
      );
      _expectChipRendersFullyOnOneLine(
        tester,
        const Key('todo-filter-due-chip'),
        'Due',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('Due: Due this month fits on one line', (tester) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildBar(locale: const Locale('en'), due: TodoDueFilter.thisMonth),
      );
      await tester.pumpAndSettle();

      _expectChipRendersFullyOnOneLine(
        tester,
        const Key('todo-filter-due-chip'),
        'Due: Due this month',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('a wide viewport has nothing to stack (#635, replaces the retired '
      '480px breakpoint)', () {
    testWidgets(
      'the bar renders every control with no overflow and no vertical '
      'scrolling at a tablet width',
      (tester) async {
        _useViewport(tester, _wideViewport);
        await tester.pumpWidget(
          _buildBar(
            locale: const Locale('pt'),
            status: TodoStatusFilter.done,
            priority: todoPriorityMedium,
            due: TodoDueFilter.thisWeek,
            viewport: _wideViewport,
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        // Every chip is simultaneously visible (no stacking, no second
        // row needed) — the retired dropdown bar's own two-up breakpoint
        // has no equivalent here.
        for (final key in const [
          'todo-filter-status-chip-all',
          'todo-filter-status-chip-open',
          'todo-filter-status-chip-overdue',
          'todo-filter-status-chip-done',
          'todo-filter-priority-chip',
          'todo-filter-due-chip',
          'todo-sort-field-chip',
          'todo-sort-direction-button',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget);
        }
        _expectChipRendersFullyOnOneLine(
          tester,
          const Key('todo-filter-status-chip-done'),
          'Concluída',
        );
        _expectChipRendersFullyOnOneLine(
          tester,
          const Key('todo-filter-priority-chip'),
          'Prioridade: Média',
        );
      },
    );
  });

  group('sheet options render in full at default scale, ellipsized at 2x '
      '(#635, pt)', () {
    testWidgets(
      'every priority sheet option fits on one line at default scale',
      (tester) async {
        _useViewport(tester, _narrowViewport);
        await tester.pumpWidget(_buildBar(locale: const Locale('pt')));
        await tester.pumpAndSettle();

        final paragraph = await _openSheetAndFindOption(
          tester,
          const Key('todo-filter-priority-chip'),
          const Key('todo-filter-priority-option-all'),
        );
        expect(paragraph.text.toPlainText(), 'Todas as prioridades');
        expect(paragraph.didExceedMaxLines, isFalse);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the due sheet\'s longest option ellipsizes rather than wraps at 2x '
      'text scale',
      (tester) async {
        _useViewport(tester, _narrowViewport);
        await tester.pumpWidget(
          _buildBar(locale: const Locale('pt'), textScale: 2.0),
        );
        await tester.pumpAndSettle();

        final paragraph = await _openSheetAndFindOption(
          tester,
          const Key('todo-filter-due-chip'),
          const Key('todo-filter-due-option-thisWeek'),
        );
        expect(paragraph.maxLines, 1);
        expect(paragraph.overflow, TextOverflow.ellipsis);
        expect(
          paragraph.size.height,
          lessThan(paragraph.preferredLineHeight * 1.5),
          reason:
              'the option wrapped onto a second line instead of '
              'ellipsizing',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('the sort-field sheet options fit on one line at default '
        'scale', (tester) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(_buildBar(locale: const Locale('pt')));
      await tester.pumpAndSettle();

      final paragraph = await _openSheetAndFindOption(
        tester,
        const Key('todo-sort-field-chip'),
        const Key('todo-sort-field-option-priority'),
      );
      expect(paragraph.text.toPlainText(), 'Prioridade');
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
