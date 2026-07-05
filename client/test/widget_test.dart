import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/network/gateway_status.dart';
import 'package:beekeepingit_client/features/home/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Overridden in every test so no test depends on real network access.
Widget buildApp({GatewayReachability status = GatewayReachability.reachable}) {
  return ProviderScope(
    overrides: [
      gatewayReachabilityProvider.overrideWith((ref) async => status),
    ],
    child: const BeekeepingitApp(),
  );
}

void main() {
  testWidgets('home screen renders title, subtitle and gateway status', (
    tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('Apiaries'), findsOneWidget);
    expect(find.textContaining('Gateway'), findsOneWidget);
    expect(find.textContaining('Reachable'), findsOneWidget);
  });

  testWidgets('shows the unreachable gateway status when the check fails', (
    tester,
  ) async {
    await tester.pumpWidget(buildApp(status: GatewayReachability.unreachable));
    await tester.pumpAndSettle();

    expect(find.textContaining('Unreachable'), findsOneWidget);
  });

  testWidgets('navigates from home to the apiary detail placeholder route', (
    tester,
  ) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('View sample apiary'));
    await tester.pumpAndSettle();

    expect(find.text('Apiary detail'), findsOneWidget);
    expect(find.textContaining(sampleApiaryId), findsOneWidget);
  });

  testWidgets('light and dark themes are both wired', (tester) async {
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.theme, isNotNull);
    expect(app.darkTheme, isNotNull);
  });
}
