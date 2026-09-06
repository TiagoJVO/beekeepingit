import 'dart:io';

import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/core/widgets/tap_target.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/activities/activity_filters.dart';
import 'package:beekeepingit_client/features/activities/activity_list_widgets.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/theming/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Layout regression tests for the activity list row (#632, FR-AC-5, FR-AC-6,
/// FR-UX-1, D-18).
///
/// The defect: the row concatenated EVERY type attribute into one
/// middot-separated subtitle and reserved a wide fixed-width actor chip on the
/// right, squeezing the text into roughly a 145px column at a 375px viewport.
/// One honey harvest then rendered as nine wrapped lines (~230px tall), and
/// long values broke mid-token — two activities no longer fit on a phone
/// screen, on the screen a beekeeper opens to answer "what has been done
/// here".
///
/// The row is excellent at 1280px (one line per activity), so the fix is a
/// responsive rule, not a redesign: below the compact-row breakpoint the
/// row renders type · date + headline metric · actor — three single lines —
/// and above it the wide layout is preserved verbatim.
///
/// Mirrors todo_filter_bar_test.dart's conventions: real fonts loaded (text
/// metrics are the whole subject here) and the widget wrapped directly rather
/// than booting the whole app.
///
/// The last group covers the same compact row under an increased system text
/// size (#759, FR-AX-1, D-18, WCAG 2.2 AA SC 1.4.4) — the case every other
/// case here leaves at the platform default, and the one where a deliberately
/// tight `maxLines: 1` layout is most likely to clip.

/// The narrowest phone width the PWA targets, and the width #632 reproduces
/// at.
const _narrowViewport = Size(375, 812);

/// The desktop width the audit found the row already excellent at.
const _wideViewport = Size(1280, 800);

/// The vertical budget for a three-line row at [_narrowViewport]: three text
/// lines at the row's own type scale plus [ListTile]'s padding. The defect
/// rendered ~230px (and ~550px inside the apiary detail card).
const _threeLineHeightBudget = 100.0;

/// The vertical budget for the preserved WIDE row: title + a single subtitle
/// line, with the actor beside them rather than beneath.
const _wideHeightBudget = 96.0;

/// A realistic increased system text size (#759): the middle of the ~1.3x–2x
/// band `docs/design/accessibility-field-ux-checklist.md` asks every widget to
/// survive, and roughly where Android's "Large" font-size step and the larger
/// iOS Dynamic Type steps land. This is the setting a beekeeper reading a
/// phone at arm's length in the sun actually picks.
const _increasedTextScale = TextScaler.linear(1.5);

/// The outer end of that band — WCAG 2.2 AA's 200% resize obligation (SC
/// 1.4.4, D-18). Covered as well as 1.5x because the compact row's whole
/// design is `maxLines: 1`, so the failure mode at 2x is more truncation, not
/// unbounded growth: if it holds at 1.5x there is no reason to stop there.
const _maxTextScale = TextScaler.linear(2.0);

/// The rows-per-phone-screen floor at each scale, measured rather than
/// assumed (#759 AC 2).
///
/// Deliberately NOT the default scale's eight: a row whose three text lines
/// are taller is a taller row, and fewer of them fit. Restating the number
/// honestly per scale is the point — carrying eight forward unchanged would
/// have been either a false claim or a vacuous assertion.
///
/// The measured heights at 375x812 are 88px at the default scale (nine rows),
/// 108px at 1.5x and 138px at 2x. 88 is [ListTile]'s own three-line minimum,
/// so the default row has slack: text grows 50% while the row grows 23%,
/// which is why the count degrades gently rather than halving. These floors
/// exist so a change that inflates the scaled row — extra padding, a fourth
/// line, an uncapped `Text` — fails here instead of quietly shortening the
/// list for exactly the users who most need it.
///
/// Headroom, so a future font or engine-metrics bump is read correctly rather
/// than shrugged at: 1.5x has the thinner margin (108px against the 116px at
/// which seven rows would become six, ~8%); 2x has ~18%. If the 1.5x floor
/// ever trips, the row got taller — check that before relaxing the number.
const _scaledRowsPerScreen = <(TextScaler, int)>[
  (_increasedTextScale, 7),
  (_maxTextScale, 5),
];

