import 'dart:io';

import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/features/todos/todo_filter_bar.dart';
import 'package:beekeepingit_client/features/todos/todo_filters.dart';
import 'package:beekeepingit_client/features/todos/todo_list_widgets.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/a11y_matchers.dart';

/// Density/a11y regression tests for the compacted Todos filter bar (#635,
/// FR-UX-1, FR-AX-1, D-18) — the concrete, measured form of the redesign's
/// own promise: a bar that no longer eats a third of a small phone's
/// viewport, with every control still meeting this app's tap-target and
/// screen-reader-label bar.
///
/// Mirrors `activity_row_density_test.dart`'s own conventions: real fonts
/// loaded (text metrics are the whole subject of the height/overflow
/// assertions here), and every numeric floor/ceiling below is MEASURED
/// first and then set with headroom — never assumed.
///
/// [TodoFilterBar] and [TodoListView] are rendered directly here, not the
/// app shell: that isolates the measurement from shell chrome and from open
/// PR #774/#773 (which move the bottom nav's own inset but cannot move the
/// TOP of this list, the only edge these tests measure from).
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

/// Measured bar height at [kHandsetViewport], with every filter set to its
/// LONGEST (`pt`) value (status=Concluída, priority=Média,
/// due=Vence esta semana) — a flat 112px at every scale this suite covers
/// (`TextScaler.noScaling`, 1.5x, 2.0x alike). It stays flat because
/// [BrandChip]'s own 44px `minHeight` floor absorbs the label's growth
/// across that whole range (a 14px label reaches ~28px tall at 2.0x, still
/// under 44px) — only a label tall enough to exceed that floor would ever
/// grow the bar. Set at 140: ~25% headroom over the measured 112, so a
/// longer future label (one that finally crosses the chip's own floor), a
/// larger base font, or an extra pixel of padding trips this rather than
/// only being noticed once it has silently eaten more of the row budget
/// checked below.
const double _barHeightCeiling = 140;

/// Rows fully on screen below the bar at [kHandsetViewport], default text
/// scale, with the bar showing the same longest (`pt`) filter values as
/// [_barHeightCeiling] — measured at 7. No headroom subtracted (mirrors
/// `activity_row_density_test.dart`'s own "restate the measured number, not
/// an assumed one" convention): a regression that drops this below 7 should
/// fail here immediately.
const int _minRowsFullyVisible = 7;

Todo _todo(String id, {String title = 'Todo'}) => Todo(
  id: id,
  title: title,
  priority: 'medium',
  status: 'open',
  dueDate: '2026-02-01',
  organizationId: 'org-1',
);

/// Every interactive key the bar renders with [status] = done, `priority` =
/// medium and `due` = thisWeek — every status chip plus the two menu chips,
/// the sort-field chip, the sort-direction button, and (since that filter
/// combination is non-default) the clear button.
const _allInteractiveKeys = [
  'todo-filter-status-chip-all',
  'todo-filter-status-chip-open',
  'todo-filter-status-chip-overdue',
  'todo-filter-status-chip-done',
  'todo-filter-priority-chip',
  'todo-filter-due-chip',
  'todo-sort-field-chip',
  'todo-sort-direction-button',
  'todo-filter-clear-button',
];

