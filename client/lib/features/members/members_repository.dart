import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../organization/organization_repository.dart';

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
  });

  factory Invitation.fromJson(Map<String, dynamic> json) => Invitation(
    id: json['id'] as String,
    email: json['email'] as String? ?? '',
    role: json['role'] as String? ?? 'user',
    status: json['status'] as String? ?? 'pending',
    createdAt: DateTime.parse(json['created_at'] as String),
  );

  final String id;
  final String email;
  final String role;
  final String status;
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
      if (cursor != null) 'cursor': cursor,
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
  Future<void> invite({required String email, String role = 'user'}) async {
    final orgId = _requireOrgId();
    final repo = ref.read(membersRepositoryProvider);
    await repo.invite(orgId, email: email, role: role);
    ref.invalidateSelf();
    await future;
  }

  /// Revokes a pending invitation and refreshes (first page).
  Future<void> revokeInvitation(String invitationId) async {
    final orgId = _requireOrgId();
    final repo = ref.read(membersRepositoryProvider);
    await repo.revokeInvitation(orgId, invitationId);
    ref.invalidateSelf();
    await future;
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
