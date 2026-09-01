import 'package:beekeepingit_client/core/l10n/locale_formatting.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/dgav/dgav_screen.dart';
import 'package:beekeepingit_client/features/dgav/stock_declarations_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// FR-AP-9 + FR-AP-10 (#296/#298): the DGAV screen.
///
/// The screen is mounted directly rather than through the app shell — it is a
/// leaf screen reached from Account, with no routing behaviour of its own worth
/// re-testing here, and mounting it directly keeps these tests hermetic (no
/// PowerSync, no router, no auth chain).
class _FakeOrganizationController extends OrganizationController {
  _FakeOrganizationController({this.dgavNumber = '', this.role = 'admin'});

  final String dgavNumber;
  final String role;

  @override
  Future<Organization?> build() async => Organization(
    id: 'org-1',
    name: 'Apiários do Montargil',
    address: '',
    dgavRegistrationNumber: dgavNumber,
    createdBy: 'user-1',
    role: role,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

Widget _buildScreen({
  String orgDgavNumber = '',
  String role = 'admin',
  List<Apiary> apiaries = const [],
  List<StockDeclaration> declarations = const [],
}) {
  return ProviderScope(
    overrides: [
      organizationProvider.overrideWith(
        () =>
            _FakeOrganizationController(dgavNumber: orgDgavNumber, role: role),
      ),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      stockDeclarationsStreamProvider.overrideWith(
        (ref) => Stream.value(declarations),
      ),
    ],
    child: const MaterialApp(
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: DgavScreen(),
    ),
  );
}

void main() {
  _recordFlowTests();
  testWidgets(
    "states up front that nothing is filed on the beekeeper's behalf — "
    'everything here is advisory (D-19 §7)',
    (tester) async {
      await tester.pumpWidget(_buildScreen());
      await tester.pumpAndSettle();

      expect(
        find.textContaining('never files anything for you'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'shows the organization registration number, editable by an admin',
    (tester) async {
      await tester.pumpWidget(_buildScreen(orgDgavNumber: 'PT-123456'));
      await tester.pumpAndSettle();

      final field = find.byKey(const Key('dgav-org-number-field'));
      expect(field, findsOneWidget);
      expect(tester.widget<TextField>(field).controller?.text, 'PT-123456');
      expect(tester.widget<TextField>(field).enabled, isTrue);
      expect(find.byKey(const Key('dgav-org-number-save')), findsOneWidget);
    },
  );

  testWidgets('a non-admin sees the number but cannot edit it (NFR-ROL-1)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildScreen(orgDgavNumber: 'PT-123456', role: 'user'),
    );
    await tester.pumpAndSettle();

    final field = find.byKey(const Key('dgav-org-number-field'));
    expect(tester.widget<TextField>(field).controller?.text, 'PT-123456');
    expect(tester.widget<TextField>(field).enabled, isFalse);
    expect(find.byKey(const Key('dgav-org-number-save')), findsNothing);
    expect(
      find.text('Only an organization admin can change this.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'groups declarations per registration number, so an organization covering '
    'several beekeepers files separately',
    (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          orgDgavNumber: 'PT-111',
          apiaries: const [
            Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 10),
            Apiary(
              id: 'a2',
              name: 'Monte Alto',
              hiveCount: 20,
              dgavRegistrationNumber: 'PT-222',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('dgav-group-PT-111')), findsOneWidget);
      expect(find.byKey(const Key('dgav-group-PT-222')), findsOneWidget);
    },
  );

  testWidgets(
    "a group's current hive count is the live total of its apiaries, shown "
    'alongside the declaration log so the two are visibly distinct '
    '(FR-AP-7 vs FR-AP-10)',
    (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          orgDgavNumber: 'PT-111',
          apiaries: const [
            Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 10),
            Apiary(id: 'a2', name: 'Monte Alto', hiveCount: 7),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Current hive count: 17'), findsOneWidget);
    },
  );

  testWidgets(
    'flags the interim trigger when the hive count has moved by more than 20% '
    'AND at least 20 colonies since the last declaration',
    (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          orgDgavNumber: 'PT-111',
          apiaries: const [
            Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 130),
          ],
          declarations: [
            StockDeclaration(
              id: 'd1',
              dgavRegistrationNumber: 'PT-111',
              declaredOn: DateTime(2026, 3, 1),
              totalHiveCount: 100,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('dgav-status-PT-111')), findsOneWidget);
      expect(
        find.textContaining('an interim declaration may be due'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'does NOT flag the interim trigger for a small holding whose percentage '
    'moved a lot but whose colony count barely did — the case the AND rule '
    'exists for',
    (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          orgDgavNumber: 'PT-111',
          apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 4)],
          declarations: [
            StockDeclaration(
              id: 'd1',
              dgavRegistrationNumber: 'PT-111',
              declaredOn: DateTime(2026, 3, 1),
              totalHiveCount: 3,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('an interim declaration may be due'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'lists a recorded declaration with its date, declared total and apiary '
    'count',
    (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          orgDgavNumber: 'PT-111',
          declarations: [
            StockDeclaration(
              id: 'd1',
              dgavRegistrationNumber: 'PT-111',
              declaredOn: DateTime(2026, 9, 12),
              totalHiveCount: 30,
              breakdown: const [
                StockDeclarationApiary(
                  apiaryId: 'a1',
                  name: 'Serra Norte',
                  hiveCount: 18,
                ),
                StockDeclarationApiary(
                  apiaryId: 'a2',
                  name: 'Monte Alto',
                  hiveCount: 12,
                ),
              ],
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('dgav-declaration-d1')), findsOneWidget);
      // Localized via LocaleFormatting (DateFormat.yMMMd), not the raw stored
      // YYYY-MM-DD — the regression this assertion exists to catch.
      expect(find.text('Sep 12, 2026 — 30 hives'), findsOneWidget);
      expect(find.text('2 apiaries'), findsOneWidget);
    },
  );

  testWidgets('shows the empty state when nothing has been declared yet', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildScreen(
        orgDgavNumber: 'PT-111',
        apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No declarations recorded yet.'), findsOneWidget);
  });
}

/// The record flow (#298): recording asks for the declaration date and an
/// optional note rather than writing silently at `DateTime.now()`.
void _recordFlowTests() {
  group('record-declaration dialog (FR-AP-10, #298)', () {
    testWidgets('the record action opens a dialog rather than writing '
        'immediately — a regulatory record should not appear from one '
        'unconfirmed tap', (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          orgDgavNumber: 'PT-111',
          apiaries: const [
            Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 12),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('dgav-record-PT-111')));
      await tester.pumpAndSettle();

      expect(find.text('Record declaration'), findsWidgets);
      expect(
        find.byKey(const Key('dgav-declaration-date-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('dgav-declaration-notes-field')),
        findsOneWidget,
      );
      // The declared total is shown, pre-filled from the live counters.
      expect(find.text('12 hives'), findsOneWidget);
    });

    testWidgets('the date defaults to today, rendered localized', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildScreen(
          orgDgavNumber: 'PT-111',
          apiaries: const [
            Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 12),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dgav-record-PT-111')));
      await tester.pumpAndSettle();

      final today = DateTime.now();
      final expected = const LocaleFormatting.forLocale('en').date(today);
      expect(find.text(expected), findsOneWidget);
    });

    testWidgets('cancelling writes nothing', (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          orgDgavNumber: 'PT-111',
          apiaries: const [
            Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 12),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('dgav-record-PT-111')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('dgav-record-cancel')));
      await tester.pumpAndSettle();

      // Still the empty state — the stream override never changes, so the only
      // observable effect of a write would be the snackbar, which must not appear.
      expect(find.text('Declaration recorded'), findsNothing);
    });

    testWidgets("the dialog's actions meet the 44x44 gloves-friendly minimum "
        '(D-18)', (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          orgDgavNumber: 'PT-111',
          apiaries: const [
            Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 12),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // The group's own record action first.
      final record = tester.getSize(
        find.byKey(const Key('dgav-record-PT-111')),
      );
      expect(record.height, greaterThanOrEqualTo(44));

      await tester.tap(find.byKey(const Key('dgav-record-PT-111')));
      await tester.pumpAndSettle();

      for (final key in const [
        Key('dgav-record-cancel'),
        Key('dgav-record-confirm'),
        Key('dgav-declaration-date-field'),
      ]) {
        final size = tester.getSize(find.byKey(key));
        expect(
          size.height,
          greaterThanOrEqualTo(44),
          reason: '$key must clear the 44px minimum tap target (D-18)',
        );
      }
    });

    testWidgets('the organization number save action also meets the minimum', (
      tester,
    ) async {
      await tester.pumpWidget(_buildScreen(orgDgavNumber: 'PT-111'));
      await tester.pumpAndSettle();

      final size = tester.getSize(
        find.byKey(const Key('dgav-org-number-save')),
      );
      expect(size.height, greaterThanOrEqualTo(44));
    });
  });
}
