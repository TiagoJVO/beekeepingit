import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../organization/organization_repository.dart';
import 'member_display.dart';

/// An organization member
/// (contracts/openapi/organizations.openapi.yaml's Member schema, #27).
class Member {
  const Member({
    required this.userId,
    required this.role,
    required this.status,
  });

  factory Member.fromJson(Map<String, dynamic> json) => Member(
    userId: json['user_id'] as String,
    role: json['role'] as String? ?? 'user',
    status: json['status'] as String? ?? 'active',
  );

  final String userId;
  final String role;
  final String status;
}

/// A member's display name
/// (contracts/openapi/organizations.openapi.yaml's MemberName schema, #44
/// follow-up) — `user_id` -> `name` only, no role/status/email. Backs
/// per-user attribution display (FR-TEN-2): resolving an activity's
/// `performed_by` id to a real name instead of a short id fragment.
class MemberName {
  const MemberName({required this.userId, required this.name});

  factory MemberName.fromJson(Map<String, dynamic> json) => MemberName(
    userId: json['user_id'] as String,
    name: json['name'] as String? ?? '',
  );

  final String userId;
  final String name;
}

/// A pending (or resolved) email invitation
/// (contracts/openapi/organizations.openapi.yaml's Invitation schema, #27,
/// FR-ONB-3, D-3).
class Invitation {
  const Invitation({
    required this.id,
    required this.email,
    required this.role,
    required this.status,
    required this.createdAt,
    this.deliveryStatus = 'pending',
    this.deliveryError = '',
    this.lastDeliveryAt,
  });

  factory Invitation.fromJson(Map<String, dynamic> json) => Invitation(
    id: json['id'] as String,
    email: json['email'] as String? ?? '',
    role: json['role'] as String? ?? 'user',
    status: json['status'] as String? ?? 'pending',
    deliveryStatus: json['delivery_status'] as String? ?? 'pending',
    deliveryError: json['delivery_error'] as String? ?? '',
    lastDeliveryAt: switch (json['last_delivery_at']) {
      final String at => DateTime.tryParse(at),
      _ => null,
    },
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  final String id;
  final String email;
  final String role;

  /// The invitation's LIFECYCLE — what the invitee did with it
  /// (`pending`/`accepted`/`expired`/`revoked`).
  final String status;

  /// What the invitation EMAIL did (#641): `pending`, `sent` or `failed`.
  /// Independent of [status] — an invitation can be accepted whether or not
  /// its email ever arrived, and (before #641) `status` alone said `pending`
  /// forever for a message that was never sent at all.
  final String deliveryStatus;

  /// Short, stable failure code for a `failed` delivery (`not_configured`,
  /// `rejected`, `relay_unavailable`, `render_failed`, `never_sent`) — the
  /// server never sends a message here, the client localizes the code.
  final String deliveryError;

  /// When the last send attempt finished, or null if none ever has.
  final DateTime? lastDeliveryAt;

  final DateTime createdAt;
}

/// One page of a cursor-paginated list response
/// (contracts/openapi/organizations.openapi.yaml's shared `page` envelope:
/// `limit`/`cursor` request params, `page.next_cursor` response field —
/// same shape apiaries' own server-side pagination uses). [nextCursor] is
/// `null` once the last page has been read.
class MembersPage<T> {
  const MembersPage({required this.items, required this.nextCursor});

  final List<T> items;
  final String? nextCursor;
}

/// Reads members and manages email invitations for the caller's own
/// organization (admin-only server-side, auth.md §5.3). Unlike apiaries,
/// this is a direct, online-only REST surface — membership/invitation
/// management is an admin-app-style action, not a field-recorded,
/// offline-first entity (sync.md: "invitations — an online admin flow, not a
/// field entity").
class MembersRepository {
  MembersRepository(this._api);

  final ApiClient _api;

  Future<MembersPage<Member>> listMembers(
    String orgId, {
    String? cursor,
    int? limit,
  }) async {
    final json = await _api.getJson(
      _pagedPath('/organizations/$orgId/members', cursor: cursor, limit: limit),
    );
    return _page(json, Member.fromJson);
  }

  Future<MembersPage<Invitation>> listInvitations(
    String orgId, {
    String? cursor,
    int? limit,
  }) async {
    final json = await _api.getJson(
      _pagedPath(
        '/organizations/$orgId/invitations',
        cursor: cursor,
        limit: limit,
      ),
    );
    return _page(json, Invitation.fromJson);
  }

