import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/todos/todo_apiary_picker_field.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _apiaryA = Apiary(id: 'a1', name: 'Monte Alto', hiveCount: 4);
const _apiaryB = Apiary(id: 'a2', name: 'Serra Norte', hiveCount: 2);

/// A small stateful host so the picker's own `onChanged` callback genuinely
/// drives its `selectedApiaryId` prop back in, exactly as the real form
/// (todo_form_screen.dart) does — mirrors journey_stats_section_test.dart's
/// own "wrap the widget directly, skip the full app shell" convention.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.initial,
    required this.onChanged,
    this.apiaries = const [_apiaryA, _apiaryB],
  });

  final String? initial;
  final ValueChanged<String?> onChanged;
  final List<Apiary> apiaries;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial;
  }

  @override
  Widget build(BuildContext context) {
    return ProviderScope(
      overrides: [
        apiariesStreamProvider.overrideWith(
          (ref) => Stream.value(widget.apiaries),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TodoApiaryPickerField(
            selectedApiaryId: _selected,
            onChanged: (v) {
              widget.onChanged(v);
              setState(() => _selected = v);
            },
          ),
        ),
      ),
    );
  }
}

Icon _trailingIcon(WidgetTester tester, Key key) => tester.widget<Icon>(
  find.descendant(of: find.byKey(key), matching: find.byType(Icon)),
);

void main() {
  group('TodoApiaryPickerField (#293, #51, FR-TD-1)', () {
    testWidgets('lists every locally-synced apiary as a selectable row', (
      tester,
    ) async {
      await tester.pumpWidget(_Harness(initial: null, onChanged: (_) {}));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-apiary-option-a1')), findsOneWidget);
      expect(find.byKey(const Key('todo-apiary-option-a2')), findsOneWidget);
      expect(find.text('Monte Alto'), findsOneWidget);
      expect(find.text('Serra Norte'), findsOneWidget);
    });

    testWidgets(
      'the "No apiary" clear row is always shown and starts selected when '
      'there is no current association',
      (tester) async {
        await tester.pumpWidget(_Harness(initial: null, onChanged: (_) {}));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('todo-apiary-option-none')),
          findsOneWidget,
        );
        expect(
          _trailingIcon(
            tester,
            const Key('todo-apiary-option-none'),
          ).icon,
          Icons.radio_button_checked,
        );
      },
    );

    testWidgets(
      'tapping a different apiary REPLACES the prior selection (single-'
      'select, not additive)',
      (tester) async {
        final changes = <String?>[];
        await tester.pumpWidget(
          _Harness(initial: 'a1', onChanged: changes.add),
        );
        await tester.pumpAndSettle();

        expect(
          _trailingIcon(tester, const Key('todo-apiary-option-a1')).icon,
          Icons.radio_button_checked,
        );

        await tester.tap(find.byKey(const Key('todo-apiary-option-a2')));
        await tester.pumpAndSettle();

        expect(changes, ['a2']);
        expect(
          _trailingIcon(tester, const Key('todo-apiary-option-a2')).icon,
          Icons.radio_button_checked,
        );
        expect(
          _trailingIcon(tester, const Key('todo-apiary-option-a1')).icon,
          Icons.radio_button_unchecked,
        );
      },
    );

    testWidgets('tapping "No apiary" clears an existing selection', (
      tester,
    ) async {
      final changes = <String?>[];
      await tester.pumpWidget(_Harness(initial: 'a1', onChanged: changes.add));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('todo-apiary-option-none')));
      await tester.pumpAndSettle();

      expect(changes, [null]);
      expect(
        _trailingIcon(tester, const Key('todo-apiary-option-none')).icon,
        Icons.radio_button_checked,
      );
    });

    testWidgets(
      'an empty org apiary set still shows the clear row plus a "none '
      'available" message',
      (tester) async {
        await tester.pumpWidget(
          _Harness(initial: null, onChanged: (_) {}, apiaries: const []),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('todo-apiary-option-none')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('todo-apiary-empty')), findsOneWidget);
        expect(
          find.text('No apiaries yet — add one from the Apiaries tab first.'),
          findsOneWidget,
        );
      },
    );

    testWidgets('the search field narrows the visible apiaries', (
      tester,
    ) async {
      await tester.pumpWidget(_Harness(initial: null, onChanged: (_) {}));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('todo-apiary-search-field')),
        'Serra',
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-apiary-option-a2')), findsOneWidget);
      expect(find.byKey(const Key('todo-apiary-option-a1')), findsNothing);
      // The clear row is unaffected by the search text.
      expect(find.byKey(const Key('todo-apiary-option-none')), findsOneWidget);
    });
  });
}
