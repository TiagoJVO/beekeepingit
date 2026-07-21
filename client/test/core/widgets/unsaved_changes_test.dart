import 'package:beekeepingit_client/core/widgets/unsaved_changes.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/a11y_matchers.dart';

/// A minimal edit screen exercising [UnsavedChangesMixin]: a single text field
/// that arms the guard on change, wrapped in [UnsavedChangesMixin.buildUnsavedChangesGuard]
/// so a pop is intercepted while dirty (#345).
class _GuardedForm extends ConsumerStatefulWidget {
  const _GuardedForm();

  @override
  ConsumerState<_GuardedForm> createState() => _GuardedFormState();
}

class _GuardedFormState extends ConsumerState<_GuardedForm>
    with UnsavedChangesMixin {
  @override
  Widget build(BuildContext context) {
    return buildUnsavedChangesGuard(
      child: Scaffold(
        body: Form(
          onChanged: markUnsavedChanges,
          child: TextFormField(key: const Key('field')),
        ),
      ),
    );
  }
}

Widget _host({Locale? locale}) {
  return ProviderScope(
    child: MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              key: const Key('go'),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const _GuardedForm()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('DiscardChangesDialog (#345, D-18)', () {
    testWidgets('renders localized EN strings with 44x44 tap targets', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: DiscardChangesDialog()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('discard-changes-dialog')), findsOneWidget);
      expect(find.text('Discard changes?'), findsOneWidget);
      expect(
        find.text(
          'You have unsaved changes. If you leave now, they will be lost.',
        ),
        findsOneWidget,
      );
      expect(find.text('Keep editing'), findsOneWidget);
      expect(find.text('Discard'), findsOneWidget);

      expectMinTapTarget(
        tester,
        find.byKey(const Key('discard-changes-cancel')),
      );
      expectMinTapTarget(
        tester,
        find.byKey(const Key('discard-changes-confirm')),
      );
    });

    testWidgets('renders localized PT strings', (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            locale: Locale('pt'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(body: DiscardChangesDialog()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Descartar alterações?'), findsOneWidget);
      expect(find.text('Descartar'), findsOneWidget);
      expect(find.text('Continuar a editar'), findsOneWidget);
    });
  });

  group('UnsavedChangesMixin back-guard (#345)', () {
    testWidgets('a pristine form pops freely with no prompt', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('field')), findsOneWidget);

      // Pop via the framework (equivalent to the OS back gesture / maybePop).
      final popped = await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(popped, isTrue);
      expect(find.byKey(const Key('discard-changes-dialog')), findsNothing);
      expect(find.byKey(const Key('field')), findsNothing);
    });

    testWidgets('a dirty form prompts on back and stays when kept', (
      tester,
    ) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('field')), 'edited');
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('discard-changes-dialog')), findsOneWidget);

      await tester.tap(find.byKey(const Key('discard-changes-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('field')), findsOneWidget);
    });

    testWidgets('a dirty form pops when discard is confirmed', (tester) async {
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('field')), 'edited');
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discard-changes-confirm')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('field')), findsNothing);
    });

    testWidgets('leaving the form resets the shared provider flag', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    key: const Key('go'),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const _GuardedForm(),
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('go')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('field')), 'edited');
      await tester.pump();
      expect(container.read(unsavedChangesProvider), isTrue);

      // Discard and leave — the flag resets so later navigation isn't blocked.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discard-changes-confirm')));
      await tester.pumpAndSettle();
      expect(container.read(unsavedChangesProvider), isFalse);
    });
  });
}
