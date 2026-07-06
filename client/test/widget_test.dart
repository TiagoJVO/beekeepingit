import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the app with auth + the local apiaries stream overridden, so no test
/// touches real OIDC or PowerSync.
Widget buildApp({required bool authed, List<Apiary>? apiaries}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(authed),
      if (apiaries != null)
        apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
    ],
    child: const BeekeepingitApp(),
  );
}

void main() {
  testWidgets('unauthenticated users land on the login screen', (tester) async {
    await tester.pumpWidget(buildApp(authed: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('login-button')), findsOneWidget);
    expect(find.text('Sign in with Keycloak'), findsOneWidget);
  });

  testWidgets('authenticated users see the apiaries list from local data', (
    tester,
  ) async {
    await tester.pumpWidget(
      buildApp(
        authed: true,
        apiaries: const [
          Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Apiaries'), findsOneWidget);
    expect(find.text('Serra Norte'), findsOneWidget);
    expect(find.text('3 hives'), findsOneWidget);
    expect(find.byKey(const Key('add-apiary-fab')), findsOneWidget);
  });

  testWidgets('empty local data shows the empty state', (tester) async {
    await tester.pumpWidget(buildApp(authed: true, apiaries: const []));
    await tester.pumpAndSettle();

    expect(find.textContaining('No apiaries yet'), findsOneWidget);
  });

  testWidgets('light and dark themes are both wired', (tester) async {
    await tester.pumpWidget(buildApp(authed: false));
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme, isNotNull);
    expect(app.darkTheme, isNotNull);
  });
}
