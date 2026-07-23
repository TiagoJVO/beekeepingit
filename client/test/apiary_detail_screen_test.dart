import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/features/activities/activities_repository.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fixtures mirroring widget_test.dart's/app_shell_test.dart's own — kept
/// local rather than imported since those files' fixtures are file-private.
class _CompleteProfileController extends ProfileController {
  @override
  Future<Profile> build() async => Profile(
    id: 'test-user',
    name: 'Test User',
    email: 'test@example.com',
    locale: 'en',
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

/// A no-op [LocalStoreEngine] — [_FakeApiariesRepository] overrides every
/// method the counters section touches, so the superclass's store is never
/// actually used. Mirrors add_activity_screen_test.dart's own identical
/// fixture.
class _NoopLocalStore implements LocalStoreEngine {
  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) => const Stream.empty();
  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async => null;
  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => const [];
  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}
  @override
  Future<void> clear() async {}
}

/// Records `setCounter()` calls from the detail screen's counters section
/// (#346): editing a counter card's value or adding a new counter both write
/// through this method. Overrides only what the counters section touches.
class _FakeApiariesRepository extends ApiariesRepository {
  _FakeApiariesRepository() : super(_NoopLocalStore());

  final List<({String apiaryId, String counterType, int value})> counterWrites =
      [];

  @override
  Future<void> setCounter(
    String apiaryId,
    String counterType,
    int value,
  ) async {
    counterWrites.add((
      apiaryId: apiaryId,
      counterType: counterType,
      value: value,
    ));
  }
}

