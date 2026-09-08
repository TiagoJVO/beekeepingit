import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/validation/email.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/widgets/content_column.dart';
import '../../core/widgets/field_action_button.dart';
import '../../core/widgets/field_error.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_widgets.dart';
import 'member_display.dart';
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

  /// Ids of invitations currently mid-resend (#641) — same double-tap guard
  /// as [_revokingIds], and it matters more here: every accepted tap is
  /// another email to a real person's inbox.
  final Set<String> _resendingIds = {};

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
      final created = await ref
          .read(membersProvider.notifier)
          .invite(email: _emailController.text.trim());
      if (!mounted) return;
      _emailController.clear();
      // #641: the invitation is created either way, but only say "sent" when
      // it actually was. A failed email is not an error here — the invitation
      // exists and is retryable from its row. Raised through showAppToast
      // (#640) like every other confirmation on this screen.
      showAppToast(
        ScaffoldMessenger.of(context),
        created.deliveryStatus == 'sent'
            ? l10n.membersInviteSuccess
            : l10n.membersInviteCreatedNotSent(
                _deliveryErrorLabel(l10n, created.deliveryError),
              ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      final fieldErrors = {
        for (final fe in e.fieldErrors) fe.field: fe.message,
      };
      if (fieldErrors.containsKey('email')) {
        setState(() => _emailError = fieldErrors['email']);
      } else {
        showAppToast(
          ScaffoldMessenger.of(context),
          l10n.membersInviteError(e.detail),
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppToast(
        ScaffoldMessenger.of(context),
        l10n.membersInviteError('$e'),
      );
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
      showAppToast(ScaffoldMessenger.of(context), l10n.membersRevokeSuccess);
    } catch (e) {
      if (!mounted) return;
      showAppToast(
        ScaffoldMessenger.of(context),
        l10n.membersInviteError('$e'),
      );
    } finally {
      if (mounted) setState(() => _revokingIds.remove(invitationId));
    }
  }

  /// Retries the invitation email (#641 AC 5) and tells the admin what THIS
  /// attempt did — a snackbar saying "sent" or "still failing", never a
  /// silent redraw. The list refresh happens inside the controller, so the
  /// row's own state label updates too.
  Future<void> _resend(String invitationId, AppLocalizations l10n) async {
    if (_resendingIds.contains(invitationId)) return;
    setState(() => _resendingIds.add(invitationId));
    try {
      final updated = await ref
          .read(membersProvider.notifier)
          .resendInvitation(invitationId);
      if (!mounted) return;
      showAppToast(
        ScaffoldMessenger.of(context),
        updated.deliveryStatus == 'sent'
            ? l10n.membersResendSuccess
            : l10n.membersResendStillFailing(
                _deliveryErrorLabel(l10n, updated.deliveryError),
              ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      showAppToast(
        ScaffoldMessenger.of(context),
        l10n.membersInviteError(e.detail),
      );
    } catch (e) {
      if (!mounted) return;
      showAppToast(
        ScaffoldMessenger.of(context),
        l10n.membersInviteError('$e'),
      );
    } finally {
      if (mounted) setState(() => _resendingIds.remove(invitationId));
    }
  }

  Future<void> _loadMoreMembers(AppLocalizations l10n) async {
    setState(() => _loadingMoreMembers = true);
    try {
      await ref.read(membersProvider.notifier).loadMoreMembers();
    } catch (e) {
      if (!mounted) return;
      showAppToast(
        ScaffoldMessenger.of(context),
        l10n.membersInviteError('$e'),
      );
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
      showAppToast(
        ScaffoldMessenger.of(context),
        l10n.membersInviteError('$e'),
      );
    } finally {
      if (mounted) setState(() => _loadingMoreInvitations = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(membersProvider);
    // The org roster (`user_id -> display name`, #44/FR-TEN-2) that every
    // other feature already resolves an id against — activities, todos and
    // history all read it exactly this way. Watched once here and passed
    // down rather than per row, so one list of N members holds one
    // subscription, not N.
    //
    // `.value ?? {}` on purpose (the same shape activity_list_widgets.dart
    // and history_section.dart use): the roster is ONLINE-ONLY and
    // best-effort — loading, offline, and a failed fetch all resolve to an
    // empty map, and a row then degrades to a short id fragment rather than
    // blocking or erroring this screen. Its own data (memberships) is a
    // separate, admin-only fetch that has already succeeded by the time a
    // row renders.
    final memberNames =
        ref.watch(memberNamesProvider).value ?? const <String, String>{};

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          key: const Key('members-back-button'),
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          // Back to the app home, which is the Home tab now (#658, D-35,
          // amending D-29's Tasks landing).
          onPressed: () => context.go('/home'),
        ),
        title: Text(l10n.membersTitle),
      ),
      // ContentColumn (#650): caps the form + members/invitations lists at
      // BrandDimens.maxWidthList on a wide desktop viewport rather than
      // stretching them across the window.
      body: ContentColumn(
        child: state.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (err, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l10n.membersLoadError('$err')),
            ),
          ),
          data: (data) => SingleChildScrollView(
            // The bottom gutter is the chrome band, not a gutter (#773): this
            // screen raises its own invite/revoke confirmations, and a flat
            // 24 left them landing on the invitation row they were reporting
            // on. No FAB and no bottom navigation here — the route is
            // declared outside the shell — so the band is the toast's own
            // height, which out here includes the home-indicator inset the
            // toast's bar carries; `scrollBottomInsetOf` adds it.
            padding: EdgeInsets.fromLTRB(
              24,
              24,
              24,
              BrandDimens.scrollBottomInsetOf(context),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // One label pattern app-wide (#629, FR-UX-1): the label
                      // sits ABOVE the field, never animated into its box
                      // border.
                      LabeledField(
                        label: l10n.membersInviteEmailLabel,
                        child: TextFormField(
                          key: const Key('invite-email-field'),
                          controller: _emailController,
                          keyboardType: TextInputType.emailAddress,
                          // Drops the last invite's server verdict once
                          // the address changes (#649's rule) — mandatory
                          // here, because `forceErrorText` below keeps
                          // `Form.validate()` false while it stands, so
                          // without this the invite button would be dead
                          // for the rest of the session.
                          onChanged: (_) {
                            if (_emailError == null) return;
                            setState(() => _emailError = null);
                          },
                          // Both messages — the local validator's and the
                          // server's 422 — are announced, not just painted
                          // (#750, FR-AX-1, D-18). The server one travels
                          // as `forceErrorText:` so it also sets
                          // `FormFieldState.hasError`, which is what marks
                          // the field `validationResult: invalid`; a
                          // decoration-only `error:`/`errorText:` would
                          // leave it reading as VALID under a visibly red
                          // message. See field_error.dart.
                          forceErrorText: _emailError,
                          errorBuilder: announcedFieldError,
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
                      const SizedBox(height: 12),
                      // Under the field rather than beside it (#629). A label
                      // above the field cannot share a row with the button
                      // that submits it: aligned to the row's top the button
                      // rides up level with the LABEL, and any fixed nudge to
                      // push it back down is a guess that breaks the moment
                      // the OS text scale grows the label — the exact
                      // large-text case this milestone is about (FR-AX-1).
                      // Still not full-width (unlike a whole form's primary
                      // action): it submits one field, and keeps the shared
                      // 44+ tap-target height (#79/#80).
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: PrimaryActionButton(
                          key: const Key('invite-submit-button'),
                          label: l10n.membersInviteButton,
                          busy: _inviting,
                          fullWidth: false,
                          onPressed: () => _invite(l10n),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
                SectionHeader(l10n.membersSectionTitle),
                const SizedBox(height: 8),
                if (data.members.isEmpty)
                  Text(l10n.membersEmpty)
                else
                  ...data.members.map(
                    (m) => _MemberTile(member: m, memberNames: memberNames),
                  ),
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
                SectionHeader(l10n.invitationsSectionTitle),
                const SizedBox(height: 8),
                if (data.invitations.isEmpty)
                  Text(l10n.invitationsEmpty)
                else
                  ...data.invitations.map(
                    (inv) => _InvitationTile(
                      invitation: inv,
                      revoking: _revokingIds.contains(inv.id),
                      resending: _resendingIds.contains(inv.id),
                      onRevoke: () => _revoke(inv.id, l10n),
                      onResend: () => _resend(inv.id, l10n),
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

/// The one honest label for an invitation's state (#641).
///
/// An invitation has TWO independent states — its lifecycle (`status`: what
/// the invitee did) and its email delivery (`delivery_status`: what the system
/// did) — and the admin needs whichever one is currently the truth about this
/// row. A resolved lifecycle wins (an accepted invitation is accepted
/// regardless of how its email went); while it is still `pending`, what the
/// admin actually needs to know is whether the email left.
///
/// This replaces a bare "Pending" that used to be shown from the moment of
/// creation, forever, for a message that had never been sent — the defect
/// #641 exists to fix. "Pending" now only ever means what it means everywhere
/// else in the product: sent, awaiting a response.
String _invitationStateLabel(AppLocalizations l10n, Invitation invitation) {
  if (invitation.status != 'pending') {
    return switch (invitation.status) {
      'accepted' => l10n.invitationStatusAccepted,
      'expired' => l10n.invitationStatusExpired,
      'revoked' => l10n.invitationStatusRevoked,
      _ => invitation.status,
    };
  }
  return switch (invitation.deliveryStatus) {
    'sent' => l10n.invitationStatusPending,
    'failed' => l10n.invitationDeliveryFailed,
    // 'pending' — an attempt is in flight, or its outcome could not be
    // recorded. Never shown as "Pending" (which claims delivery): "Sending"
    // says exactly as much as is known.
    _ => l10n.invitationDeliverySending,
  };
}

/// Maps a server delivery failure CODE to a localized explanation (#641).
/// Codes, not messages, cross the wire, so the admin reads this in their own
/// language and the server never has to guess one.
String _deliveryErrorLabel(AppLocalizations l10n, String code) =>
    switch (code) {
      'not_configured' => l10n.invitationDeliveryErrorNotConfigured,
      'rejected' => l10n.invitationDeliveryErrorRejected,
      'relay_unavailable' => l10n.invitationDeliveryErrorRelayUnavailable,
      'render_failed' => l10n.invitationDeliveryErrorRenderFailed,
      'never_sent' => l10n.invitationDeliveryErrorNeverSent,
      _ => l10n.invitationDeliveryErrorUnknown,
    };

/// A single row in the members list — its own widget class (rather than an
/// inline `.map()` closure in [_MembersScreenState.build]) so the role/status
/// localization (MEDIUM finding: these were raw, untranslated codes like
/// `'admin · active'`) lives in one place and [_MembersScreenState.build]
/// stays smaller.
class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.member, required this.memberNames});

  final Member member;

  /// The caller's org roster (`user_id -> display name`) from
  /// `memberNamesProvider`, resolved by [memberIdentityLabel]. Empty offline,
  /// before the first fetch, or after a failed one — see the owning screen's
  /// own comment.
  final Map<String, String> memberNames;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListTile(
      // Keyed by the id, titled by the NAME (#582, FR-TEN-2): a widget key
      // is never read aloud or painted, so it stays the stable, unique id
      // while the row shows something a person can read.
      key: Key('member-${member.userId}'),
      contentPadding: EdgeInsets.zero,
      // Bounded (#582, D-18): the name is authored outside this app and the
      // server accepts up to 200 characters, so an unbounded title could grow
      // the row without limit — and at 200% text scale even an ordinary name
      // needs the ellipsis. Two lines rather than one so a genuinely long name
      // stays readable at that scale.
      title: Text(
        memberIdentityLabel(l10n, member.userId, memberNames),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
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
    required this.resending,
    required this.onRevoke,
    required this.onResend,
  });

  final Invitation invitation;

  /// Whether a revoke request for this invitation is currently in flight.
  final bool revoking;

  /// Whether a resend request for this invitation is currently in flight
  /// (#641) — same double-tap guard rationale as [revoking].
  final bool resending;

  final VoidCallback onRevoke;
  final VoidCallback onResend;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final failed =
        invitation.status == 'pending' && invitation.deliveryStatus == 'failed';

    // The failure reason is a second subtitle line rather than a tooltip or an
    // icon: "it failed" without "why" is the kind of dead end this milestone
    // is about, and a tooltip is reachable by neither touch nor screen reader.
    final reason = failed
        ? _deliveryErrorLabel(l10n, invitation.deliveryError)
        : null;

    return ListTile(
      key: Key('invitation-${invitation.id}'),
      contentPadding: EdgeInsets.zero,
      isThreeLine: reason != null,
      // The invited address stays the row's title (#582): an invitation has
      // no user account yet, so there is no name to resolve and no id worth
      // showing — the email IS the invitee's identity, and it reads as a
      // person's identifier beside a named member rather than as an internal
      // code. Bounded exactly like [_MemberTile]'s title (D-18, FR-AX-1) so
      // the two lists degrade the same way at 200% text scale; an address can
      // be up to 320 octets and would otherwise grow the row without limit.
      title: Text(
        invitation.email,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_roleLabel(l10n, invitation.role)} · '
            '${_invitationStateLabel(l10n, invitation)}',
            style: failed
                ? theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  )
                : null,
          ),
          if (reason != null)
            Text(
              reason,
              key: Key('invitation-delivery-error-${invitation.id}'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
      trailing: invitation.status == 'pending'
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('resend-invitation-${invitation.id}'),
                  icon: resending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  tooltip: l10n.membersResendButton,
                  onPressed: resending ? null : onResend,
                ),
                IconButton(
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
                ),
              ],
            )
          : null,
    );
  }
}
