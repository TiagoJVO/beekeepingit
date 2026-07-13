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

/// Reads members and manages email invitations for the caller's own
/// organization (admin-only server-side, auth.md §5.3). Unlike apiaries,
/// this is a direct, online-only REST surface — membership/invitation
/// management is an admin-app-style action, not a field-recorded,
/// offline-first entity (sync.md: "invitations — an online admin flow, not a
/// field entity").
class MembersRepository {
  MembersRepository(this._api);

  final ApiClient _api;

  Future<List<Member>> listMembers(String orgId) async {
    final json = await _api.getJson('/organizations/$orgId/members');
    final data = json['data'] as List<dynamic>? ?? [];
    return data.map((e) => Member.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<List<Invitation>> listInvitations(String orgId) async {
    final json = await _api.getJson('/organizations/$orgId/invitations');
    final data = json['data'] as List<dynamic>? ?? [];
    return data
        .map((e) => Invitation.fromJson(e as Map<String, dynamic>))
        .toList();
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
}

final membersRepositoryProvider = Provider<MembersRepository>((ref) {
  return MembersRepository(ref.watch(apiClientProvider));
});

/// Members + invitations for the caller's own organization, refetched
/// together since the admin screen shows both lists. `null` org (not yet
/// onboarded) yields empty lists rather than erroring — this screen is only
/// reachable once org onboarding is done, but stays defensive.
class MembersState {
  const MembersState({required this.members, required this.invitations});

  final List<Member> members;
  final List<Invitation> invitations;
}

class MembersController extends AsyncNotifier<MembersState> {
  @override
  Future<MembersState> build() async {
    final org = await ref.watch(organizationProvider.future);
    if (org == null) return const MembersState(members: [], invitations: []);
    final repo = ref.watch(membersRepositoryProvider);
    final members = await repo.listMembers(org.id);
    final invitations = await repo.listInvitations(org.id);
    return MembersState(members: members, invitations: invitations);
  }

  /// Invites [email] and refreshes both lists with the server's state.
  /// Rethrows on failure (e.g. [ApiException] for a 422/409) so the screen
  /// can surface the error.
  Future<void> invite({required String email, String role = 'user'}) async {
    final org = ref.read(organizationProvider).value;
    if (org == null) return;
    final repo = ref.read(membersRepositoryProvider);
    await repo.invite(org.id, email: email, role: role);
    ref.invalidateSelf();
    await future;
  }

  /// Revokes a pending invitation and refreshes.
  Future<void> revokeInvitation(String invitationId) async {
    final org = ref.read(organizationProvider).value;
    if (org == null) return;
    final repo = ref.read(membersRepositoryProvider);
    await repo.revokeInvitation(org.id, invitationId);
    ref.invalidateSelf();
    await future;
  }
}

final membersProvider = AsyncNotifierProvider<MembersController, MembersState>(
  MembersController.new,
);
