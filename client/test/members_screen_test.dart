import 'dart:async';

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
  String role = 'user',
  String status = 'pending',
}) => Invitation(
  id: id,
  email: email,
  role: role,
  status: status,
  createdAt: DateTime.utc(2026, 1, 1),
);

/// A fake controller so tests drive [MembersScreen] without a real
/// [ApiClient]/network call, matching organization_screen_test.dart's
/// override-providers-not-network convention.
class _FakeMembersController extends MembersController {
  _FakeMembersController(
    this._initial, {
    this.onInvite,
    this.onRevoke,
    this.onLoadMoreMembers,
    this.onLoadMoreInvitations,
  });

  final MembersState _initial;
  final Future<void> Function({required String email, String role})? onInvite;
  final Future<void> Function(String invitationId)? onRevoke;

  /// Test-only seams for the "load more" pagination actions — the real
  /// implementations need `organizationProvider`/a real repository, neither
  /// of which this widget test's `ProviderScope` wires up (matching
  /// [onInvite]/[onRevoke]'s same reasoning). Never exercised unless a test
  /// both sets a `*NextCursor` on the initial state *and* supplies the
  /// matching callback, so leaving one of these null is safe as long as the
  /// fixture's cursor stays null (the default).
  final Future<void> Function()? onLoadMoreMembers;
  final Future<void> Function()? onLoadMoreInvitations;

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

  @override
  Future<void> loadMoreMembers() async {
    if (onLoadMoreMembers != null) {
      await onLoadMoreMembers!();
      return;
    }
    await super.loadMoreMembers();
  }

  @override
  Future<void> loadMoreInvitations() async {
    if (onLoadMoreInvitations != null) {
      await onLoadMoreInvitations!();
      return;
    }
    await super.loadMoreInvitations();
  }
}

/// A controller whose `build()` fails, so tests can drive [MembersScreen]'s
/// `error:` branch (HIGH finding: previously untested — every other test
/// used a controller whose `build()` always succeeds).
class _ThrowingMembersController extends MembersController {
  @override
  Future<MembersState> build() async {
    throw const ApiException(
      statusCode: 403,
      code: 'forbidden',
      detail: 'only an organization admin may perform this action',
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

  // HIGH finding: members_screen.dart's invite field had no client-side
  // format validation at all (unlike account_screen.dart's
  // profileEmailInvalid check) — a malformed value used to sail straight
  // through to a server round trip.
  testWidgets('validates a malformed invite email client-side', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeMembersController(
          const MembersState(members: [], invitations: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('invite-email-field')), 'nope');
    await tester.tap(find.byKey(const Key('invite-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid email address.'), findsOneWidget);
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

  // HIGH finding: revoke had no busy/disabled state, so a double-tap could
  // fire duplicate DELETE requests.
  testWidgets(
    'disables the revoke action and shows a spinner while the request is '
    'in flight, and ignores a second tap',
    (tester) async {
      final completer = Completer<void>();
      var revokeCallCount = 0;
      final controller = _FakeMembersController(
        MembersState(members: const [], invitations: [_invitation()]),
        onRevoke: (invitationId) {
          revokeCallCount++;
          return completer.future;
        },
      );
      await tester.pumpWidget(_buildScreen(controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('revoke-invitation-inv-1')));
      await tester.pump();

      final button = tester.widget<IconButton>(
        find.byKey(const Key('revoke-invitation-inv-1')),
      );
      expect(
        button.onPressed,
        isNull,
        reason: 'disabled while the revoke request is in flight',
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // A second tap while busy must not fire a second request — the
      // IconButton is disabled (onPressed null) so this is a no-op tap.
      await tester.tap(
        find.byKey(const Key('revoke-invitation-inv-1')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(revokeCallCount, 1);

      completer.complete();
      await tester.pumpAndSettle();

      expect(find.text('Invitation revoked.'), findsOneWidget);
    },
  );

  // HIGH finding: MembersScreen's error/loading state was untested — every
  // existing test used a controller whose build() always succeeds.
  testWidgets(
    'renders the load error and hides the members/invite UI on a 403',
    (tester) async {
      await tester.pumpWidget(_buildScreen(_ThrowingMembersController()));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not load members'), findsOneWidget);
      expect(find.byKey(const Key('invite-email-field')), findsNothing);
      expect(find.byKey(const Key('invite-submit-button')), findsNothing);
      expect(find.text('Members'), findsNothing);
      expect(find.text('Invitations'), findsNothing);
    },
  );

  // MEDIUM finding: member/invitation role and status were hardcoded,
  // untranslated raw values ('admin · active') instead of localized text.
  testWidgets('localizes a member\'s role and status', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeMembersController(
          MembersState(
            members: [
              _member(userId: 'admin-1', role: 'admin', status: 'active'),
            ],
            invitations: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Admin · Active'), findsOneWidget);
    expect(find.text('admin · active'), findsNothing);
  });

  testWidgets('localizes an invitation\'s role and status', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeMembersController(
          MembersState(
            members: const [],
            invitations: [_invitation(role: 'user', status: 'pending')],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Member · Pending'), findsOneWidget);
    expect(find.text('user · pending'), findsNothing);
  });

  // MEDIUM finding: the back button lacked a tooltip/semantic label, unlike
  // the app shell's own back button.
  testWidgets('the back button has a tooltip/semantic label', (tester) async {
    await tester.pumpWidget(
      _buildScreen(
        _FakeMembersController(
          const MembersState(members: [], invitations: []),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final button = tester.widget<IconButton>(
      find.byKey(const Key('members-back-button')),
    );
    expect(button.tooltip, isNotNull);
    expect(button.tooltip, isNotEmpty);
  });

  // MEDIUM finding: the lists had no client-side pagination even though the
  // server implements cursor pagination (limit/cursor/page.next_cursor) —
  // data past the first page was silently hidden.
  group('pagination (load more)', () {
    testWidgets(
      'shows a load-more action for members when there is a next page, '
      'and fetches it on tap',
      (tester) async {
        var called = false;
        final controller = _FakeMembersController(
          MembersState(
            members: [_member(userId: 'user-1')],
            invitations: const [],
            membersNextCursor: 'cursor-1',
          ),
          onLoadMoreMembers: () async {
            called = true;
          },
        );
        await tester.pumpWidget(_buildScreen(controller));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('members-load-more-button')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('members-load-more-button')));
        await tester.pumpAndSettle();

        expect(called, isTrue);
      },
    );

    testWidgets('hides the members load-more action once there is no '
        'further page', (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          _FakeMembersController(
            MembersState(members: [_member()], invitations: const []),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('members-load-more-button')), findsNothing);
    });

    testWidgets(
      'shows a load-more action for invitations when there is a next page, '
      'and fetches it on tap',
      (tester) async {
        var called = false;
        final controller = _FakeMembersController(
          MembersState(
            members: const [],
            invitations: [_invitation()],
            invitationsNextCursor: 'cursor-1',
          ),
          onLoadMoreInvitations: () async {
            called = true;
          },
        );
        await tester.pumpWidget(_buildScreen(controller));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('invitations-load-more-button')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('invitations-load-more-button')));
        await tester.pumpAndSettle();

        expect(called, isTrue);
      },
    );

    testWidgets('hides the invitations load-more action once there is no '
        'further page', (tester) async {
      await tester.pumpWidget(
        _buildScreen(
          _FakeMembersController(
            MembersState(members: const [], invitations: [_invitation()]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('invitations-load-more-button')),
        findsNothing,
      );
    });
  });
}