  /// Fetches the org's full member-name roster (all pages) as a
  /// `user_id -> display name` map, for resolving per-user attribution (#44,
  /// FR-TEN-2). Unlike [listMembers] (admin-only server-side), the
  /// `/members/names` endpoint is readable by ANY active member, so this
  /// works for a plain user too. Every name is put through
  /// [sanitizedMemberName] (#582), and a member left with nothing readable —
  /// an empty name, a whitespace-only one, or one that was nothing but
  /// invisible codepoints — is omitted, so the caller falls back to a short
  /// id fragment rather than showing a blank (or a forged) attribution.
  Future<Map<String, String>> listMemberNames(String orgId) async {
    final names = <String, String>{};
    String? cursor;
    do {
      final json = await _api.getJson(
        _pagedPath('/organizations/$orgId/members/names', cursor: cursor),
      );
      final page = _page(json, MemberName.fromJson);
      for (final m in page.items) {
        // Sanitized on the way IN (#582, NFR-SEC-1): a name is authored
        // outside this app, and one that is blank, whitespace-only, or
        // nothing but invisible codepoints must never reach a caller — every
        // consumer's "no name available" branch then covers all three the
        // same way.
        //
        // The render sites (activity_display, history_display, todo_display,
        // todo_assignee_picker_field, member_display's memberIdentityLabel)
        // sanitize AGAIN, deliberately — not because this call is
        // insufficient. Each of those is a public function over a
        // caller-supplied `Map<String, String>`, so it cannot know its
        // argument came through here; a test, a future second reader of
        // `/members/names`, or an admin-app port would otherwise get an
        // unfiltered name with no compile-time warning. `sanitizedMemberName`
        // is idempotent and cheap, so the second pass costs a rune scan and
        // buys the guarantee at the boundary that actually renders.
        final name = sanitizedMemberName(m.name);
        if (name != null) names[m.userId] = name;
      }
      cursor = page.nextCursor;
    } while (cursor != null);
    return names;
  }

  Future<Invitation> invite(
    String orgId, {
    required String email,
    String role = 'user',
  }) async {
    final json = await _api.postJson('/organizations/$orgId/invitations', {
      'email': email,
      'role': role,
    });
    return Invitation.fromJson(json);
  }

  Future<void> revokeInvitation(String orgId, String invitationId) async {
    await _api.deleteJson('/organizations/$orgId/invitations/$invitationId');
  }

  /// Asks the server to attempt the invitation email again (#641,
  /// `POST .../invitations/{id}/resend`) and returns the invitation with the
  /// outcome of that attempt. The request has no body: this is an action, not
  /// an edit — nothing about the invitation itself changes.
  Future<Invitation> resendInvitation(String orgId, String invitationId) async {
    final json = await _api.postJson(
      '/organizations/$orgId/invitations/$invitationId/resend',
      const <String, dynamic>{},
    );
    return Invitation.fromJson(json);
  }

  static MembersPage<T> _page<T>(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final data = json['data'] as List<dynamic>? ?? [];
    final page = json['page'] as Map<String, dynamic>? ?? const {};
    return MembersPage(
      items: data.map((e) => fromJson(e as Map<String, dynamic>)).toList(),
      nextCursor: page['next_cursor'] as String?,
    );
  }

  /// Appends `limit`/`cursor` query params (server: `parsePage`,
  /// api/invitations.go) only when given — an unpaginated first fetch omits
  /// them entirely and gets the server's own default page size.
  static String _pagedPath(String path, {String? cursor, int? limit}) {
    final params = <String, String>{
      if (limit != null) 'limit': '$limit',
      'cursor': ?cursor,
    };
    if (params.isEmpty) return path;
    final query = params.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    return '$path?$query';
  }
}

final membersRepositoryProvider = Provider<MembersRepository>((ref) {
  return MembersRepository(ref.watch(apiClientProvider));
});

/// The caller's org member-name lookup (`user_id -> display name`), for
/// resolving per-user activity attribution to a real name (#44,
/// activity_display.dart's `activityAttributionText`). Online-fetch +
/// session cache, matching [MembersRepository]'s online-only stance (member
/// data is not a synced, offline-first entity — sync.md): offline, or before
/// the first successful fetch, this resolves to an empty map and attribution
/// degrades to a short id fragment rather than erroring.
///
/// Best-effort by design: a not-yet-onboarded (`null` org) state or any fetch
/// failure yields an empty map, so a name-lookup problem never turns the
/// offline-first activities list into an error screen — attribution simply
/// falls back. Re-fetched when the org changes (e.g. after onboarding).
final memberNamesProvider = FutureProvider<Map<String, String>>((ref) async {
  final org = await ref.watch(organizationProvider.future);
  if (org == null) return const {};
  try {
    return await ref.watch(membersRepositoryProvider).listMemberNames(org.id);
  } on ApiException {
    return const {};
  } on ApiNetworkException {
    return const {};
  }
});

/// Members + invitations for the caller's own organization, refetched
/// together since the admin screen shows both lists. `null` org (not yet
/// onboarded) yields empty lists rather than erroring — this screen is only
/// reachable once org onboarding is done, but stays defensive.
///
/// Each list carries its own `*NextCursor` (cursor pagination, MEDIUM
/// finding: the server implements `limit`/`cursor`/`page.next_cursor` but
/// the client used to ignore it, silently hiding anything past the server's
/// default page size) — `null` once that list has no further page.
class MembersState {
  const MembersState({
    required this.members,
    required this.invitations,
    this.membersNextCursor,
    this.invitationsNextCursor,
  });

