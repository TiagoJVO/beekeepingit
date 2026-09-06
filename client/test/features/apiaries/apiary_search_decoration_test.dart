import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/features/apiaries/apiary_search_decoration.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit coverage for the shared apiary search-field [InputDecoration]
/// (#762, D-17) — FOUR call sites (`todo_apiary_picker_field.dart`,
/// `apiary_multi_select_field.dart`, `new_activity_flow_screen.dart`'s
/// `_ApiaryStep`, and `apiaries_list_screen.dart`) built the same
/// `hintText`/`Icons.search`/`isDense: true` decoration inline;
/// `apiaries_list_screen.dart`'s own copy additionally shows a conditional
/// clear button, which [apiarySearchDecoration] supports via [suffixIcon]
/// without forcing the other three (which have no clear button) to grow one.
void main() {
  testWidgets('builds the shared hint/search-icon/isDense decoration', (
    tester,
  ) async {
    late AppLocalizations l10n;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: kSupportedLocales,
        home: Builder(
          builder: (context) {
            l10n = AppLocalizations.of(context);
            return Scaffold(
              body: TextField(decoration: apiarySearchDecoration(l10n)),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(l10n.apiariesSearchHint), findsOneWidget);
    expect(find.byIcon(Icons.search), findsOneWidget);
  });

  testWidgets('passes through an optional suffixIcon (the clear button)', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: kSupportedLocales,
        home: Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context);
            return Scaffold(
              body: TextField(
                decoration: apiarySearchDecoration(
                  l10n,
                  suffixIcon: const Icon(Icons.clear, key: Key('clear-icon')),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('clear-icon')), findsOneWidget);
  });

  testWidgets('omits the suffixIcon by default', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: kSupportedLocales,
        home: Builder(
          builder: (context) {
            final l10n = AppLocalizations.of(context);
            return Scaffold(
              body: TextField(decoration: apiarySearchDecoration(l10n)),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.clear), findsNothing);
  });
}