/// Loads the app's real text fonts into the test binding.
///
/// Mandatory for this suite specifically (same reason todo_filter_bar_test
/// .dart loads them): the default test font draws every glyph as a full em
/// square, so measured text comes out roughly twice as wide as what a user
/// sees, and a line-count assertion made against it would be about a layout
/// nobody ships. Read from disk rather than `rootBundle` so the test does not
/// depend on the tool's asset bundle.
Future<void> _loadAppFonts() async {
  Future<void> load(String family, String path) async {
    final bytes = await File(path).readAsBytes();
    await (FontLoader(family)..addFont(
          Future.value(ByteData.sublistView(Uint8List.fromList(bytes))),
        ))
        .load();
  }

  await load(AppTheme.bodyFontFamily, 'fonts/Archivo/Archivo-Regular.ttf');
  await load(
    AppTheme.displayFontFamily,
    'fonts/PlayfairDisplay/PlayfairDisplay-SemiBold.ttf',
  );
}

class _StubProfileController extends ProfileController {
  @override
  Future<Profile> build() async => Profile(
    id: 'test-user',
    name: 'Test User',
    email: 'test@example.com',
    locale: 'en-GB',
    profileComplete: true,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

Activity _activity({
  String id = 'a1',
  String type = 'harvest',
  Map<String, dynamic> attributes = const {
    'honey_supers': 4,
    'honey_kg': 12.5,
    'hives_involved': 9,
    'lot_batch': '2026-07-A1',
    'notes': 'A long field note that has no business in a list row at all.',
  },
  String? performedBy = 'test-user',
}) => Activity(
  id: id,
  apiaryId: 'ap1',
  type: type,
  occurredAt: '2026-06-01',
  attributes: attributes,
  performedBy: performedBy,
);

void _useViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _buildList({
  required Locale locale,
  required List<Activity> activities,
  String? Function(String apiaryId)? apiaryNameOf,
  double? rowWidth,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  final list = ActivityListView(
    viewModel: AsyncValue.data(
      ActivitiesViewModel(hasAnyActivities: true, filtered: activities),
    ),
    emptyText: 'empty',
    showApiary: apiaryNameOf != null,
    apiaryNameOf: apiaryNameOf,
  );
  return ProviderScope(
    overrides: [
      profileProvider.overrideWith(_StubProfileController.new),
      memberNamesProvider.overrideWith((ref) async => const {}),
    ],
    child: MaterialApp(
      locale: locale,
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      // The system text-size setting, injected the same way a11y_field_ux_test
      // .dart does it: above `home` so every descendant inherits it, and via
      // `copyWith` so the view's real size/padding are preserved (#759).
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: rowWidth == null
            ? list
            : Center(
                child: SizedBox(width: rowWidth, child: list),
              ),
      ),
    ),
  );
}

Finder _row(String id) => find.byKey(Key('activity-$id'));

/// Every TEXT paragraph rendered inside the row keyed [id] — icons also
/// render as paragraphs (a glyph in the `MaterialIcons` family) and are not
/// subject to the line-count rule, so they are filtered out.
List<RenderParagraph> _paragraphs(WidgetTester tester, String id) => tester
    .renderObjectList<RenderParagraph>(
      find.descendant(of: _row(id), matching: find.byType(RichText)),
    )
    .where((p) => p.text.style?.fontFamily != 'MaterialIcons')
    .toList();

/// Fails when any text in the row wraps onto a second line — the concrete
/// form of "long values wrap or truncate at a sensible boundary, never
/// mid-token": a capped, ellipsized single line, not a mid-word break.
void _expectEveryLineSingleAndEllipsized(WidgetTester tester, String id) {
  for (final paragraph in _paragraphs(tester, id)) {
    expect(
      paragraph.size.height,
      lessThan(paragraph.preferredLineHeight * 1.5),
      reason:
          '"${paragraph.text.toPlainText()}" wrapped onto a second line in '
          'the compact row',
    );
    expect(
      paragraph.maxLines,
      1,
      reason:
          '"${paragraph.text.toPlainText()}" must be capped at one line in '
          'the compact row',
    );
    expect(
      paragraph.overflow,
      TextOverflow.ellipsis,
      reason:
          '"${paragraph.text.toPlainText()}" must ellipsize rather than '
          'break mid-token',
    );
  }
}

/// Fails when laying the row out at this text scale reported anything.
///
/// A `RenderFlex overflowed` is not thrown: it goes through
/// [FlutterError.reportError], which the binding records and re-raises at the
/// end of the test. Taking it explicitly makes "the row does not overflow"
/// the stated subject of the assertion (#759 AC 1) rather than an incidental
/// crash in the run log. It takes ANY recorded exception, not only an
/// overflow — an overflow is merely the shape a failure is expected to take
/// here, and a different one is no less a failure.
void _expectNoOverflow(WidgetTester tester) {
  expect(
    tester.takeException(),
    isNull,
    reason:
        'the compact row must lay out at this text scale with nothing '
        'reported — a RenderFlex overflow is the expected shape of a '
        'failure here',
  );
}

/// Fails when any of the row's rendered text sits outside the row's own box.
///
/// The complement to [_expectNoOverflow]: a [ListTile] that stops growing
/// with its content clips rather than reporting an overflow, so a
/// scale-induced regression can be silent. All four edges are checked (the
/// vertical ones are where scaled text actually escapes; the horizontal pair
/// is cheap and keeps the check exhaustive rather than assuming an LTR
/// layout). Compared with a half-pixel tolerance because layout arithmetic is
/// not exact.
void _expectTextWithinRow(WidgetTester tester, String id) {
  final rowRect = tester.getRect(_row(id));
  final texts = find.descendant(of: _row(id), matching: find.byType(RichText));
  for (var i = 0; i < texts.evaluate().length; i++) {
    final rect = tester.getRect(texts.at(i));
    expect(
      rect.top,
      greaterThanOrEqualTo(rowRect.top - 0.5),
      reason: 'text is clipped off the top of the row',
    );
    expect(
      rect.bottom,
      lessThanOrEqualTo(rowRect.bottom + 0.5),
      reason: 'text is clipped off the bottom of the row',
    );
    expect(
      rect.left,
      greaterThanOrEqualTo(rowRect.left - 0.5),
      reason: 'text is clipped off the start of the row',
    );
    expect(
      rect.right,
      lessThanOrEqualTo(rowRect.right + 0.5),
      reason: 'text is clipped off the end of the row',
    );
  }
}

void main() {
  setUpAll(_loadAppFonts);

  group('activity row at 375px (#632, FR-AC-5/6, FR-UX-1)', () {
    testWidgets('a fully-populated harvest occupies at most three lines', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildList(locale: const Locale('en', 'GB'), activities: [_activity()]),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(_row('a1')).height,
        lessThan(_threeLineHeightBudget),
        reason:
            'the row must fit three lines; the defect rendered nine (~230px)',
      );
      _expectEveryLineSingleAndEllipsized(tester, 'a1');
    });

    testWidgets('the compact row renders exactly three text lines — title, '
        'date + headline, attribution — not attribution folded into the '
        'subtitle string (#758)', (tester) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildList(locale: const Locale('en', 'GB'), activities: [_activity()]),
      );
      await tester.pumpAndSettle();

      expect(_paragraphs(tester, 'a1'), hasLength(3));
    });