  final List<Member> members;
  final List<Invitation> invitations;
  final String? membersNextCursor;
  final String? invitationsNextCursor;
}

class MembersController extends AsyncNotifier<MembersState> {
  @override
  Future<MembersState> build() async {
    final org = await ref.watch(organizationProvider.future);
    if (org == null) return const MembersState(members: [], invitations: []);
    final repo = ref.watch(membersRepositoryProvider);
    final membersPage = await repo.listMembers(org.id);
    final invitationsPage = await repo.listInvitations(org.id);
    return MembersState(
      members: membersPage.items,
      invitations: invitationsPage.items,
      membersNextCursor: membersPage.nextCursor,
      invitationsNextCursor: invitationsPage.nextCursor,
    );
  }

  /// The caller's org id, or a thrown [StateError] if there is none.
  ///
  /// Previously this whole method (and [revokeInvitation]/[loadMoreMembers]/
  /// [loadMoreInvitations]) returned silently when there was no
  /// organization, which reads to the caller as "request succeeded, nothing
  /// changed" — actually a bug swallowed on a screen that's only reachable
  /// once org onboarding is done, so hitting this path at all means
  /// something is already wrong. Throwing lets the screen's existing
  /// catch-all error path (membersInviteError) surface it truthfully instead
  /// of a silent no-op (MEDIUM finding).
  String _requireOrgId() {
    final org = ref.read(organizationProvider).value;
    if (org == null) throw StateError('no organization');
    return org.id;
  }

  /// Invites [email] and refreshes both lists (first page) with the
  /// server's state. Rethrows on failure (e.g. [ApiException] for a
  /// 422/409) so the screen can surface the error.
  ///
  /// Returns the created invitation so the screen can report what actually
  /// happened (#641): the server commits the invitation and then attempts its
  /// email, so a `201` can still carry `delivery_status: failed`. Announcing
  /// "Invitation sent." unconditionally would be the same lie this issue is
  /// about, one screen further along.
  Future<Invitation> invite({
    required String email,
    String role = 'user',
  }) async {
    final orgId = _requireOrgId();
    final repo = ref.read(membersRepositoryProvider);
    final created = await repo.invite(orgId, email: email, role: role);
    ref.invalidateSelf();
    await future;
    return created;
  }

  /// Revokes a pending invitation and refreshes (first page).
  Future<void> revokeInvitation(String invitationId) async {
    final orgId = _requireOrgId();
    final repo = ref.read(membersRepositoryProvider);
    await repo.revokeInvitation(orgId, invitationId);
    ref.invalidateSelf();
    await future;
  }

  /// Retries the invitation email and refreshes both lists so the row shows
  /// the new delivery state (#641 AC: a failed send is retryable). Returns the
  /// attempt's outcome so the screen can tell the admin whether THIS try
  /// worked, rather than only silently redrawing the list. Rethrows on
  /// failure (e.g. an [ApiException] for the 429 cooldown) so the screen can
  /// surface it.
  Future<Invitation> resendInvitation(String invitationId) async {
    final orgId = _requireOrgId();
    final repo = ref.read(membersRepositoryProvider);
    final updated = await repo.resendInvitation(orgId, invitationId);
    ref.invalidateSelf();
    await future;
    return updated;
  }

  /// Fetches the next page of members and appends it to the current list —
  /// a no-op if there is no further page (e.g. a stale double-tap after the
  /// button's already been hidden).
  Future<void> loadMoreMembers() async {
    final current = state.value;
    if (current == null || current.membersNextCursor == null) return;
    final orgId = _requireOrgId();
    final repo = ref.read(membersRepositoryProvider);
    final page = await repo.listMembers(
      orgId,
      cursor: current.membersNextCursor,
    );
    state = AsyncData(
      MembersState(
        members: [...current.members, ...page.items],
        invitations: current.invitations,
        membersNextCursor: page.nextCursor,
        invitationsNextCursor: current.invitationsNextCursor,
      ),
    );
  }

  /// Fetches the next page of invitations and appends it — same shape as
  /// [loadMoreMembers].
  Future<void> loadMoreInvitations() async {
    final current = state.value;
    if (current == null || current.invitationsNextCursor == null) return;
    final orgId = _requireOrgId();
    final repo = ref.read(membersRepositoryProvider);
    final page = await repo.listInvitations(
      orgId,
      cursor: current.invitationsNextCursor,
    );
    state = AsyncData(
      MembersState(
        members: current.members,
        invitations: [...current.invitations, ...page.items],
        membersNextCursor: current.membersNextCursor,
        invitationsNextCursor: page.nextCursor,
      ),
    );
  }
}

final membersProvider = AsyncNotifierProvider<MembersController, MembersState>(
  MembersController.new,
);