/// Builds the full app (real router/shell included) as an authenticated,
/// onboarded user with a fixed local apiaries list — the detail screen
/// (#32) reads from the same apiariesStreamProvider the list screen does,
/// so this harness matches widget_test.dart's/app_shell_test.dart's own
/// override-providers-not-network convention.
///
/// Note on the edit-navigation test below: apiariesRepositoryProvider (the
/// one that actually reads/writes — powered by a real, connecting
/// PowerSync instance) is intentionally left un-overridden, matching every
/// other widget test in this suite. That means once navigation reaches
/// apiary_form_screen.dart in edit mode, its initState-triggered
/// _loadExisting() never resolves in this environment (no platform
/// channel/network), so the form is left showing its own indefinite busy
/// spinner rather than the loaded field — expected and asserted on, not a
/// bug in the screen under test.
///
/// The add-todo FAB test below only asserts navigation to the full form
/// (#389) — it never saves, so unlike the retired #52 quick-create sheet's
/// own tests, no `todosRepositoryProvider` override is needed here.
Widget _buildApp({
  required List<Apiary> apiaries,
  Map<String, List<ApiaryCounter>> counters = const {},
  ApiariesRepository? apiariesRepository,
}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      // The counters section (#346) writes counter edits/adds through
      // apiariesRepositoryProvider. Left un-overridden it's the real,
      // never-resolving PowerSync-backed repo (fine for the read-only badge
      // tests, which never tap an editor); the edit/add tests pass a fake
      // here to record setCounter() without a backend.
      if (apiariesRepository != null)
        apiariesRepositoryProvider.overrideWith(
          (ref) async => apiariesRepository,
        ),
      // The detail screen watches apiaryByIdProvider (HIGH finding: a
      // narrow per-id family provider, not the whole-org
      // apiariesStreamProvider) — overridden here the same way
      // apiaryCountersProvider already is, resolving from the same fixed
      // [apiaries] list by id so existing fixtures/tests don't need to
      // change shape.
      apiaryByIdProvider.overrideWith(
        (ref, apiaryId) => Stream.value(
          apiaries.cast<Apiary?>().firstWhere(
            (a) => a!.id == apiaryId,
            orElse: () => null,
          ),
        ),
      ),
      // The detail screen's generic counters section (#256) watches this
      // family provider per apiary id. Un-overridden it depends on the real
      // (never-resolving in tests) apiariesRepositoryProvider, so the tests
      // that don't care about non-hive counters simply see it stay in
      // loading state (only the always-on hive badge renders — exactly the
      // "hives always shows" default). Tests that DO exercise other-type
      // rendering pass a fixed list here.
      apiaryCountersProvider.overrideWith(
        (ref, apiaryId) =>
            Stream.value(counters[apiaryId] ?? const <ApiaryCounter>[]),
      ),
      // The activities section (#42) watches this family provider per
      // apiary id — overridden with an empty stream so opening the detail
      // screen doesn't hang on the real (never-resolving here)
      // activitiesRepositoryProvider chain; unlike the counters section,
      // ActivityListView DOES render a loading spinner, which would make
      // pumpAndSettle time out if left un-overridden.
      activitiesByApiaryProvider.overrideWith(
        (ref, apiaryId) => Stream.value(const <Activity>[]),
      ),
      profileProvider.overrideWith(_CompleteProfileController.new),
      // Keep the member-name roster hermetic (#44): the activity list watches
      // memberNamesProvider, which would otherwise attempt a real fetch —
      // attribution falls back to short ids here, which these tests assert.
      memberNamesProvider.overrideWith((ref) async => const <String, String>{}),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

void main() {
  testWidgets('tapping an apiary in the list opens its detail screen (#32)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('apiary-a1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('apiary-detail-header')), findsOneWidget);
    expect(find.text('Serra Norte'), findsOneWidget);
    expect(find.text('3 hives'), findsOneWidget);
  });

  testWidgets(
    'the detail screen renders correctly when location and notes are empty (#32 AC)',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 0)],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('apiary-detail-header')), findsOneWidget);
      expect(find.byKey(const Key('apiary-detail-location')), findsOneWidget);
      expect(find.text('No location set'), findsOneWidget);
      // No notes block at all when notes is unset — not an empty card.
      expect(find.byKey(const Key('apiary-detail-notes')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the detail screen shows notes when present (FR-AP-8, #196)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        apiaries: const [
          Apiary(
            id: 'a1',
            name: 'Serra Norte',
            hiveCount: 3,
            notes: 'Rosmaninho e eucalipto; acesso por caminho de terra.',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('apiary-a1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('apiary-detail-notes')), findsOneWidget);
    expect(
      find.text('Rosmaninho e eucalipto; acesso por caminho de terra.'),
      findsOneWidget,
    );
  });

  testWidgets('a blank (whitespace-only) notes value is treated as absent', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        apiaries: const [
          Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3, notes: '   '),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('apiary-a1')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('apiary-detail-notes')), findsNothing);
  });

  testWidgets('the edit action navigates to the edit form (#32)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildApp(
        apiaries: const [
          Apiary(
            id: 'a1',
            name: 'Serra Norte',
            hiveCount: 3,
            notes: 'Cerca elétrica.',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('apiary-a1')));
    await tester.pumpAndSettle();

    // The edit action lives inside the single "Actions" speed dial now
    // (#347) — expand it first, then tap the revealed edit option.
    await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('apiary-detail-edit-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('apiary-detail-edit-button')));
    // Pump past the page-transition animation in bounded steps (not
    // pumpAndSettle, which would wait forever): the edit form's initState
    // kicks off a real apiariesRepositoryProvider load
    // (apiary_form_screen.dart's _loadExisting), which needs a real
    // PowerSync instance this widget-test environment doesn't provide —
    // the form is left showing its own (indefinite) busy spinner, whose
    // implicit animation would make pumpAndSettle hang. What this test
    // asserts is the navigation itself: the route changed to the edit
    // form and the shell header/back button reflect that. Several smaller
    // pumps (rather than one large jump) reliably carry the transition to
    // completion regardless of its exact curve/duration.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // "Edit apiary" is asserted via findsWidgets, not findsOneWidget: the
    // string is shared by the shell header title (editApiaryTitle) and
    // the detail screen's own FAB label (editApiaryAction) — both
    // legitimately render "Edit apiary" in EN. The detail screen's own
    // Container (apiary-detail-header) also stays mounted underneath the
    // pushed edit route (the Navigator keeps the previous page's widget
    // tree alive, not just off-screen, until it's actually popped). The
    // real signal that navigation reached the edit form is the header
    // title switch plus the form's own (indefinite, PowerSync-less)
    // loading spinner — apiary_form_screen.dart's edit mode always shows
    // that spinner in this test environment (see the file-level doc
    // comment above), never the loaded field, so a spinner is exactly
    // what "we're on the edit form" looks like here.
    expect(find.text('Edit apiary'), findsWidgets);
    expect(find.byKey(const Key('shell-back-button')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // The back button returns to the detail screen, not straight to the
    // list (edit is pushed under the detail route in app_router.dart).
    await tester.tap(find.byKey(const Key('shell-back-button')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const Key('apiary-detail-header')), findsOneWidget);
  });

  // --- Counters section (#256, FR-AP-7) ---

  testWidgets(
    'the hives badge ALWAYS shows (0 when the apiary has no counter row) '
    '(#256 AC)',
    (tester) async {
      // No hive counter row for this apiary at all — hive_count resolves to
      // 0 at the repository (the "0 default" here comes in via hiveCount: 0
      // on the model, which the real repo derives from the absent counter),
      // and the badge must still render.
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 0)],
          counters: const {'a1': <ApiaryCounter>[]},
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      // The hive badge is present and reads the "no hives" plural — the exact
      // text the e2e depends on, unchanged by the counters decoupling.
      expect(find.byKey(const Key('apiary-detail-hive-count')), findsOneWidget);
      expect(find.text('No hives'), findsOneWidget);
    },
  );

  testWidgets(
    'the hives badge shows the counter-backed value (e2e "12 hives" stays '
    'identical) (#256)',
    (tester) async {
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [
            Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 12),
          ],
          counters: const {
            'a1': [
              ApiaryCounter(apiaryId: 'a1', counterType: 'hive', value: 12),
            ],
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('apiary-detail-hive-count')), findsOneWidget);
      expect(find.text('12 hives'), findsOneWidget);
    },
  );

  testWidgets(
    'an unknown/newer-server counter type is skipped, not rendered as raw '
    'internals (#256: additive row shapes degrade gracefully)',
    (tester) async {
      // A counter type this client version has no label for
      // (counter_types.dart's counterValueLabel returns null). It must NOT
      // appear on screen (no badge, no leaked type string), while the hive
      // badge still renders normally.
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 4)],
          counters: const {
            'a1': [
              ApiaryCounter(apiaryId: 'a1', counterType: 'hive', value: 4),
              ApiaryCounter(
                apiaryId: 'a1',
                counterType: 'nucs_from_future',
                value: 7,
              ),
            ],
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      expect(find.text('4 hives'), findsOneWidget);
      expect(
        find.byKey(const Key('apiary-detail-counter-nucs_from_future')),
        findsNothing,
      );
      expect(find.textContaining('nucs_from_future'), findsNothing);
      expect(find.textContaining('7'), findsNothing);
    },
  );

  // --- Counter management: edit + add (#346, FR-AP-7, D-20) ---

  group('counter editing + add (#346)', () {
    testWidgets(
      'tapping the hive card opens the inline editor and saving writes the '
      'value through setCounter(hive) (#346 AC: counters editable on detail)',
      (tester) async {
        final repo = _FakeApiariesRepository();
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
            apiariesRepository: repo,
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        // No editor until a card is tapped.
        expect(
          find.byKey(const Key('apiary-detail-counter-editor')),
          findsNothing,
        );

        await tester.tap(find.byKey(const Key('apiary-detail-hive-count')));
        await tester.pumpAndSettle();

        // Editor opens pre-filled with the current value.
        expect(
          find.byKey(const Key('apiary-detail-counter-editor')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('apiary-counter-edit-field')),
          findsOneWidget,
        );

        await tester.enterText(
          find.byKey(const Key('apiary-counter-edit-field')),
          '12',
        );
        await tester.tap(find.byKey(const Key('apiary-counter-save')));
        await tester.pumpAndSettle();

        expect(repo.counterWrites, hasLength(1));
        expect(repo.counterWrites.single.apiaryId, 'a1');
        expect(repo.counterWrites.single.counterType, 'hive');
        expect(repo.counterWrites.single.value, 12);
        // Editor closes after saving.
        expect(
          find.byKey(const Key('apiary-detail-counter-editor')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'the +/- stepper adjusts the draft value before saving (gloves-friendly)',
      (tester) async {
        final repo = _FakeApiariesRepository();
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
            apiariesRepository: repo,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-detail-hive-count')));
        await tester.pumpAndSettle();

        // From 3: +1 twice = 5, then save.
        await tester.tap(find.byKey(const Key('apiary-counter-increment')));
        await tester.tap(find.byKey(const Key('apiary-counter-increment')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('apiary-counter-save')));
        await tester.pumpAndSettle();

        expect(repo.counterWrites.single.value, 5);
      },
    );

    testWidgets(
      'the add-counter action lets the user pick a known type (Supers) and set '
      'its value; the write goes through setCounter(super) (#346 AC)',
      (tester) async {
        final repo = _FakeApiariesRepository();
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
            apiariesRepository: repo,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        // Supers has no row yet, so the add-counter action is present.
        expect(
          find.byKey(const Key('apiary-detail-add-counter-button')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-counter-button')),
        );
        await tester.pumpAndSettle();

        // The picker offers Supers.
        expect(
          find.byKey(const Key('apiary-add-counter-option-super')),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('apiary-add-counter-option-super')),
        );
        await tester.pumpAndSettle();

        // The editor opens for the picked type at 0; set a value and save.
        expect(
          find.byKey(const Key('apiary-detail-counter-editor')),
          findsOneWidget,
        );
        await tester.enterText(
          find.byKey(const Key('apiary-counter-edit-field')),
          '4',
        );
        await tester.tap(find.byKey(const Key('apiary-counter-save')));
        await tester.pumpAndSettle();

        expect(repo.counterWrites, hasLength(1));
        expect(repo.counterWrites.single.counterType, 'super');
        expect(repo.counterWrites.single.value, 4);
      },
    );

    testWidgets(
      'a known non-hive counter with a row renders its own tappable card, and '
      'the add-counter action disappears (UNIQUE respected — no second super)',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
            counters: const {
              'a1': [
                ApiaryCounter(apiaryId: 'a1', counterType: 'hive', value: 3),
                ApiaryCounter(apiaryId: 'a1', counterType: 'super', value: 6),
                ApiaryCounter(
                  apiaryId: 'a1',
                  counterType: 'empty_hive',
                  value: 1,
                ),
                ApiaryCounter(apiaryId: 'a1', counterType: 'swarm', value: 2),
              ],
            },
            apiariesRepository: _FakeApiariesRepository(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('apiary-detail-counter-super')),
          findsOneWidget,
        );
        expect(find.text('6 supers'), findsOneWidget);
        // Every known type now has a row (hive + super + empty_hive + swarm),
        // so nothing is addable.
        expect(
          find.byKey(const Key('apiary-detail-add-counter-button')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'empty-hive and swarm counters render their own tappable cards with '
      'localized labels (#392)',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
            counters: const {
              'a1': [
                ApiaryCounter(
                  apiaryId: 'a1',
                  counterType: 'empty_hive',
                  value: 1,
                ),
                ApiaryCounter(apiaryId: 'a1', counterType: 'swarm', value: 2),
              ],
            },
            apiariesRepository: _FakeApiariesRepository(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('apiary-detail-counter-empty_hive')),
          findsOneWidget,
        );
        expect(find.text('1 empty hive'), findsOneWidget);
        expect(
          find.byKey(const Key('apiary-detail-counter-swarm')),
          findsOneWidget,
        );
        expect(find.text('2 swarms'), findsOneWidget);
      },
    );

    testWidgets(
      'the add-counter picker offers empty hives and swarms once hive and '
      'super rows already exist (#392)',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
            counters: const {
              'a1': [
                ApiaryCounter(apiaryId: 'a1', counterType: 'hive', value: 3),
                ApiaryCounter(apiaryId: 'a1', counterType: 'super', value: 6),
              ],
            },
            apiariesRepository: _FakeApiariesRepository(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        await tester.tap(
          find.byKey(const Key('apiary-detail-add-counter-button')),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('apiary-add-counter-option-empty_hive')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('apiary-add-counter-option-swarm')),
          findsOneWidget,
        );
      },
    );
  });

  // --- Error state (HIGH #4: no test previously drove the error: branch) ---

  testWidgets(
    'shows an error state (not a crash/blank page) when the per-apiary '
    'stream errors',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            isAuthenticatedProvider.overrideWithValue(true),
            apiariesStreamProvider.overrideWith(
              (ref) => Stream.value(const [
                Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
              ]),
            ),
            apiaryByIdProvider.overrideWith(
              (ref, apiaryId) => Stream<Apiary?>.error('boom'),
            ),
            apiaryCountersProvider.overrideWith(
              (ref, apiaryId) => Stream.value(const <ApiaryCounter>[]),
            ),
            activitiesByApiaryProvider.overrideWith(
              (ref, apiaryId) => Stream.value(const <Activity>[]),
            ),
            profileProvider.overrideWith(_CompleteProfileController.new),
            memberNamesProvider.overrideWith(
              (ref) async => const <String, String>{},
            ),
            organizationProvider.overrideWith(
              _ExistingOrganizationController.new,
            ),
          ],
          child: const BeekeepingitApp(),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not load apiaries'), findsOneWidget);
      expect(find.byKey(const Key('apiary-detail-header')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  // --- Consolidated "Actions" speed dial (#347, FR-UX-1, FR-UX-2) ---

  group('actions speed dial (#347)', () {
    testWidgets(
      'a single "Actions" control replaces the stacked FABs — the three '
      'options are hidden until it is expanded, and collapse cleanly again',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        // Collapsed: only the single Actions toggle shows; none of the
        // scope's options are in the tree.
        expect(
          find.byKey(const Key('actions-speed-dial-toggle')),
          findsOneWidget,
        );
        expect(find.text('Actions'), findsOneWidget);
        for (final key in const [
          'apiary-detail-add-todo-button',
          'apiary-detail-add-activity-button',
          'apiary-detail-edit-button',
        ]) {
          expect(find.byKey(Key(key)), findsNothing);
        }

        // Expand: all three scope-appropriate options are revealed.
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        for (final key in const [
          'apiary-detail-add-todo-button',
          'apiary-detail-add-activity-button',
          'apiary-detail-edit-button',
        ]) {
          expect(find.byKey(Key(key)), findsOneWidget);
        }

        // Collapse again: the options are gone, the toggle remains.
        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('actions-speed-dial-toggle')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('apiary-detail-edit-button')),
          findsNothing,
        );
      },
    );

    testWidgets(
      'the Actions toggle announces its expanded/collapsed state to screen '
      'readers (D-18 accessibility)',
      (tester) async {
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        final toggle = find.byKey(const Key('actions-speed-dial-toggle'));
        // Collapsed: a button named "Actions" that advertises an expandable
        // state, currently not expanded.
        expect(
          tester.getSemantics(toggle),
          isSemantics(
            isButton: true,
            label: 'Actions',
            hasExpandedState: true,
            isExpanded: false,
          ),
        );

        await tester.tap(toggle);
        await tester.pumpAndSettle();

        // Expanded: the same node now reports the expanded state.
        expect(
          tester.getSemantics(toggle),
          isSemantics(hasExpandedState: true, isExpanded: true),
        );

        // Dispose within the test body — the end-of-test handle-leak check
        // runs before addTearDown callbacks would.
        handle.dispose();
      },
    );

    testWidgets('tapping the add-todo option routes to the full create form, '
        'pre-selecting this apiary (#389, FR-UX-2 contextual create)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3)],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apiary-detail-add-todo-button')));
      await tester.pumpAndSettle();

      // The full form (#293), not #52's now-retired quick-create sheet —
      // its apiary picker shows this apiary already selected, resolved
      // from the route's own `?apiaryId=a1` (app_router.dart's `todoNew`
      // builder).
      expect(find.byKey(const Key('todo-title-field')), findsOneWidget);
      expect(find.text('New todo'), findsWidgets);
      expect(find.text('Serra Norte'), findsOneWidget);
    });

    testWidgets(
      'the existing add-activity FAB still navigates as before (regression '
      'guard)',
      (tester) async {
        await tester.pumpWidget(
          _buildApp(
            apiaries: const [
              Apiary(id: 'a1', name: 'Serra Norte', hiveCount: 3),
            ],
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('apiary-a1')));
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('actions-speed-dial-toggle')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('apiary-detail-add-activity-button')),
        );
        // Bounded pumps (not pumpAndSettle, which would hang forever): the
        // pushed add-activity form's own journey-matching section
        // (journeyMatchesProvider) depends on the real, never-resolving
        // journeysRepositoryProvider in this environment, whose loading
        // state renders an indeterminate LinearProgressIndicator — same
        // rationale as this file's own edit-navigation test above, which
        // hits the equivalent issue via apiariesRepositoryProvider.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }

        expect(find.byKey(const Key('shell-back-button')), findsOneWidget);
        expect(find.text('Add activity'), findsWidgets);
      },
    );
  });
}
