import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/features/activities/activity_types.dart';
import 'package:beekeepingit_client/features/journeys/journey_default_attributes_section.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The controlled vocabularies render in the ACTIVE language while the value
/// the section builds stays the stored/wire string (#625, NFR-I18N-1,
/// FR-AC-1, D-19).
void main() {
  Widget host({
    required String type,
    required JourneyDefaultAttributesController controller,
    required Locale locale,
  }) => MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: kSupportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: JourneyDefaultAttributesSection(
          type: type,
          controller: controller,
          onChanged: () {},
        ),
      ),
    ),
  );

  testWidgets('English renders English treatment-product options (#625)', (
    tester,
  ) async {
    final controller = JourneyDefaultAttributesController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        type: activityTypeTreatment,
        controller: controller,
        locale: const Locale('en'),
      ),
    );

    await tester.tap(
      find.byKey(const Key('journey-default-treatment-type-field')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Oxalic acid').last, findsOneWidget);
    expect(find.text('Thymol').last, findsOneWidget);
    expect(find.text('Ácido oxálico'), findsNothing);
    expect(find.text('Timol'), findsNothing);
  });

  testWidgets('Portuguese still renders the Portuguese options (#625)', (
    tester,
  ) async {
    final controller = JourneyDefaultAttributesController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      host(
        type: activityTypeTreatment,
        controller: controller,
        locale: const Locale('pt'),
      ),
    );

    await tester.tap(
      find.byKey(const Key('journey-default-treatment-type-field')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Ácido oxálico').last, findsOneWidget);
    expect(find.text('Timol').last, findsOneWidget);
    expect(find.text('Oxalic acid'), findsNothing);
  });

  testWidgets(
    'picking an English label stores the Portuguese wire value (#625)',
    (tester) async {
      final controller = JourneyDefaultAttributesController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        host(
          type: activityTypeFeeding,
          controller: controller,
          locale: const Locale('en'),
        ),
      );

      await tester.tap(
        find.byKey(const Key('journey-default-feed-type-field')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('1:1 syrup').last);
      await tester.pumpAndSettle();

      expect(controller.feedType, 'Xarope 1:1');
      expect(controller.build(activityTypeFeeding), {
        'feed_type': 'Xarope 1:1',
      });
    },
  );
}
