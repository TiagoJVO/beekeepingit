import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:beekeepingit_client/theming/brand_dimens.dart';
import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/image_asset.dart';

/// Widget-level guards for the shared design-system building blocks
/// (lib/theming/brand_widgets.dart), mirroring the repo convention of testing
/// shared widgets (see core/widgets/field_action_button_test.dart). Some of
/// these (Eyebrow, LabeledField, BrandChip, MenuListCard/MenuRow) are library
/// API meant for screens still to come, so they're exercised here rather than
/// left as untested surface: they must build under the real [AppTheme] (which
/// registers the BrandTheme extension `context.brand` reads) and their
/// tappable variants must fire their callbacks.
Widget _host(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: Center(child: child)),
);

/// [_host] plus the real localization delegates, for the widgets that read
/// their own strings from [AppLocalizations] (BrandMark's semantic label).
Widget _localizedHost(Widget child, {Locale? locale}) => MaterialApp(
  theme: AppTheme.light(),
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: kSupportedLocales,
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('Eyebrow renders its text uppercased', (tester) async {
    await tester.pumpWidget(_host(const Eyebrow('ordered by proximity')));
    expect(find.text('ORDERED BY PROXIMITY'), findsOneWidget);
  });

  testWidgets('SectionHeader renders its text', (tester) async {
    await tester.pumpWidget(_host(const SectionHeader('Organization')));
    expect(find.text('Organization'), findsOneWidget);
  });

  testWidgets('LabeledField shows the label above its child', (tester) async {
    await tester.pumpWidget(
      _host(
        const LabeledField(
          label: 'Name',
          child: TextField(key: Key('lf-child')),
        ),
      ),
    );
    expect(find.text('Name'), findsOneWidget);
    expect(find.byKey(const Key('lf-child')), findsOneWidget);
  });

  testWidgets('HeroCard and NotesCard render their content', (tester) async {
    await tester.pumpWidget(
      _host(
        const Column(
          children: [
            HeroCard(child: Text('Herdade da Ribeira')),
            NotesCard(text: 'Rosemary and eucalyptus.'),
          ],
        ),
      ),
    );
    expect(find.text('Herdade da Ribeira'), findsOneWidget);
    expect(find.text('Rosemary and eucalyptus.'), findsOneWidget);
  });

  testWidgets('BrandCard fires onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(BrandCard(onTap: () => tapped = true, child: const Text('tap me'))),
    );
    await tester.tap(find.text('tap me'));
    expect(tapped, isTrue);
  });

  testWidgets('BrandRowCard shows title/subtitle, a chevron, and taps', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        BrandRowCard(
          title: 'Barragem Norte',
          subtitle: '30 hives · 5.4 km away',
          leading: const LeadingIconTile(
            icon: Icons.hive,
            color: Colors.brown,
            tint: Color(0xFFF4EDDB),
          ),
          onTap: () => tapped = true,
        ),
      ),
    );
    expect(find.text('Barragem Norte'), findsOneWidget);
    expect(find.text('30 hives · 5.4 km away'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    await tester.tap(find.text('Barragem Norte'));
    expect(tapped, isTrue);
  });

  testWidgets('EmptyState renders its message and optional icon', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const EmptyState(message: 'No results.', icon: Icons.search_off)),
    );
    expect(find.text('No results.'), findsOneWidget);
    expect(find.byIcon(Icons.search_off), findsOneWidget);
  });

  testWidgets('BrandChip renders its label and fires onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      _host(
        BrandChip(label: 'Harvest', selected: true, onTap: () => tapped = true),
      ),
    );
    expect(find.text('Harvest'), findsOneWidget);
    await tester.tap(find.text('Harvest'));
    expect(tapped, isTrue);
  });

  testWidgets('MenuListCard renders each MenuRow and taps route through', (
    tester,
  ) async {
    var tappedOrg = false;
    await tester.pumpWidget(
      _host(
        MenuListCard(
          rows: [
            MenuRow(
              label: 'Members & invitations',
              icon: Icons.group,
              onTap: () => tappedOrg = true,
            ),
            const MenuRow(label: 'Change password', icon: Icons.lock),
          ],
        ),
      ),
    );
    expect(find.text('Members & invitations'), findsOneWidget);
    expect(find.text('Change password'), findsOneWidget);
    await tester.tap(find.text('Members & invitations'));
    expect(tappedOrg, isTrue);
  });

  group('BrandMark (#686)', () {
    testWidgets('renders the bundled bee artwork — the same file the app icon '
        'ships — rather than a Material glyph', (tester) async {
      await tester.pumpWidget(_localizedHost(const BrandMark()));
      await tester.pumpAndSettle();

      final image = tester.widget<Image>(find.byType(Image));
      expect(assetNameOf(image), kBrandMarkAsset);
      // The honeycomb glyph it replaces must not come back alongside it.
      expect(find.byIcon(Icons.hive_rounded), findsNothing);
    });

    testWidgets('carries a localized semantic label (FR-AX-1, NFR-I18N-1)', (
      tester,
    ) async {
      await tester.pumpWidget(_localizedHost(const BrandMark()));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('BeekeepingIT logo'), findsOneWidget);

      await tester.pumpWidget(
        _localizedHost(const BrandMark(), locale: const Locale('pt', 'PT')),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Logótipo BeekeepingIT'), findsOneWidget);
    });

    testWidgets('honours the requested size and keeps the icon squircle at it '
        '— a fixed radius would clamp to a circle below 56px', (tester) async {
      await tester.pumpWidget(_localizedHost(const BrandMark(size: 48)));
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(BrandMark)), const Size(48, 48));
      final clip = tester.widget<ClipRRect>(find.byType(ClipRRect));
      // 28/96 of 48 = 14 — still a squircle. Half of 48 (24) would be a
      // circle, which is the one shape the app icon is not.
      expect(
        clip.borderRadius,
        BorderRadius.circular(
          48 * (BrandDimens.radiusBrandMark / BrandDimens.sizeBrandMark),
        ),
      );
      expect(
        (clip.borderRadius as BorderRadius).topLeft.x,
        lessThan(24),
        reason: 'a radius of half the box would render a circle',
      );
    });
  });
}
