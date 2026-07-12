import 'package:beekeepingit_client/app.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/apiaries/apiaries_repository.dart';
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

/// Builds the full app (real router/shell included) as an authenticated,
/// onboarded user with a fixed local apiaries list. apiariesRepositoryProvider
/// itself (the one that actually reads/writes — powered by a real,
/// connecting PowerSync instance) is intentionally left un-overridden here,
/// matching every other widget test in this suite (app_shell_test.dart's FAB
/// test included): none of them drive the form's save/delete actions or
/// edit-mode pre-fill through to completion, because that provider chain
/// needs a real platform channel + network this test environment doesn't
/// have. These tests stop at "the field exists and accepts input" (create
/// mode) or "navigation succeeds" (edit mode) — the actual persistence of
/// `notes` is covered by apiaries_repository.dart's create/update methods (a
/// plain parameterized SQL statement, reviewed directly) and by the
/// server-side round-trip tests (services/apiaries/main_test.go's
/// TestApiariesRest_Notes_CreateAndUpdateRoundTrip /
/// TestApiariesSlice_Notes_SyncApplyRoundTrip).
Widget _buildApp({required List<Apiary> apiaries}) {
  return ProviderScope(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(true),
      apiariesStreamProvider.overrideWith((ref) => Stream.value(apiaries)),
      profileProvider.overrideWith(_CompleteProfileController.new),
      organizationProvider.overrideWith(_ExistingOrganizationController.new),
    ],
    child: const BeekeepingitApp(),
  );
}

void main() {
  testWidgets(
    'the create form has a notes field that accepts free text (FR-AP-8, #196)',
    (tester) async {
      await tester.pumpWidget(_buildApp(apiaries: const []));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('shell-fab')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('apiary-notes-field')), findsOneWidget);
      expect(find.text('Notes'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('apiary-name-field')),
        'Quinta das Flores',
      );
      await tester.enterText(
        find.byKey(const Key('apiary-notes-field')),
        'Flora, acessos, observações…',
      );
      await tester.pump();

      expect(find.text('Flora, acessos, observações…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'navigating to the edit form from the detail screen works without error',
    (tester) async {
      // apiary_form_screen.dart's edit mode (isEdit) always re-fetches the
      // apiary via the real apiariesRepositoryProvider in initState
      // (_loadExisting) rather than accepting the value the caller already
      // has — that provider is backed by a connecting PowerSyncDatabase this
      // widget-test environment can't stand up (no native sqlite extension,
      // no network), so this test — like every other edit-mode test in this
      // suite — stops at "navigation succeeds and the form is left in its
      // (indefinite) loading state without throwing", not asserting on
      // pre-filled field content. The actual pre-fill logic
      // (existing.notes ?? '' -> _notesController.text) is a two-line,
      // directly-reviewed assignment in apiary_form_screen.dart's
      // _loadExisting; the notes persistence it reads from is covered
      // server-side (main_test.go's
      // TestApiariesRest_Notes_CreateAndUpdateRoundTrip).
      await tester.pumpWidget(
        _buildApp(
          apiaries: const [
            Apiary(
              id: 'a1',
              name: 'Monte Alto',
              hiveCount: 4,
              notes: 'Montado de sobro.',
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('apiary-a1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('apiary-detail-edit-button')));
      // Pump past the page-transition animation with a bounded duration
      // (not pumpAndSettle, which would wait forever on the busy spinner's
      // implicit animation below).
      await tester.pump(const Duration(milliseconds: 400));

      // findsWidgets, not findsOneWidget: "Edit apiary" is shared by the
      // shell header title and the outgoing detail screen's own FAB label
      // (apiary_detail_screen_test.dart has the full explanation, which also
      // covers this same navigation more thoroughly — including the
      // shell-back-button/apiary-name-field route-key assertions). This test
      // only additionally confirms the transition into edit-mode's
      // (indefinite, PowerSync-less) loading state doesn't throw.
      expect(find.text('Edit apiary'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
