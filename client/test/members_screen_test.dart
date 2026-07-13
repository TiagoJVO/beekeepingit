import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/members/members_screen.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Member _member({
  String userId = 'user-1',
  String role = 'user',
  String status = 'active',
}) => Member(userId: userId, role: role, status: status);

Invitation _invitation({
  String id = 'inv-1',
  String email = 'invitee@example.com',
  String status = 'pending',
}) => Invitation(
  id: id,
  email: email,
  role: 'user',
  status: status,
  createdAt: DateTime.utc(2026, 1, 1),
);

/// A fake controller so tests drive [MembersScreen] without a real
/// [ApiClient]/network call, matching organization_screen_test.dart's
/// override-providers-not-network convention.
class _FakeMembersController extends MembersController {
  _FakeMembersController(this._initial, {this.onInvite, this.onRevoke});

  final MembersState _initial;
  final Future<void> Function({required String email, String role})? onInvite;
  final Future<void> Function(String invitationId)? onRevoke;

  @override
  Future<MembersState> build() async => _initial;

  @override
  Future<void> invite({required String email, String role = 'user'}) async {
    if (onInvite != null) {
      await onInvite!(email: email, role: role);
      return;
    }
    state = AsyncData(
      MembersState(
        members: _initial.members,
        invitations: [
          ..._initial.invitations,
          _invitation(email: email),
        ],
      ),
    );
  }

  @override
  Future<void> revokeInvitation(String invitationId) async {
    if (onRevoke != null) {
      await onRevoke!(invitationId);
      return;
    }
    state = AsyncData(
      MembersState(
        members: _initial.members,
        invitations: _initial.invitations
            .where((i) => i.id != invitationId)
            .toList(),
      ),
    );
  }
}

Widget _buildScreen(MembersController controller) {
  return ProviderScope(
    overrides: [membersProvider.overrideWith(() => controller)],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MembersScreen(),
    ),
  );
}

void main() {
  testWidgets('renders members and invitations lists', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeMembersController(
          MembersState(
            members: [_member(userId: 'admin-1', role: 'admin')],
            invitations: [_invitation()],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('member-admin-1')), findsOneWidget);
    expect(find.byKey(const Key('invitation-inv-1')), findsOneWidget);
    expect(find.text('invitee@example.com'), findsOneWidget);
  });

  testWidgets('shows empty states when there are no members/invitations', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeMembersController(
          const MembersState(members: [], invitations: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No members yet.'), findsOneWidget);
    expect(find.text('No invitations yet.'), findsOneWidget);
  });

  testWidgets('validates an empty invite email client-side', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeMembersController(
          const MembersState(members: [], invitations: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('invite-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter an email address.'), findsOneWidget);
  });

  testWidgets('submits a valid invite email and shows success', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeMembersController(
          const MembersState(members: [], invitations: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('invite-email-field')),
      'new@example.com',
    );
    await tester.tap(find.byKey(const Key('invite-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Invitation sent.'), findsOneWidget);
  });

  testWidgets('surfaces a mocked 409 duplicate-invite error', (tester) async {
    final controller = _FakeMembersController(
      const MembersState(members: [], invitations: []),
      onInvite: ({required email, role = 'user'}) async {
        throw const ApiException(
          statusCode: 409,
          code: 'resource.conflict',
          detail:
              'this email already has a pending invitation to this organization',
        );
      },
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('invite-email-field')),
      'dup@example.com',
    );
    await tester.tap(find.byKey(const Key('invite-submit-button')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('already has a pending invitation'),
      findsOneWidget,
    );
  });

  testWidgets('revoking a pending invitation shows success', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeMembersController(
          MembersState(members: const [], invitations: [_invitation()]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('revoke-invitation-inv-1')));
    await tester.pumpAndSettle();

    expect(find.text('Invitation revoked.'), findsOneWidget);
  });

  testWidgets('surfaces an error when revoking fails', (tester) async {
    final controller = _FakeMembersController(
      MembersState(members: const [], invitations: [_invitation()]),
      onRevoke: (invitationId) async {
        throw const ApiException(
          statusCode: 404,
          code: 'resource.not_found',
          detail: 'invitation is no longer pending',
        );
      },
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('revoke-invitation-inv-1')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('invitation is no longer pending'),
      findsOneWidget,
    );
  });

  testWidgets('an accepted invitation has no revoke action', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeMembersController(
          MembersState(
            members: const [],
            invitations: [_invitation(status: 'accepted')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('revoke-invitation-inv-1')), findsNothing);
  });
}
