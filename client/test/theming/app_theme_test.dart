import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:beekeepingit_client/theming/brand_tokens.dart';
import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The font family every `Text` reading [text] *actually renders with* — the
/// effective style after `DefaultTextStyle` inheritance and any widget-level
/// merge, not the style someone declared. `Text` builds a [RichText] whose
/// span style is exactly that resolved result, so reading it back is the only
/// honest way to assert what a user sees.
///
/// Returns one entry per occurrence: an open dropdown draws its selected value
/// twice (the closed button's `IndexedStack` and the overlay menu), and both
/// have to be right.
Iterable<String?> _renderedFamilies(WidgetTester tester, String text) => tester
    .widgetList<RichText>(
      find.descendant(of: find.text(text), matching: find.byType(RichText)),
    )
    .map((rich) => rich.text.style?.fontFamily);

/// Brand-wiring assertions for `AppTheme` (FR-UX-1, FR-AX-1, D-18, EPIC-11
/// #243): the theme is built from the Melargil tokens, honey is the single
/// primary *action's* fill (never the surface-legible `primary` accent role,
/// #627), and the bundled fonts are wired the way the prototype asks
/// ("Archivo for all UI/body, Playfair Display for display/screen titles").
/// Contrast is covered separately in `app_theme_contrast_test.dart`.
void main() {
  group('brand color wiring', () {
    test('light primary is plum, not honey — honey is a fill, and `primary` '
        'is drawn on the light surface (#627)', () {
      final scheme = AppTheme.light().colorScheme;
      // Material draws `primary` as a foreground (outlined/text-button
      // labels, accent icons) on the surface, and honey-on-cream is 1.84:1.
      // Plum is the brand hue that reads there; the honey fill is pinned on
      // the one primary action instead (see below).
      expect(scheme.primary, BrandTokens.plum700);
      expect(scheme.onPrimary, BrandTokens.paper);
      expect(scheme.primary, isNot(BrandTokens.honey));
    });

    test(
      'dark primary is honey — on plum it reads as a foreground (8.02:1)',
      () {
        expect(AppTheme.dark().colorScheme.primary, BrandTokens.honey);
        // White-on-honey fails AA, so on-primary is the dark ink the FAB uses.
        expect(AppTheme.dark().colorScheme.onPrimary, BrandTokens.onHoney);
      },
    );

    test('the honey fill is pinned on the FAB in both brightnesses ("honey is '
        'the only primary action")', () {
      // The two places the single primary action lives are the FAB theme and
      // PrimaryActionButton (covered in
      // test/core/widgets/field_action_button_test.dart). Neither may drift
      // to a second honey-ish hex, and neither may follow `primary` now that
      // the light scheme's accent is plum (#243, #627).
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        expect(
          theme.floatingActionButtonTheme.backgroundColor,
          BrandTokens.honey,
        );
        expect(
          theme.floatingActionButtonTheme.foregroundColor,
          BrandTokens.onHoney,
        );
      }
    });

    test('light surface ground is cream and body text is ink', () {
      final scheme = AppTheme.light().colorScheme;
      expect(scheme.surface, BrandTokens.cream);
      expect(scheme.onSurface, BrandTokens.ink);
    });

    test('the two theme schemes differ by brightness', () {
      expect(AppTheme.light().colorScheme.brightness, Brightness.light);
      expect(AppTheme.dark().colorScheme.brightness, Brightness.dark);
      // Dark ground is plum, not cream.
      expect(AppTheme.dark().colorScheme.surface, BrandTokens.plum950);
    });
  });

  group('bundled typography wiring', () {
    for (final entry in {
      'light': AppTheme.light(),
      'dark': AppTheme.dark(),
    }.entries) {
      final name = entry.key;
      final theme = entry.value;

      test('$name: app-wide default font family is Archivo', () {
        // fontFamily on ThemeData is the app-wide default for any text style
        // that doesn't opt into another family — i.e. all UI/body text.
        expect(theme.textTheme.bodyMedium?.fontFamily, AppTheme.bodyFontFamily);
        expect(theme.textTheme.labelLarge?.fontFamily, AppTheme.bodyFontFamily);
        expect(AppTheme.bodyFontFamily, 'Archivo');
      });

      test('$name: display/headline/title styles use Playfair Display', () {
        expect(AppTheme.displayFontFamily, 'Playfair Display');
        for (final style in <TextStyle?>[
          theme.textTheme.displayLarge,
          theme.textTheme.headlineMedium,
          theme.textTheme.titleLarge,
        ]) {
          expect(style?.fontFamily, AppTheme.displayFontFamily);
        }
        // Body/label stay on Archivo (Playfair is titles-only).
        expect(theme.textTheme.bodyLarge?.fontFamily, AppTheme.bodyFontFamily);
        expect(
          theme.textTheme.labelMedium?.fontFamily,
          AppTheme.bodyFontFamily,
        );
      });

      test('$name: titleMedium is Archivo — it is Material\'s form-control '
          'tier, not a title tier (#628)', () {
        // `titleMedium` is what Material resolves for a form control, not
        // for a title: under this theme's M3 defaults it is `DropdownButton`'s
        // value and menu items that read it. (`PopupMenuButton`, `AlertDialog`
        // and `SnackBar` read it only under M2; on M3 they take
        // `labelLarge`/`bodyMedium`.) Putting the display serif here dressed
        // the dropdowns as headings — the serif word sitting inside a
        // sans-serif form that #628 reports. Screen titles
        // ride `titleLarge` and above (asserted just above); section headers
        // ride [SectionHeader], which pins Playfair itself.
        expect(
          theme.textTheme.titleMedium?.fontFamily,
          AppTheme.bodyFontFamily,
        );
      });
    }
  });

  group('dropdown values render in Archivo (#628, FR-UX-1)', () {
    // The prototype (docs/design/prototype.md §Typography) gives Archivo "all
    // UI, labels, inputs, buttons, body" and Playfair only "display / screen
    // titles / brand". A dropdown's selected value is an input value.
    //
    // These assert the *rendered* family rather than a theme field, because
    // Flutter offers no theme entry for `DropdownButtonFormField`:
    // `DropdownMenuThemeData` overrides the unrelated M3 `DropdownMenu`, and
    // `DropdownButton._textStyle` reads `theme.textTheme.titleMedium` with no
    // override hook. So what the widget actually paints is the only thing
    // worth asserting.
    Widget host(ThemeData theme) => MaterialApp(
      theme: theme,
      home: Scaffold(
        body: DropdownButtonFormField<String>(
          key: const Key('locale-field'),
          initialValue: 'en-GB',
          decoration: const InputDecoration(labelText: 'Language'),
          items: const [
            DropdownMenuItem(value: 'en-GB', child: Text('English')),
            DropdownMenuItem(value: 'pt-PT', child: Text('Portugues')),
          ],
          onChanged: (_) {},
        ),
      ),
    );

    for (final entry in {
      'light': AppTheme.light(),
      'dark': AppTheme.dark(),
    }.entries) {
      testWidgets('${entry.key}: the closed dropdown\'s selected value is '
          'Archivo, like every other form control', (tester) async {
        await tester.pumpWidget(host(entry.value));

        expect(
          _renderedFamilies(tester, 'English'),
          everyElement(AppTheme.bodyFontFamily),
        );
        // Sanity: the assertion above is meaningless if it matched nothing.
        expect(_renderedFamilies(tester, 'English'), isNotEmpty);
        // The field's own label was already Archivo and must stay that way.
        expect(
          _renderedFamilies(tester, 'Language'),
          everyElement(AppTheme.bodyFontFamily),
        );
        // Same guard: `everyElement` is vacuously true on an empty iterable,
        // so a renamed/removed label would pass while checking nothing.
        expect(_renderedFamilies(tester, 'Language'), isNotEmpty);
      });

      testWidgets('${entry.key}: the open menu\'s items are Archivo too', (
        tester,
      ) async {
        await tester.pumpWidget(host(entry.value));
        await tester.tap(find.byKey(const Key('locale-field')));
        await tester.pumpAndSettle();

        // Open, the selected value is drawn twice (button + overlay menu);
        // both, and the unselected item, must be Archivo.
        expect(_renderedFamilies(tester, 'English').length, greaterThan(1));
        for (final label in ['English', 'Portugues']) {
          expect(
            _renderedFamilies(tester, label),
            everyElement(AppTheme.bodyFontFamily),
          );
          // `everyElement` is vacuously true on an empty iterable — without
          // this, renaming a menu item would leave the loop green and blind.
          expect(_renderedFamilies(tester, label), isNotEmpty);
        }
      });
    }
  });

  group('Playfair stays on titles, brand and section headers (#628)', () {
    // The companion constraint to the group above: the fix must take the
    // serif *off* form controls without taking it off anything that is
    // legitimately a title. These are the three sanctioned homes.
    for (final entry in {
      'light': AppTheme.light(),
      'dark': AppTheme.dark(),
    }.entries) {
      final name = entry.key;
      final theme = entry.value;

      test('$name: screen titles keep the display serif', () {
        // The tiers screen titles and brand text ride. The shell header's own
        // title is covered by the app-bar test below.
        expect(
          theme.textTheme.titleLarge?.fontFamily,
          AppTheme.displayFontFamily,
        );
        expect(
          theme.textTheme.headlineSmall?.fontFamily,
          AppTheme.displayFontFamily,
        );
        expect(
          theme.textTheme.displaySmall?.fontFamily,
          AppTheme.displayFontFamily,
        );
      });

      testWidgets('$name: section headers keep the display serif', (
        tester,
      ) async {
        // [SectionHeader] is the app's one section-header mechanism (every
        // screen composes it). It pins Playfair itself rather than borrowing a
        // text-theme tier, which is why retiring the serif from `titleMedium`
        // cannot reach it.
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(body: SectionHeader('Organization')),
          ),
        );
        expect(
          _renderedFamilies(tester, 'Organization'),
          everyElement(AppTheme.displayFontFamily),
        );
        expect(_renderedFamilies(tester, 'Organization'), isNotEmpty);
      });

      test('$name: the app-bar title uses the Playfair title style', () {
        // The shell header (app_shell.dart) drops its inline fontFamily and
        // relies on this — so the screen title actually renders in Playfair.
        expect(
          theme.appBarTheme.titleTextStyle?.fontFamily,
          AppTheme.displayFontFamily,
        );
      });
    }
  });
}
