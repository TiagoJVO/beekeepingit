import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
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
      final fieldErrors = {for (final fe in e.fieldErrors) fe.field: fe.message};
      if (fieldErrors.containsKey('email')) {
        setState(() => _emailError = fieldErrors['email']);
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.membersInviteError(e.detail))));
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
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(membersProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
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
                ...data.members.map(
                  (m) => ListTile(
                    key: Key('member-${m.userId}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(m.userId),
                    subtitle: Text('${m.role} · ${m.status}'),
                  ),
                ),
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
                  (inv) => ListTile(
                    key: Key('invitation-${inv.id}'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(inv.email),
                    subtitle: Text('${inv.role} · ${inv.status}'),
                    trailing: inv.status == 'pending'
                        ? IconButton(
                            key: Key('revoke-invitation-${inv.id}'),
                            icon: const Icon(Icons.close),
                            tooltip: l10n.membersRevokeButton,
                            onPressed: () => _revoke(inv.id, l10n),
                          )
                        : null,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
