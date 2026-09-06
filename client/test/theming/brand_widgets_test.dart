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

  // #771 (FR-AX-1, D-18): heading semantics are how a screen-reader user skims
  // a screen — jumping header to header instead of reading every node in
  // order. [SectionHeader] is the app's ONE section-header mechanism, so this
  // single node carries every heading in the app.
  // #797 (FR-AX-1, D-18): a plain `Center > Padding > Column` overflowed by
  // 181px at the 200% text scale the app commits to, inside any bounded
  // parent. A RenderFlex overflow is a hard error under test, so this also
  // made the shell untestable at 200% — its IndexedStack builds every tab and
  // any empty one threw during layout.
  testWidgets('EmptyState does not overflow a bounded parent at 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 500);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      _host(
        const Column(
          children: [
            Expanded(
              child: EmptyState(
                message:
                    'No activities recorded yet for this apiary. Record one '
                    'to start building its history.',
                icon: Icons.inbox_outlined,
              ),
            ),
          ],
        ),
      ),
    );

    // A RenderFlex overflow surfaces as a thrown exception during layout.
    expect(tester.takeException(), isNull);
  });

  testWidgets('EmptyState still lays out under an unbounded parent', (
    tester,
  ) async {
    // The other half of the contract: it is also dropped straight into
    // unbounded Columns, where a bare SingleChildScrollView would throw.
    await tester.pumpWidget(
      _host(
        const SingleChildScrollView(
          child: Column(children: [EmptyState(message: 'Nothing here yet')]),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Nothing here yet'), findsOneWidget);
  });

  testWidgets('SectionHeader announces its label as a heading', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(const SectionHeader('Organization', key: Key('header'))),
    );

    // The REAL node, not a `contains` matcher (#662's discipline): the flag
    // and the label must sit on the SAME node, or a screen reader announces
    // an empty heading followed by a stray line of text.
    final data = tester
        .getSemantics(find.byKey(const Key('header')))
        .getSemanticsData();
    expect(data.flagsCollection.isHeader, isTrue);
    expect(data.label, 'Organization');
    handle.dispose();
  });

  // The other half of #771's third acceptance criterion: only things that ARE
  // headings become headings. [LabeledField]'s bold 13px label sits above a
  // field and reads like one, but it names an input — marking it a heading
  // would put every form field into the screen reader's heading list.
  testWidgets('LabeledField\'s label is not a heading', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        const LabeledField(
          label: 'Name',
          child: TextField(key: Key('lf-child')),
        ),
      ),
    );

    // Since #629 the label is the CHILD's accessible name and the visible
    // `Text` is excluded from semantics, so the assertion has to look at the
    // control's node — checking the `Text` would now pass vacuously against
    // an empty label rather than proving the field is not a heading.
    final data = tester
        .getSemantics(find.byKey(const Key('lf-child')))
        .getSemanticsData();
    expect(data.label, 'Name');
    expect(data.flagsCollection.isHeader, isFalse);
    handle.dispose();
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

  testWidgets(
    'LabeledField lends its label to the field it wraps as that field\'s '
    'ACCESSIBLE name (#629, FR-AX-1) — moving the label out of the box '
    'border must not cost the input the name InputDecoration.labelText '
    'used to put on its own semantics node',
    (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(
          const LabeledField(
            label: 'Name',
            child: TextField(key: Key('lf-child')),
          ),
        ),
      );

      final semantics = tester.getSemantics(find.byKey(const Key('lf-child')));
      expect(
        semantics.label,
        'Name',
        reason:
            'a bare Text sibling is invisible to a screen reader focused on '
            'the input: the label has to land on the field node itself, the '
            'way labelText did',
      );
      expect(
        semantics.flagsCollection.isTextField,
        isTrue,
        reason:
            'the label must merge INTO the field node, not wrap it in an '
            'extra container node that the input would not inherit',
      );
      expect(
        find.bySemanticsLabel('Name'),
        findsOneWidget,
        reason:
            'exactly one announced "Name" — the visible Text is excluded '
            'from semantics once the field carries the name, or a screen '
            'reader reads the label twice',
      );
      handle.dispose();
    },
  );

  testWidgets('LabeledField(labelsChild: false) leaves the wrapped subtree\'s '
      'semantics untouched — the opt-out for groups whose controls each own '
      'their name already (pickers, a read-only value, a field sharing its '
      'row with a button) (#629)', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        const LabeledField(
          label: 'Apiaries',
          labelsChild: false,
          child: TextField(key: Key('lf-child')),
        ),
      ),
    );

    expect(
      tester.getSemantics(find.byKey(const Key('lf-child'))).label,
      isEmpty,
    );
    expect(find.text('Apiaries'), findsOneWidget);
    handle.dispose();
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

  // #662 (FR-AX-1): a row card speaks as ONE node. The three tests below pin
  // the contract `BrandCard`'s own doc comment states, at the level where it
  // lives — the screen-level sweep in `test/a11y_field_ux_test.dart` proves it
  // holds on every list screen, these prove the widget itself is why.
  testWidgets('BrandRowCard announces title, subtitle and trailing label '
      'exactly once', (tester) async {
    await tester.pumpWidget(
      _host(
        BrandRowCard(
          key: const Key('row'),
          title: 'Barragem Norte',
          subtitle: '30 hives · 5.4 km away',
          trailing: const Text('40d'),
          trailingSemanticLabel: '40 days since the last visit',
          leading: const LeadingIconTile(
            icon: Icons.hive,
            color: Colors.brown,
            tint: Color(0xFFF4EDDB),
          ),
          onTap: () {},
        ),
      ),
    );

    // The WHOLE label, not a `contains`: the visible "40d" and the title/
    // subtitle `Text`s must not merge in on top of it.
    expect(
      tester.getSemantics(find.byKey(const Key('row'))).label,
      'Barragem Norte. 30 hives · 5.4 km away. 40 days since the last visit',
    );
  });

  testWidgets('BrandRowCard stays activatable through the semantics tree', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var tapped = false;
    await tester.pumpWidget(
      _host(
        BrandRowCard(
          key: const Key('row'),
          title: 'Barragem Norte',
          onTap: () => tapped = true,
        ),
      ),
    );

    // Not `tester.tap` — that is a pointer event and would pass even if the
    // semantics tree had lost the action. This is the screen-reader gesture,
    // driven through the semantics tree itself, and it throws if the node
    // does not actually carry `SemanticsAction.tap`.
    tester.semantics.tap(find.semantics.byLabel('Barragem Norte'));
    expect(tapped, isTrue);
    handle.dispose();
  });

  testWidgets('BrandCard without a semanticLabel keeps its children\'s '
      'semantics', (tester) async {
    await tester.pumpWidget(
      _host(
        const BrandCard(
          key: Key('panel'),
          child: Column(children: [Text('Attributes'), Text('Honey: 12 kg')]),
        ),
      ),
    );

    // Detail-screen panels and menu cards rely on this: the exclusion is tied
    // to composing a label, so a card that composes none must still announce
    // what it contains.
    expect(find.bySemanticsLabel('Attributes'), findsOneWidget);
    expect(find.bySemanticsLabel('Honey: 12 kg'), findsOneWidget);
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
