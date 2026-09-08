// Table-driven content-width sweep (#650) across every list/content screen
// this milestone constrains, modeled on a11y_field_ux_test.dart's own sweep:
// one shared assertion applied consistently across screens, so the next list
// screen that forgets the [ContentColumn] wrap fails in one obvious place
// rather than shipping a silently full-bleed row.
//
// At 1280x800 (the wide desktop viewport #650's own audit used) every case
// asserts: at least one [ContentColumn] is present (the screen actually
// wraps its content) and none renders wider than [BrandDimens.maxWidthList]
// — in both EN and PT, since a longer Portuguese string is exactly the kind
// of content that could tempt a screen into a wider, unwrapped layout.
import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/geo/device_location.dart';
import 'package:beekeepingit_client/core/widgets/content_column.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/history/history_repository.dart';
import 'package:beekeepingit_client/features/journeys/journeys_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:beekeepingit_client/features/stock_declarations/stock_declarations_repository.dart';
import 'package:beekeepingit_client/features/sync/sync_rejected_repository.dart';
import 'package:beekeepingit_client/features/todos/todos_repository.dart';
import 'package:beekeepingit_client/routing/app_router.dart';
import 'package:beekeepingit_client/theming/brand_dimens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Never touches the real `geolocator` platform channel (mirrors
/// apiaries_list_screen_test.dart's own fixture).
class _FakeDeviceLocationService implements DeviceLocationService {
  const _FakeDeviceLocationService();
  @override
  Future<DeviceLocation> current() async => const DeviceLocationUnavailable();
}

class _ProfileControllerFor extends ProfileController {
  _ProfileControllerFor(this.locale);
  final String locale;

  @override
  Future<Profile> build() async => Profile(
    id: 'test-user',
    name: 'Test User',
    email: 'test@example.com',
    locale: locale,
    profileComplete: true,
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _ExistingOrganizationController extends OrganizationController {
  @override
  Future<Organization?> build() async => Organization(
    id: 'test-org',
    name: 'Test Apiary Co.',
    address: '',
    createdBy: 'test-user',
    role: 'admin',
    createdAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
  );
}

class _EmptyMembersController extends MembersController {
  @override
  Future<MembersState> build() async =>
      const MembersState(members: [], invitations: []);
}

const _apiary = Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3);

/// Boots the whole app (matching todos_list_screen_test.dart's/
/// apiary_activities_screen_test.dart's own convention for a tab-root or
/// deep-linked screen) with every stream this sweep's screens read
/// overridden to a fixed, resolved value — so every screen reaches a
/// deterministic, ContentColumn-bearing state rather than sitting in
/// AsyncLoading against real (unavailable-in-test) infrastructure.
Future<_AppNavigator> _bootApp(
  WidgetTester tester, {
  required String locale,
}) async {
  late final ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        isAuthenticatedProvider.overrideWithValue(true),
        profileProvider.overrideWith(() => _ProfileControllerFor(locale)),
        organizationProvider.overrideWith(_ExistingOrganizationController.new),
        deviceLocationServiceProvider.overrideWithValue(
          const _FakeDeviceLocationService(),
        ),
        apiariesStreamProvider.overrideWith(
          (ref) => Stream.value(const [_apiary]),
        ),
        apiaryByIdProvider.overrideWith((ref, id) => Stream.value(_apiary)),
        activitiesStreamProvider.overrideWith(
          (ref) => Stream.value(const <Activity>[]),
        ),
        activitiesByApiaryProvider.overrideWith(
          (ref, apiaryId) => Stream.value(const <Activity>[]),
        ),
        todosStreamProvider.overrideWith((ref) => Stream.value(const <Todo>[])),
        journeysStreamProvider.overrideWith(
          (ref) => Stream.value(const <Journey>[]),
        ),
        memberNamesProvider.overrideWith((ref) async => const {}),
        membersProvider.overrideWith(_EmptyMembersController.new),
        stockDeclarationsStreamProvider.overrideWith(
          (ref) => Stream.value(const <StockDeclaration>[]),
        ),
        syncRejectedOpsProvider.overrideWith(
          (ref) => Stream.value(const <RejectedOp>[]),
        ),
        entityHistoryProvider.overrideWith(
          (ref, target) => Stream.value(const <HistoryEntry>[]),
        ),
      ],
      child: const BeekeepingitApp(),
    ),
  );
  container = ProviderScope.containerOf(
    tester.element(find.byType(BeekeepingitApp)),
  );
  await tester.pumpAndSettle();
  return _AppNavigator(container);
}

/// Thin holder so call sites read `nav.go(path)` rather than threading the
/// container's `routerProvider` read at every call site. Deliberately NOT
/// named `GoRouterState` — that name belongs to go_router's own type.
class _AppNavigator {
  _AppNavigator(this._container);
  final ProviderContainer _container;

  Future<void> go(WidgetTester tester, String path) async {
    _container.read(routerProvider).go(path);
    await tester.pumpAndSettle();
  }
}

/// Asserts the shared #650 contract for whatever is currently on screen: at
/// least one [ContentColumn] present, none wider than
/// [BrandDimens.maxWidthList], and nothing thrown laying it out.
void _expectContentWidthContract(WidgetTester tester, {required String where}) {
  final columns = find.byType(ContentColumn);
  expect(
    columns,
    findsAtLeastNWidgets(1),
    reason: '$where must wrap its content in a ContentColumn (#650)',
  );
  for (var i = 0; i < columns.evaluate().length; i++) {
    // ContentColumn itself is a StatelessWidget built as
    // `Align(child: ConstrainedBox(...))` — [Align] always fills its own
    // incoming (bounded) constraints regardless of alignment, so its OWN
    // render box is the full viewport width. The actual cap lives on its
    // [ConstrainedBox] child, so that inner box — not the ContentColumn
    // element itself — is what has to be measured (`.first` to reach the
    // ContentColumn's own ConstrainedBox before any unrelated one deeper in
    // the wrapped content, e.g. a row's own tap-target constraint).
    final constrainedBox = find
        .descendant(of: columns.at(i), matching: find.byType(ConstrainedBox))
        .first;
    final width = tester.getSize(constrainedBox).width;
    expect(
      width,
      lessThanOrEqualTo(BrandDimens.maxWidthList),
      reason:
          '$where rendered a ContentColumn $width px wide — over the '
          '${BrandDimens.maxWidthList}px cap (#650)',
    );
  }
  expect(
    tester.takeException(),
    isNull,
    reason: '$where threw while laying out',
  );
}

void main() {
  // The wide desktop viewport #650's own audit measured the defect at.
  const wideViewport = Size(1280, 800);

  final cases = <(String name, String path)>[
    ('Activities tab', '/activities'),
    ('Apiaries tab (list view)', '/apiaries'),
    ('Journeys tab', '/journeys'),
    ('Todos tab', '/todos'),
    ('Home tab', '/home'),
    ('Apiary history', '/apiaries/a1/history'),
    ('Apiary activities (full list)', '/apiaries/a1/activities'),
    ('Members', '/organization/members'),
    ('Stock declarations', '/stock-declarations'),
    ('Sync needs-fix', '/sync-needs-fix'),
    ('Not found', '/home/not-found'),
  ];

  for (final locale in const ['en', 'pt']) {
    for (final (name, path) in cases) {
      testWidgets(
        '$name stays within maxWidthList at 1280x800 ($locale, #650)',
        (tester) async {
          tester.view.physicalSize = wideViewport;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final router = await _bootApp(tester, locale: locale);
          await router.go(tester, path);

          _expectContentWidthContract(tester, where: name);
        },
      );
    }
  }
}
