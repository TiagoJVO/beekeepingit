import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/validation/email.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import 'members_repository.dart';

/// Admin-only organization members + invitations screen (FR-ONB-3, D-3,
/// NFR-ROL-1, #27). Server-side authorization is the real gate (auth.md
/// §5.3: member/invitation endpoints are admin-only, 403 for a plain user) —
/// this screen doesn't hide itself from non-admins client-side, it just
/// surfaces the 403 as an error state if a non-admin somehow navigates here.
class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({super.key});

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _inviting = false;
  String? _emailError;

  /// Ids of pending invitations currently mid-revoke — guards the revoke
  /// action with a busy/disabled state (HIGH finding: previously nothing
  /// stopped a double-tap from firing duplicate DELETE requests, unlike
  /// `_inviting`'s equivalent guard on the invite button).
  final Set<String> _revokingIds = {};

  bool _loadingMoreMembers = false;
  bool _loadingMoreInvitations = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _invite(AppLocalizations l10n) async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _inviting = true;
      _emailError = null;
    });
    try {
      await ref
          .read(membersProvider.notifier)
          .invite(email: _emailController.text.trim());
      if (!mounted) return;
      _emailController.clear();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.membersInviteSuccess)));
    } on ApiException catch (e) {
      if (!mounted) return;
      final fieldErrors = {
        for (final fe in e.fieldErrors) fe.field: fe.message,
      };
      if (fieldErrors.containsKey('email')) {
        setState(() => _emailError = fieldErrors['email']);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.membersInviteError(e.detail))),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.membersInviteError('$e'))));
    } finally {
      if (mounted) setState(() => _inviting = false);
    }
  }

  Future<void> _revoke(String invitationId, AppLocalizations l10n) async {
    if (_revokingIds.contains(invitationId)) return;
    setState(() => _revokingIds.add(invitationId));
    try {
      await ref.read(membersProvider.notifier).revokeInvitation(invitationId);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.membersRevokeSuccess)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.membersInviteError('$e'))));
    } finally {
      if (mounted) setState(() => _revokingIds.remove(invitationId));
    }
  }

  Future<void> _loadMoreMembers(AppLocalizations l10n) async {
    setState(() => _loadingMoreMembers = true);
    try {
      await ref.read(membersProvider.notifier).loadMoreMembers();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.membersInviteError('$e'))));
    } finally {
      if (mounted) setState(() => _loadingMoreMembers = false);
    }
  }

  Future<void> _loadMoreInvitations(AppLocalizations l10n) async {
    setState(() => _loadingMoreInvitations = true);
    try {
      await ref.read(membersProvider.notifier).loadMoreInvitations();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.membersInviteError('$e'))));
    } finally {
      if (mounted) setState(() => _loadingMoreInvitations = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(membersProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('members-back-button'),
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => context.go('/apiaries'),
        ),
        title: Text(l10n.membersTitle),
      ),
      body: state.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(l10n.membersLoadError('$err')),
          ),
        ),
        data: (data) => SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Form(
                key: _formKey,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextFormField(
                        key: const Key('invite-email-field'),
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: InputDecoration(
                          labelText: l10n.membersInviteEmailLabel,
                          border: const OutlineInputBorder(),
                          errorText: _emailError,
                        ),
                        validator: (v) {
                          final value = (v ?? '').trim();
                          if (value.isEmpty) {
                            return l10n.membersInviteEmailRequired;
                          }
                          if (!looksLikeEmail(value)) {
                            return l10n.membersInviteEmailInvalid;
                          }
                          return null;
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Not full-width (unlike the other screens' primary
                    // actions): this button shares its row with the email
                    // field rather than owning the whole form width. Still
                    // gets the same 44+ tap-target height (#79/#80) — this
                    // previously had no explicit minimumSize at all, silently
                    // sized to Material 3's 40px default.
                    PrimaryActionButton(
                      key: const Key('invite-submit-button'),
                      label: l10n.membersInviteButton,
                      busy: _inviting,
                      fullWidth: false,
                      onPressed: () => _invite(l10n),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
              Text(
                l10n.membersSectionTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (data.members.isEmpty)
                Text(l10n.membersEmpty)
              else
                ...data.members.map((m) => _MemberTile(member: m)),
              // Cursor-pagination "load more" (MEDIUM finding: the server
              // implements limit/cursor/page.next_cursor but the client used
              // to ignore it, silently hiding anything past the server's
              // default page size).
              if (data.membersNextCursor != null) ...[
                const SizedBox(height: 8),
                SecondaryActionButton(
                  key: const Key('members-load-more-button'),
                  label: l10n.membersLoadMoreButton,
                  busy: _loadingMoreMembers,
                  onPressed: () => _loadMoreMembers(l10n),
                ),
              ],
              const SizedBox(height: 32),
              Text(
                l10n.invitationsSectionTitle,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (data.invitations.isEmpty)
                Text(l10n.invitationsEmpty)
              else
                ...data.invitations.map(
                  (inv) => _InvitationTile(
                    invitation: inv,
                    revoking: _revokingIds.contains(inv.id),
                    onRevoke: () => _revoke(inv.id, l10n),
                  ),
                ),
              if (data.invitationsNextCursor != null) ...[
                const SizedBox(height: 8),
                SecondaryActionButton(
                  key: const Key('invitations-load-more-button'),
                  label: l10n.membersLoadMoreButton,
                  busy: _loadingMoreInvitations,
                  onPressed: () => _loadMoreInvitations(l10n),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Maps a raw membership/invitation `role` value (organizations migrations
/// 00001/00002: `role IN ('admin', 'user')`, shared by both) to its
/// localized display label. An unrecognized value falls back to the raw
/// string rather than crashing, defensive against a future server-added role
/// the client doesn't know about yet.
String _roleLabel(AppLocalizations l10n, String role) => switch (role) {
  'admin' => l10n.memberRoleAdmin,
  'user' => l10n.memberRoleUser,
  _ => role,
};

/// Maps a raw membership `status` value (organizations migration 00001:
/// `status IN ('active', 'invited', 'removed')`) to its localized label.
String _memberStatusLabel(AppLocalizations l10n, String status) =>
    switch (status) {
      'active' => l10n.memberStatusActive,
      'invited' => l10n.memberStatusInvited,
      'removed' => l10n.memberStatusRemoved,
      _ => status,
    };

/// Maps a raw invitation `status` value (organizations migration 00002:
/// `status IN ('pending', 'accepted', 'expired', 'revoked')`) to its
/// localized label.
String _invitationStatusLabel(AppLocalizations l10n, String status) =>
    switch (status) {
      'pending' => l10n.invitationStatusPending,
      'accepted' => l10n.invitationStatusAccepted,
      'expired' => l10n.invitationStatusExpired,
      'revoked' => l10n.invitationStatusRevoked,
      _ => status,
    };

/// A single row in the members list — its own widget class (rather than an
/// inline `.map()` closure in [_MembersScreenState.build]) so the role/status
/// localization (MEDIUM finding: these were raw, untranslated codes like
/// `'admin · active'`) lives in one place and [_MembersScreenState.build]
/// stays smaller.
class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.member});

  final Member member;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      key: Key('member-${member.userId}'),
      contentPadding: EdgeInsets.zero,
      title: Text(member.userId),
      subtitle: Text(
        '${_roleLabel(l10n, member.role)} · '
        '${_memberStatusLabel(l10n, member.status)}',
      ),
    );
  }
}

/// A single row in the invitations list, with its revoke action — same
/// extraction rationale as [_MemberTile]. [revoking]/[onRevoke] are plain
/// data/callback from [_MembersScreenState] (which owns the busy-id set and
/// the actual revoke request), matching how [_SyncSection] on the account
/// screen takes its busy flag + handler from its owning state.
class _InvitationTile extends StatelessWidget {
  const _InvitationTile({
    required this.invitation,
    required this.revoking,
    required this.onRevoke,
  });

  final Invitation invitation;

  /// Whether a revoke request for this invitation is currently in flight.
  final bool revoking;

  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      key: Key('invitation-${invitation.id}'),
      contentPadding: EdgeInsets.zero,
      title: Text(invitation.email),
      subtitle: Text(
        '${_roleLabel(l10n, invitation.role)} · '
        '${_invitationStatusLabel(l10n, invitation.status)}',
      ),
      trailing: invitation.status == 'pending'
          ? IconButton(
              key: Key('revoke-invitation-${invitation.id}'),
              icon: revoking
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.close),
              tooltip: l10n.membersRevokeButton,
              onPressed: revoking ? null : onRevoke,
            )
          : null,
    );
  }
}
