import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/todos/todo_assignee_picker_field.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _roster = {'m1': 'Maria Silva', 'm2': 'Joao Costa'};

/// A small stateful host so the picker's own `onChanged` callback genuinely
/// drives its `selectedAssigneeId` prop back in, exactly as the real form
/// (todo_form_screen.dart) does — mirrors
/// todo_apiary_picker_field_test.dart's own `_Harness`.
class _Harness extends StatefulWidget {
  const _Harness({
    required this.initial,
    required this.onChanged,
    this.memberNames = _roster,
  });

  final String? initial;
  final ValueChanged<String?> onChanged;
  final Map<String, String> memberNames;

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
        memberNamesProvider.overrideWith((ref) async => widget.memberNames),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TodoAssigneePickerField(
            selectedAssigneeId: _selected,
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
  group('TodoAssigneePickerField (#293, FR-TD-1)', () {
    testWidgets('lists every org member as a selectable row', (tester) async {
      await tester.pumpWidget(_Harness(initial: null, onChanged: (_) {}));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('todo-assignee-option-m1')), findsOneWidget);
      expect(find.byKey(const Key('todo-assignee-option-m2')), findsOneWidget);
      expect(find.text('Maria Silva'), findsOneWidget);
      expect(find.text('Joao Costa'), findsOneWidget);
    });

    testWidgets(
      'the "Unassigned" clear row is always shown and starts selected when '
      'there is no current assignee',
      (tester) async {
        await tester.pumpWidget(_Harness(initial: null, onChanged: (_) {}));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('todo-assignee-option-none')),
          findsOneWidget,
        );
        expect(find.text('Unassigned'), findsOneWidget);
        expect(
          _trailingIcon(tester, const Key('todo-assignee-option-none')).icon,
          Icons.radio_button_checked,
        );
      },
    );

    testWidgets(
      'tapping a different member REPLACES the prior selection (single-'
      'select, not additive)',
      (tester) async {
        final changes = <String?>[];
        await tester.pumpWidget(
          _Harness(initial: 'm1', onChanged: changes.add),
        );
        await tester.pumpAndSettle();

        expect(
          _trailingIcon(tester, const Key('todo-assignee-option-m1')).icon,
          Icons.radio_button_checked,
        );

        await tester.tap(find.byKey(const Key('todo-assignee-option-m2')));
        await tester.pumpAndSettle();

        expect(changes, ['m2']);
        expect(
          _trailingIcon(tester, const Key('todo-assignee-option-m2')).icon,
          Icons.radio_button_checked,
        );
        expect(
          _trailingIcon(tester, const Key('todo-assignee-option-m1')).icon,
          Icons.radio_button_unchecked,
        );
      },
    );

    testWidgets('tapping "Unassigned" clears an existing assignee', (
      tester,
    ) async {
      final changes = <String?>[];
      await tester.pumpWidget(_Harness(initial: 'm1', onChanged: changes.add));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('todo-assignee-option-none')));
      await tester.pumpAndSettle();

      expect(changes, [null]);
    });

    testWidgets(
      'an empty roster (offline / org not loaded yet) still shows the '
      'Unassigned clear row plus a "none available" message',
      (tester) async {
        await tester.pumpWidget(
          _Harness(initial: null, onChanged: (_) {}, memberNames: const {}),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('todo-assignee-option-none')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('todo-assignee-empty')), findsOneWidget);
      },
    );

    testWidgets(
      'offline: clearing an already-assigned todo still works even though '
      'the roster is empty (only the assignee\'s own fallback row and the '
      'Unassigned row render)',
      (tester) async {
        final changes = <String?>[];
        await tester.pumpWidget(
          _Harness(
            initial: 'm1',
            onChanged: changes.add,
            memberNames: const {},
          ),
        );
        await tester.pumpAndSettle();

        // No "none available" message: the currently-assigned id still gets
        // its own (fallback-labeled) row rather than an empty list.
        expect(find.byKey(const Key('todo-assignee-empty')), findsNothing);
        expect(
          find.byKey(const Key('todo-assignee-option-m1')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('todo-assignee-option-none')));
        await tester.pumpAndSettle();

        expect(changes, [null]);
      },
    );

    testWidgets(
      'a currently-selected assignee id not (yet) in the roster renders its '
      'own short-id fallback row instead of a blank/missing selection',
      (tester) async {
        await tester.pumpWidget(
          _Harness(
            initial: 'abcdefgh12345678',
            onChanged: (_) {},
            memberNames: const {},
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Member 12345678'), findsOneWidget);
        expect(
          _trailingIcon(
            tester,
            const Key('todo-assignee-option-abcdefgh12345678'),
          ).icon,
          Icons.radio_button_checked,
        );
      },
    );
  });
}
