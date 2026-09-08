import 'dart:async';

import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/l10n/supported_locales.dart';
import 'package:beekeepingit_client/features/members/members_repository.dart';
import 'package:beekeepingit_client/features/members/members_screen.dart';
import 'package:beekeepingit_client/l10n/gen/app_localizations.dart';
import 'package:beekeepingit_client/theming/brand_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/a11y_matchers.dart';
import 'support/bottom_chrome.dart';

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

Widget _buildScreen(
  MembersController controller, {
  Map<String, String> memberNames = const {},
  Locale? locale,
}) {
  return ProviderScope(
    overrides: [
      membersProvider.overrideWith(() => controller),
      // The screen watches `memberNamesProvider` (#582) to resolve a member
      // id to a real name; the real provider would attempt a network fetch
      // this widget test never wires up — same override convention as
      // todo_detail_screen_test.dart / history_section_test.dart.
      memberNamesProvider.overrideWith((ref) async => memberNames),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: kSupportedLocales,
      locale: locale,
      home: const MembersScreen(),
    ),
  );
}

void main() {
  // #629 (FR-UX-1, FR-AX-1): the invite field floated its label while the
  // forms this screen sits beside wear theirs above. With the label above
  // the field, the Invite button moves under it rather than beside it —
  // sharing the row would align the button with the label, not the input.
  group('one field-label pattern (#629, FR-UX-1)', () {
    Future<void> pumpForm(WidgetTester tester) async {
      await tester.pumpWidget(
        _buildScreen(
          _FakeMembersController(
            MembersState(
              members: [_member(userId: 'admin-1', role: 'admin')],
              invitations: const [],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('the invite field paints no floating Material label', (
      tester,
    ) async {
      await pumpForm(tester);

      expectNoFloatingFieldLabels(tester, find.byType(Form));
    });

    testWidgets('its label sits above the field, via LabeledField', (
      tester,
    ) async {
      await pumpForm(tester);

      expect(
        find.descendant(
          of: find.byType(LabeledField),
          matching: find.text('Email to invite'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'the field keeps the accessible name its floating label used to give '
      'it, and the submit button keeps its own (FR-AX-1)',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pumpForm(tester);

        expectFieldAccessibleName(
          tester,
          const Key('invite-email-field'),
          'Email to invite',
        );
        expectHasSemanticsLabel(tester, const Key('invite-submit-button'));
        handle.dispose();
      },
    );
  });

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

  // #582 (FR-TEN-2, FR-ONB-1, NFR-I18N-1, FR-AX-1, D-18): the members list
  // printed the raw 36-character user UUID as a row's title and never read
  // the org roster at all — while every other feature (activities, todos,
  // history) resolves the SAME roster to a real display name and falls back
  // to a short id fragment, never the full id.
  group('member identity display (#582, FR-TEN-2)', () {
    const uuid = '3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d';

    Future<void> pumpMembers(
      WidgetTester tester, {
      Map<String, String> memberNames = const {},
      List<Invitation> invitations = const [],
      Locale? locale,
    }) async {
      await tester.pumpWidget(
        _buildScreen(
          _FakeMembersController(
            MembersState(
              members: [_member(userId: uuid, role: 'admin')],
              invitations: invitations,
            ),
          ),
          memberNames: memberNames,
          locale: locale,
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'a member in the roster renders their real display name, and the raw '
      'UUID appears nowhere on screen',
      (tester) async {
        await pumpMembers(tester, memberNames: const {uuid: 'Ana Silva'});

        expect(find.text('Ana Silva'), findsOneWidget);
        expect(find.text(uuid), findsNothing);
      },
    );

    testWidgets(
      'the row keeps its localized role/status subtitle beside the name',
      (tester) async {
        await pumpMembers(tester, memberNames: const {uuid: 'Ana Silva'});

        expect(find.text('Admin · Active'), findsOneWidget);
      },
    );

    testWidgets(
      'a member with no roster entry — an account predating profile seeding '
      '(#572), a provider emitting no name claim, or offline / '
      'pre-first-fetch — degrades to a short id fragment, not the full id',
      (tester) async {
        await pumpMembers(tester);

        expect(find.text('Member 2a3b4c5d'), findsOneWidget);
        expect(find.text(uuid), findsNothing);
      },
    );

    testWidgets('a blank roster name degrades the same way', (tester) async {
      await pumpMembers(tester, memberNames: const {uuid: '   '});

      expect(find.text('Member 2a3b4c5d'), findsOneWidget);
      expect(find.text(uuid), findsNothing);
    });

    testWidgets('the fallback is localized in PT (NFR-I18N-1)', (tester) async {
      await pumpMembers(tester, locale: const Locale('pt', 'PT'));

      expect(find.text('Membro 2a3b4c5d'), findsOneWidget);
      expect(find.text(uuid), findsNothing);
    });

    // FR-AX-1 / D-18: a screen reader reads the semantics tree, not the
    // painted glyphs — a name that only reached the pixels would still
    // announce a 36-character id, one character at a time.
    testWidgets('the screen reader announces the name, never the raw id', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpMembers(tester, memberNames: const {uuid: 'Ana Silva'});

      // A ListTile merges its title and subtitle into ONE node, so the
      // accessible name is the whole row — matched by pattern, not equality.
      final label = tester
          .getSemantics(find.byKey(const Key('member-$uuid')))
          .label;
      expect(label, contains('Ana Silva'));
      expect(label, isNot(contains(uuid)));
      handle.dispose();
    });

    // NFR-SEC-1 (security-review HIGH on #582): the roster name is authored
    // outside this app — seeded from the IdP claim, then writable by the
    // account owner through `PATCH /v1/profile`, which today only trims and
    // length-bounds it. The row must not render it verbatim. Full rule
    // coverage lives in member_display_test.dart; this pins the WIRING —
    // that the members list actually goes through the filter.
    testWidgets('a name carrying a bidi override renders sanitized', (
      tester,
    ) async {
      await pumpMembers(tester, memberNames: const {uuid: '\u202EAna Silva'});

      expect(find.text('Ana Silva'), findsOneWidget);
      expect(find.text('\u202EAna Silva'), findsNothing);
    });

    // The other half of #582's scope: an invitation has no user account yet,
    // so the invited address IS its only identity — it must keep reading as
    // a person's identifier beside a named member, not regress to an id.
    testWidgets(
      'an invitation still shows the invited email beside a named member',
      (tester) async {
        await pumpMembers(
          tester,
          memberNames: const {uuid: 'Ana Silva'},
          invitations: [_invitation()],
        );

        expect(find.text('Ana Silva'), findsOneWidget);
        expect(find.text('invitee@example.com'), findsOneWidget);
        expect(find.text('Member · Pending'), findsOneWidget);
      },
    );

    // D-18 / FR-AX-1: both lists carry outside-authored text as their row
    // title — a display name (up to 200 runes) and an email address (up to
    // 320 octets). Neither may grow its row without limit, and at 200% text
    // scale even an ordinary value needs the ellipsis. The two must agree, or
    // one list wraps while the other truncates on the same screen.
    testWidgets('both row titles are bounded identically (#582, D-18)', (
      tester,
    ) async {
      await pumpMembers(
        tester,
        memberNames: const {uuid: 'Ana Silva'},
        invitations: [_invitation()],
      );

      for (final text in const ['Ana Silva', 'invitee@example.com']) {
        final widget = tester.widget<Text>(find.text(text));
        expect(widget.maxLines, 2, reason: '"$text" is unbounded');
        expect(widget.overflow, TextOverflow.ellipsis, reason: text);
      }
    });
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
          detail: 'this email already has a pending invitation to this organization',
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

  // #750 (FR-AX-1, D-18): a 422 that names the `email` field is rendered
  // under the field rather than in a snackbar, so — unlike the 409 above —
  // it never passes through `Form.validate()` and the SDK's own
  // announcement path never sees it. It has to carry the live region
  // itself, AND mark the field invalid, or a screen-reader user gets a red
  // rectangle and an `aria-invalid="false"` field.
  testWidgets('a mocked 422 email field error is announced and marks the '
      'field invalid', (tester) async {
    final handle = tester.ensureSemantics();
    final controller = _FakeMembersController(
      const MembersState(members: [], invitations: []),
      onInvite: ({required email, role = 'user'}) async {
        throw const ApiException(
          statusCode: 422,
          code: 'validation.failed',
          detail: 'one or more fields are invalid',
          fieldErrors: [
            ApiFieldError(
              field: 'email',
              code: 'not_allowed',
              message: 'that domain is not allowed',
            ),
          ],
        );
      },
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('invite-email-field')),
      'blocked@example.com',
    );
    await tester.tap(find.byKey(const Key('invite-submit-button')));
    await tester.pumpAndSettle();

    expect(find.text('that domain is not allowed'), findsOneWidget);
    expectLiveRegion(tester, find.text('that domain is not allowed'));
    // The message only — the field's name is already announced by its own
    // node and must not be folded in a second time (#629).
    expect(
      tester.getSemantics(find.text('that domain is not allowed')).label,
      'that domain is not allowed',
    );
    expect(
      tester
          .getSemantics(find.byKey(const Key('invite-email-field')))
          .getSemanticsData()
          .validationResult,
      SemanticsValidationResult.invalid,
    );
    handle.dispose();
  });

  // The counterpart: `forceErrorText` makes the field genuinely invalid, so
  // `Form.validate()` returns false while the server's verdict stands. The
  // verdict must therefore be dropped the moment the user edits the address
  // it judged (#649's rule) — otherwise the invite button is dead for the
  // rest of the session (#750).
  testWidgets('editing the email after a 422 lets the next invite through '
      '(#750, #649)', (tester) async {
    var invites = 0;
    final controller = _FakeMembersController(
      const MembersState(members: [], invitations: []),
      onInvite: ({required email, role = 'user'}) async {
        invites++;
        if (invites == 1) {
          throw const ApiException(
            statusCode: 422,
            code: 'validation.failed',
            detail: 'one or more fields are invalid',
            fieldErrors: [
              ApiFieldError(
                field: 'email',
                code: 'not_allowed',
                message: 'that domain is not allowed',
              ),
            ],
          );
        }
      },
    );
    await tester.pumpWidget(_buildScreen(controller));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('invite-email-field')),
      'blocked@example.com',
    );
    await tester.tap(find.byKey(const Key('invite-submit-button')));
    await tester.pumpAndSettle();
    expect(invites, 1);
    expect(find.text('that domain is not allowed'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('invite-email-field')),
      'ok@example.com',
    );
    await tester.pumpAndSettle();
    expect(find.text('that domain is not allowed'), findsNothing);

    await tester.tap(find.byKey(const Key('invite-submit-button')));
    await tester.pumpAndSettle();
    expect(invites, 2);
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

  // #640 (FR-UX-1, FR-ONB-3): `showSnackBar` queues, so a second action taken
  // inside the first toast's 4s life leaves the first message on screen and
  // parks the second behind it — the toast reads one action behind. This
  // screen is where the report came from: invite, then revoke, and the bar
  // still says "Invitation sent."
  testWidgets(
    'revoking right after inviting shows the revoke confirmation, not the '
    'invite one (#640)',
    (tester) async {
      final controller = _FakeMembersController(
        MembersState(members: const [], invitations: [_invitation()]),
        // A no-op invite so the seeded invitation list stays as it is: the
        // default seam appends a second row carrying the same `inv-1` id,
        // which would make the revoke key ambiguous.
        onInvite: ({required email, role = 'user'}) async {},
      );
      await tester.pumpWidget(_buildScreen(controller));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('invite-email-field')),
        'new@example.com',
      );
      await tester.tap(find.byKey(const Key('invite-submit-button')));
      // Timed pumps, not `pumpAndSettle`: the invite toast has to still be
      // on screen when the next action arrives, which is the whole
      // precondition of the bug.
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.text('Invitation sent.'),
        findsOneWidget,
        reason: 'precondition: the invite toast is still on screen',
      );

      await tester.tap(find.byKey(const Key('revoke-invitation-inv-1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));

      // The exact English copy of `membersRevokeSuccess` /
      // `membersInviteSuccess` (lib/l10n/arb/app_en.arb).
      expect(
        find.text('Invitation revoked.'),
        findsOneWidget,
        reason: 'the toast reports the action the user just took',
      );
      expect(
        find.text('Invitation sent.'),
        findsNothing,
        reason:
            'the superseded confirmation is gone, not still occupying '
            'the bar',
      );
    },
  );

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

  // #773 (FR-UX-2, FR-AX-1): this screen raises five toasts of its own
  // (invite sent, invite failed, invitation revoked, …) over a scroll view
  // that reserved nothing at the bottom, so a confirmation landed on the very
  // row it was confirming. It is outside the shell — no bottom navigation and
  // no FAB — so the band it needs is the toast's own height, which is exactly
  // what `#631` sized `scrollBottomInset` to.
  group('the bottom chrome band (#773, FR-UX-2)', () {
    for (final textScale in [1.0, 2.0]) {
      testWidgets(
        'a toast does not cover the last invitation row, at ${textScale}x '
        'text',
        (tester) async {
          useFieldPhone(tester, textScale: textScale);
          await tester.pumpWidget(
            _buildScreen(
              _FakeMembersController(
                MembersState(
                  members: [_member(userId: 'admin-1', role: 'admin')],
                  invitations: [
                    for (var i = 0; i < 6; i++)
                      _invitation(id: 'inv-$i', email: 'invitee$i@example.com'),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          await scrollToEnd(tester, find.byType(SingleChildScrollView));

          // `membersInviteSuccess` — the copy this screen actually shows on
          // a successful invite (app_en.arb).
          await showToast(tester, message: 'Invitation sent.');

          expectToastClearsLastRow(
            tester,
            find.byKey(const Key('invitation-inv-5')),
            reason:
                'the invite/revoke toast must land in the band the list '
                'reserves, not on the invitation it is reporting on',
          );
        },
      );
    }
  });
}