    testWidgets(
      'the subtitle is the date plus the headline metric only — the rest '
      'moves to the activity detail screen',
      (tester) async {
        _useViewport(tester, _narrowViewport);
        await tester.pumpWidget(
          _buildList(
            locale: const Locale('en', 'GB'),
            activities: [_activity()],
          ),
        );
        await tester.pumpAndSettle();

        // FR-AC-1 names the supers count the primary yield metric — the
        // headline for a harvest.
        expect(
          find.descendant(
            of: _row('a1'),
            matching: find.text('1 Jun 2026 · Supers: 4'),
          ),
          findsOneWidget,
        );
        // Everything else is detail-screen material now.
        expect(find.textContaining('Honey harvested (kg)'), findsNothing);
        expect(find.textContaining('Hives involved'), findsNothing);
        expect(find.textContaining('Lot / batch'), findsNothing);
        expect(find.textContaining('A long field note'), findsNothing);
      },
    );

    testWidgets('the actor no longer consumes a third of the row width', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildList(locale: const Locale('en', 'GB'), activities: [_activity()]),
      );
      await tester.pumpAndSettle();

      final rowWidth = tester.getSize(_row('a1')).width;
      final subtitle = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: _row('a1'),
          matching: find.text('1 Jun 2026 · Supers: 4'),
        ),
      );
      expect(
        subtitle.constraints.maxWidth,
        greaterThan(rowWidth * 0.6),
        reason:
            'the defect left the text roughly 145px of a 375px row (39%) '
            'because the actor chip reserved the right-hand side',
      );
      // The actor is still shown per row (FR-TEN-2) — beneath the subtitle,
      // not beside it.
      expect(
        find.descendant(of: _row('a1'), matching: find.text('You')),
        findsOneWidget,
      );
    });

    testWidgets('attribution keeps its screen-reader label (D-18)', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _buildList(locale: const Locale('en', 'GB'), activities: [_activity()]),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel(RegExp('Performed by: You')),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('the row still meets the 44px tap-target floor (D-18)', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildList(locale: const Locale('en', 'GB'), activities: [_activity()]),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(_row('a1')).height,
        greaterThanOrEqualTo(kMinTapTarget),
      );
    });

    testWidgets('at least eight activities fit on one phone screen', (
      tester,
    ) async {
      // The issue's actual complaint, as a number: "at this density two
      // activities no longer fit on a phone screen and ten are unusable".
      //
      // Default text scale only. Eight rows is a DENSITY target, and density
      // is exactly what a user trades away when they turn the system text
      // size up — the scaled equivalent is asserted separately, at the number
      // that scale actually yields (#759).
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildList(
          locale: const Locale('en', 'GB'),
          activities: [for (var i = 0; i < 10; i++) _activity(id: 'a$i')],
        ),
      );
      await tester.pumpAndSettle();

      // Only the rows the viewport (plus the list's cache extent) reaches are
      // built at all — measure the first, which every row matches.
      final rowHeight = tester.getSize(_row('a0')).height;
      expect(
        (_narrowViewport.height / rowHeight).floor(),
        greaterThanOrEqualTo(8),
        reason:
            'a ${rowHeight.toStringAsFixed(1)}px row only fits '
            '${(_narrowViewport.height / rowHeight).floor()} activities on a '
            '${_narrowViewport.height.toInt()}px screen',
      );
    });

    testWidgets(
      'the apiary-detail card case (a narrower embedded width) is compact too',
      (tester) async {
        _useViewport(tester, _narrowViewport);
        await tester.pumpWidget(
          _buildList(
            locale: const Locale('en', 'GB'),
            activities: [_activity()],
            // The embedded per-apiary section renders the same list inside a
            // padded card — narrower than the screen, where the defect was
            // worst (~550px per activity).
            rowWidth: 343,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          tester.getSize(_row('a1')).height,
          lessThan(_threeLineHeightBudget),
        );
        _expectEveryLineSingleAndEllipsized(tester, 'a1');
      },
    );

    testWidgets('an apiary-qualified title still fits on one line', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildList(
          locale: const Locale('en', 'GB'),
          activities: [_activity()],
          apiaryNameOf: (_) =>
              'An apiary with a deliberately very long name indeed',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.getSize(_row('a1')).height,
        lessThan(_threeLineHeightBudget),
      );
      _expectEveryLineSingleAndEllipsized(tester, 'a1');
    });

    testWidgets('Portuguese renders the same compact three-line row', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildList(locale: const Locale('pt', 'PT'), activities: [_activity()]),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: _row('a1'),
          matching: find.text('1 jun. 2026 · Alças: 4'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(_row('a1')).height,
        lessThan(_threeLineHeightBudget),
      );
      _expectEveryLineSingleAndEllipsized(tester, 'a1');
    });

    testWidgets('a feeding shows what was fed and how much', (tester) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildList(
          locale: const Locale('en', 'GB'),
          activities: [
            _activity(
              type: 'feeding',
              attributes: const {
                'feed_type': 'Xarope 1:1',
                'feed_amount': 2,
                'hives_involved': 9,
              },
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: _row('a1'),
          matching: find.text('1 Jun 2026 · 1:1 syrup · Amount: 2'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(_row('a1')).height,
        lessThan(_threeLineHeightBudget),
      );
    });

    testWidgets('a generic activity shows just the date, not filler text', (
      tester,
    ) async {
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildList(
          locale: const Locale('en', 'GB'),
          activities: [
            _activity(type: 'generic', attributes: const {'notes': 'x'}),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: _row('a1'), matching: find.text('1 Jun 2026')),
        findsOneWidget,
      );
      expect(find.text('No additional details'), findsNothing);
    });
  });

  group('the wide layout is preserved above the breakpoint (#632)', () {
    testWidgets('at 1280px the full summary stays on one line beside the '
        'actor chip', (tester) async {
      _useViewport(tester, _wideViewport);
      await tester.pumpWidget(
        _buildList(locale: const Locale('en', 'GB'), activities: [_activity()]),
      );
      await tester.pumpAndSettle();

      // Every attribute, exactly as before the fix.
      final subtitle = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: _row('a1'),
          matching: find.textContaining('Honey supers harvested: 4'),
        ),
      );
      final text = subtitle.text.toPlainText();
      expect(text, contains('Honey harvested (kg): 12.5'));
      expect(text, contains('Hives involved: 9'));
      expect(text, contains('Lot / batch identifier: 2026-07-A1'));
      expect(
        subtitle.size.height,
        lessThan(subtitle.preferredLineHeight * 1.5),
        reason: 'the wide row is one line per activity',
      );

      // The actor keeps its trailing chip at this width.
      expect(
        find.descendant(of: _row('a1'), matching: find.byType(Chip)),
        findsOneWidget,
      );
      expect(tester.getSize(_row('a1')).height, lessThan(_wideHeightBudget));
    });

    testWidgets('at 1280px Portuguese keeps the same wide layout', (
      tester,
    ) async {
      _useViewport(tester, _wideViewport);
      await tester.pumpWidget(
        _buildList(locale: const Locale('pt', 'PT'), activities: [_activity()]),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: _row('a1'),
          matching: find.textContaining('Alças de mel colhidas: 4'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: _row('a1'), matching: find.byType(Chip)),
        findsOneWidget,
      );
      expect(tester.getSize(_row('a1')).height, lessThan(_wideHeightBudget));
    });
  });

  group('the compact row at an increased system text scale (#759, FR-AX-1, '
      'D-18)', () {
    for (final (scale, _) in _scaledRowsPerScreen) {
      final label = '${scale.scale(1).toStringAsFixed(1)}x';

      testWidgets('at $label the row lays out without overflowing or '
          'clipping', (tester) async {
        _useViewport(tester, _narrowViewport);
        await tester.pumpWidget(
          _buildList(
            locale: const Locale('en', 'GB'),
            activities: [_activity()],
            textScaler: scale,
          ),
        );
        await tester.pumpAndSettle();

        _expectNoOverflow(tester);
        _expectTextWithinRow(tester, 'a1');
        // The compact form is unchanged in kind — still three capped,
        // ellipsized lines. Truncating more of the summary is the correct
        // response to bigger text; wrapping into an unbounded row is not.
        _expectEveryLineSingleAndEllipsized(tester, 'a1');
      });

      for (final locale in const [Locale('en', 'GB'), Locale('pt', 'PT')]) {
        testWidgets(
          'at $label the row still meets the 44px tap-target floor in '
          '${locale.languageCode} (D-18)',
          (tester) async {
            // Both locales, because the row's height follows its text and
            // PT's labels are the longer ones.
            _useViewport(tester, _narrowViewport);
            await tester.pumpWidget(
              _buildList(
                locale: locale,
                activities: [_activity()],
                textScaler: scale,
              ),
            );
            await tester.pumpAndSettle();

            expect(
              tester.getSize(_row('a1')).height,
              greaterThanOrEqualTo(kMinTapTarget),
            );
          },
        );
      }

      testWidgets('at $label the apiary-detail card case lays out too', (
        tester,
      ) async {
        _useViewport(tester, _narrowViewport);
        await tester.pumpWidget(
          _buildList(
            locale: const Locale('en', 'GB'),
            activities: [_activity()],
            // The narrowest place this tile renders (see the default-scale
            // case above): the apiary detail's padded card.
            rowWidth: 343,
            textScaler: scale,
          ),
        );
        await tester.pumpAndSettle();

        _expectNoOverflow(tester);
        _expectTextWithinRow(tester, 'a1');
        _expectEveryLineSingleAndEllipsized(tester, 'a1');
      });

      testWidgets('at $label Portuguese lays out too', (tester) async {
        _useViewport(tester, _narrowViewport);
        await tester.pumpWidget(
          _buildList(
            locale: const Locale('pt', 'PT'),
            activities: [_activity()],
            textScaler: scale,
          ),
        );
        await tester.pumpAndSettle();

        _expectNoOverflow(tester);
        _expectTextWithinRow(tester, 'a1');
        _expectEveryLineSingleAndEllipsized(tester, 'a1');
      });
    }

    testWidgets('an apiary-qualified title still fits on one line at 2.0x', (
      tester,
    ) async {
      // The widest title this row can be asked to render, at the widest text
      // the checklist covers — the case most likely to break the cap.
      _useViewport(tester, _narrowViewport);
      await tester.pumpWidget(
        _buildList(
          locale: const Locale('en', 'GB'),
          activities: [_activity()],
          apiaryNameOf: (_) =>
              'An apiary with a deliberately very long name indeed',
          textScaler: _maxTextScale,
        ),
      );
      await tester.pumpAndSettle();

      _expectNoOverflow(tester);
      _expectTextWithinRow(tester, 'a1');
      _expectEveryLineSingleAndEllipsized(tester, 'a1');
    });

    testWidgets('the attribution keeps its screen-reader label at 2.0x '
        '(D-18)', (tester) async {
      // Scaling text must not change what the row ANNOUNCES — the wide/
      // compact semantics parity #632 established has to survive it too.
      _useViewport(tester, _narrowViewport);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _buildList(
          locale: const Locale('en', 'GB'),
          activities: [_activity()],
          textScaler: _maxTextScale,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel(RegExp('Performed by: You')),
        findsOneWidget,
      );
      handle.dispose();
    });

    for (final (scale, rows) in _scaledRowsPerScreen) {
      final label = '${scale.scale(1).toStringAsFixed(1)}x';

      testWidgets('at $label the density budget is restated at $rows rows, '
          'not assumed to still be eight', (tester) async {
        // The honest version of "at least eight activities fit on one phone
        // screen" (#759 AC 2) — see [_scaledRowsPerScreen] for where these
        // numbers come from.
        _useViewport(tester, _narrowViewport);
        await tester.pumpWidget(
          _buildList(
            locale: const Locale('en', 'GB'),
            activities: [for (var i = 0; i < 10; i++) _activity(id: 'a$i')],
            textScaler: scale,
          ),
        );
        await tester.pumpAndSettle();

        final rowHeight = tester.getSize(_row('a0')).height;
        final fit = (_narrowViewport.height / rowHeight).floor();
        expect(
          fit,
          greaterThanOrEqualTo(rows),
          reason:
              'a ${rowHeight.toStringAsFixed(1)}px row at $label only fits '
              '$fit activities on a '
              '${_narrowViewport.height.toInt()}px screen',
        );
      });
    }
  });
}
