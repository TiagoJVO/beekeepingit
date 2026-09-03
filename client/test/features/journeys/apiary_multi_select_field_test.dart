import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/journeys/apiary_multi_select_field.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives [ApiaryMultiSelectField]'s callback-based selection exactly like the
/// real owning forms (journey_form_screen.dart / journey_quick_create_sheet.dart)
/// do — holding the selected `Set<String>` and rebuilding on [onChanged] — so
/// the widget's bulk-action feedback (#425, FR-JO-4) is exercised end to end.
class _Host extends StatefulWidget {
  const _Host({required this.initial, this.onEmit});

  final Set<String> initial;

  /// Fires once per [ApiaryMultiSelectField.onChanged] call — lets a test
  /// assert that a no-op bulk tap does NOT notify the form (and so does not
  /// arm the unsaved-changes leave-guard the real form wires to `onChanged`).
  final VoidCallback? onEmit;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late Set<String> _selected = {...widget.initial};

  @override
  Widget build(BuildContext context) {
    return ApiaryMultiSelectField(
      selectedApiaryIds: _selected,
      onChanged: (ids) {
        widget.onEmit?.call();
        setState(() => _selected = ids);
      },
    );
  }
}

Widget _wrap(
  List<Apiary> apiaries, {
  Set<String> initial = const {},
  VoidCallback? onEmit,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return ProviderScope(
    overrides: [
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: SingleChildScrollView(
              child: _Host(initial: initial, onEmit: onEmit),
            ),
          ),
        ),
      ),
    ),
  );
}

/// True when the row for [apiaryId] renders a filled (checked) checkbox.
/// A checked row uses [Icons.check_box]; an unchecked one uses
/// [Icons.check_box_outline_blank] — distinct icons, so this only matches the
/// checked state.
bool _isChecked(WidgetTester tester, String apiaryId) {
  final tile = find.byKey(Key('journey-apiary-option-$apiaryId'));
  return tester
      .widgetList(
        find.descendant(of: tile, matching: find.byIcon(Icons.check_box)),
      )
      .isNotEmpty;
}

void main() {
  const apiaries = [
    Apiary(id: 'a1', name: 'Norte', hiveCount: 3),
    Apiary(id: 'a2', name: 'Sul', hiveCount: 5),
    Apiary(id: 'a3', name: 'Encosta Norte', hiveCount: 2),
  ];

  group('ApiaryMultiSelectField bulk actions (#425, FR-JO-4)', () {
    testWidgets('select all with no filter selects every apiary', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(apiaries));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('journey-apiaries-select-all')));
      await tester.pumpAndSettle();

      expect(_isChecked(tester, 'a1'), isTrue);
      expect(_isChecked(tester, 'a2'), isTrue);
      expect(_isChecked(tester, 'a3'), isTrue);
      expect(find.text('3 apiaries selected'), findsOneWidget);
    });

    testWidgets('select all respects the active search filter', (tester) async {
      await tester.pumpWidget(_wrap(apiaries));
      await tester.pumpAndSettle();

      // Narrow to the two "Norte" apiaries (a1, a3); "Sul" (a2) is filtered out.
      await tester.enterText(
        find.byKey(const Key('journey-apiaries-search-field')),
        'norte',
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('journey-apiaries-select-all')));
      await tester.pumpAndSettle();

      // Only the filtered set was selected.
      expect(find.text('2 apiaries selected'), findsOneWidget);

      // Clear the search so every row is visible again, then confirm the
      // filtered-out apiary was NOT selected by the bulk action.
      await tester.enterText(
        find.byKey(const Key('journey-apiaries-search-field')),
        '',
      );
      await tester.pumpAndSettle();

      expect(_isChecked(tester, 'a1'), isTrue);
      expect(_isChecked(tester, 'a3'), isTrue);
      expect(_isChecked(tester, 'a2'), isFalse);
    });

    testWidgets('clear all empties the whole selection', (tester) async {
      await tester.pumpWidget(_wrap(apiaries, initial: {'a1', 'a2'}));
      await tester.pumpAndSettle();

      expect(find.text('2 apiaries selected'), findsOneWidget);

      await tester.tap(find.byKey(const Key('journey-apiaries-clear-all')));
      await tester.pumpAndSettle();

      expect(find.text('No apiaries selected'), findsOneWidget);
      expect(_isChecked(tester, 'a1'), isFalse);
      expect(_isChecked(tester, 'a2'), isFalse);
    });

    testWidgets('a no-op bulk tap does not notify the form (no dirty guard)', (
      tester,
    ) async {
      var emitCount = 0;
      // Selection already empty, so "Clear all" computes an identical set.
      await tester.pumpWidget(_wrap(apiaries, onEmit: () => emitCount++));
      await tester.pumpAndSettle();

      expect(find.text('No apiaries selected'), findsOneWidget);

      await tester.tap(find.byKey(const Key('journey-apiaries-clear-all')));
      await tester.pumpAndSettle();

      // No change emitted — the leave-guard stays disarmed.
      expect(emitCount, 0);
      expect(find.text('No apiaries selected'), findsOneWidget);

      // Now select everything, then tap "Select all" again — the second tap is
      // a no-op (filtered set already fully selected) and must not re-notify.
      await tester.tap(find.byKey(const Key('journey-apiaries-select-all')));
      await tester.pumpAndSettle();
      expect(emitCount, 1);

      await tester.tap(find.byKey(const Key('journey-apiaries-select-all')));
      await tester.pumpAndSettle();
      expect(emitCount, 1);
    });

    testWidgets('bulk controls do not overflow at a narrow width + large text '
        'scale', (tester) async {
      // A small phone width with a large OS text scale — the worst case for a
      // fixed Row (FR-AX-1 text-scaling).
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(apiaries, textScaler: const TextScaler.linear(2.0)),
      );
      await tester.pumpAndSettle();

      // Both controls render and the layout laid out without a RenderFlex
      // overflow (which would surface as a caught exception).
      expect(find.byKey(const Key('journey-apiaries-select-all')), findsOne);
      expect(find.byKey(const Key('journey-apiaries-clear-all')), findsOne);
      expect(tester.takeException(), isNull);
    });
  });
}