Widget _buildScreen({
  required TextScaler textScaler,
  Locale locale = const Locale('pt', 'PT'),
  int todoCount = 15,
  TodoStatusFilter status = TodoStatusFilter.done,
  String? priority = 'medium',
  TodoDueFilter due = TodoDueFilter.thisWeek,
  SortDirection sortDirection = SortDirection.descending,
}) {
  return MaterialApp(
    locale: locale,
    theme: AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: kSupportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: Scaffold(
      // Mirrors todos_list_screen.dart's own layout — the bar above an
      // Expanded list — without the shell chrome around it.
      body: Column(
        children: [
          TodoFilterBar(
            status: status,
            priority: priority,
            due: due,
            sortField: TodoSortField.priority,
            sortDirection: sortDirection,
            onStatusChanged: (_) {},
            onPriorityChanged: (_) {},
            onDueChanged: (_) {},
            onSortFieldChanged: (_) {},
            onSortDirectionToggle: () {},
            onClearFilters: () {},
          ),
          Expanded(
            child: TodoListView(
              viewModel: AsyncValue.data(
                TodosViewModel(
                  hasAnyTodos: true,
                  filtered: [for (var i = 0; i < todoCount; i++) _todo('t$i')],
                  today: DateTime(2026, 1, 1),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Every "value" [RenderParagraph] in the tree — a [BrandChip]'s own label
/// or a sheet [ListTile]'s option text — filtering out `MaterialIcons`
/// glyphs (icons also render as a paragraph in that family).
///
/// Deliberately NOT "every paragraph in the tree": a bottom sheet's
/// [SectionHeader] is BY DESIGN set in the display serif (its own doc
/// comment, `brand_widgets.dart`) — the same as every other sheet in this
/// app (`_AddCounterSheet`'s own header, `journey_picker.dart`'s). #628 was
/// never about headings; it was about a filter's own SELECTED/READ value
/// silently inheriting that heading font. A chip's label and a sheet
/// option's text are this bar's equivalent of that value, so those are what
/// this sweep checks.
List<RenderParagraph> _valueTextParagraphs(WidgetTester tester) {
  final paragraphs = <RenderParagraph>[
    ...tester.renderObjectList<RenderParagraph>(
      find.descendant(
        of: find.byType(BrandChip),
        matching: find.byType(RichText),
      ),
    ),
    ...tester.renderObjectList<RenderParagraph>(
      find.descendant(
        of: find.byType(ListTile),
        matching: find.byType(RichText),
      ),
    ),
  ];
  return paragraphs
      .where((p) => p.text.style?.fontFamily != 'MaterialIcons')
      .toList();
}

void main() {
  setUpAll(_loadAppFonts);

  group('bar height stays compact at every text scale (#635)', () {
    for (final scale in const [
      TextScaler.noScaling,
      TextScaler.linear(1.5),
      TextScaler.linear(2.0),
    ]) {
      final label = '${scale.scale(1).toStringAsFixed(1)}x';

      testWidgets('at $label the bar renders within the height ceiling, '
          'with nothing reported', (tester) async {
        useViewport(tester);
        await tester.pumpWidget(_buildScreen(textScaler: scale));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        final height = tester
            .getSize(find.byKey(const Key('todo-filter-bar')))
            .height;
        expect(
          height,
          lessThanOrEqualTo(_barHeightCeiling),
          reason:
              'the bar rendered ${height.toStringAsFixed(1)}px at $label, '
              'over the $_barHeightCeiling ceiling',
        );
      });
    }
  });

  testWidgets(
    'at least $_minRowsFullyVisible todo rows fit fully on screen below the '
    'bar at default text scale',
    (tester) async {
      useViewport(tester);
      await tester.pumpWidget(_buildScreen(textScaler: TextScaler.noScaling));
      await tester.pumpAndSettle();

      var fullyVisible = 0;
      for (var i = 0; i < 15; i++) {
        final finder = find.byKey(Key('todo-t$i'));
        if (finder.evaluate().isEmpty) continue;
        if (tester.getRect(finder).bottom <= kHandsetViewport.height) {
          fullyVisible++;
        }
      }

      expect(
        fullyVisible,
        greaterThanOrEqualTo(_minRowsFullyVisible),
        reason:
            'only $fullyVisible todo rows fit fully on a '
            '${kHandsetViewport.height.toInt()}px screen below the bar',
      );
    },
  );

  group('the sort-direction/clear icon buttons announce a real label (#635, '
      'AC-2)', () {
    for (final locale in const [Locale('en', 'GB'), Locale('pt', 'PT')]) {
      testWidgets(
        'in ${locale.languageCode}, the sort-direction button\'s semantics '
        'label names the active direction, not a bare "Ascending"',
        (tester) async {
          useViewport(tester);
          await tester.pumpWidget(
            _buildScreen(
              textScaler: TextScaler.noScaling,
              locale: locale,
              sortDirection: SortDirection.ascending,
            ),
          );
          await tester.pumpAndSettle();

          const key = Key('todo-sort-direction-button');
          expectHasSemanticsLabel(tester, key);
          final label = tester.getSemantics(find.byKey(key)).label;
          final l10n = lookupAppLocalizations(locale);
          expect(
            label,
            contains(l10n.todoSortDirectionAscendingLabel),
            reason:
                'the button\'s own label must contain the LOCALIZED '
                'direction word ("${l10n.todoSortDirectionAscendingLabel}"), '
                'not a hardcoded English one',
          );
        },
      );

      testWidgets(
        'in ${locale.languageCode}, the clear-filters button has a real '
        'semantics label',
        (tester) async {
          useViewport(tester);
          await tester.pumpWidget(
            _buildScreen(textScaler: TextScaler.noScaling, locale: locale),
          );
          await tester.pumpAndSettle();

          expectHasSemanticsLabel(
            tester,
            const Key('todo-filter-clear-button'),
          );
        },
      );
    }
  });

  group('every chip and icon button meets the 44x44 tap-target floor (#635, '
      'D-18)', () {
    for (final scale in const [TextScaler.noScaling, TextScaler.linear(2.0)]) {
      final label = '${scale.scale(1).toStringAsFixed(1)}x';

      testWidgets('at $label', (tester) async {
        useViewport(tester);
        await tester.pumpWidget(_buildScreen(textScaler: scale));
        await tester.pumpAndSettle();

        for (final key in _allInteractiveKeys) {
          expectMinTapTarget(tester, find.byKey(Key(key)));
        }
      });
    }
  });

  group('#628 anti-regression: no text in the bar or its sheets is set in '
      'the display serif', () {
    testWidgets('the bar itself is all body font', (tester) async {
      useViewport(tester);
      await tester.pumpWidget(_buildScreen(textScaler: TextScaler.noScaling));
      await tester.pumpAndSettle();

      for (final paragraph in _valueTextParagraphs(tester)) {
        expect(
          paragraph.text.style?.fontFamily,
          isNot(AppTheme.displayFontFamily),
          reason:
              '"${paragraph.text.toPlainText()}" is set in the display '
              'serif — dropdown/menu values regressed to it once before '
              '(#628)',
        );
      }
    });

    for (final (chipKeyName, sheetKeyName) in const [
      ('todo-filter-priority-chip', 'todo-filter-priority-sheet'),
      ('todo-filter-due-chip', 'todo-filter-due-sheet'),
      ('todo-sort-field-chip', 'todo-sort-field-sheet'),
    ]) {
      testWidgets('the $sheetKeyName is all body font too', (tester) async {
        useViewport(tester);
        await tester.pumpWidget(_buildScreen(textScaler: TextScaler.noScaling));
        await tester.pumpAndSettle();

        // The menu chips share a scrollable row (#635) and the longest (pt)
        // labels push the later ones out of the 375px viewport — scroll the
        // target into view before tapping it, same as any other horizontal
        // scrollable in this suite.
        await tester.ensureVisible(find.byKey(Key(chipKeyName)));
        await tester.tap(find.byKey(Key(chipKeyName)));
        await tester.pumpAndSettle();
        expect(find.byKey(Key(sheetKeyName)), findsOneWidget);

        for (final paragraph in _valueTextParagraphs(tester)) {
          expect(
            paragraph.text.style?.fontFamily,
            isNot(AppTheme.displayFontFamily),
            reason:
                '"${paragraph.text.toPlainText()}" is set in the display '
                'serif inside $sheetKeyName (#628)',
          );
        }
      });
    }
  });
}
