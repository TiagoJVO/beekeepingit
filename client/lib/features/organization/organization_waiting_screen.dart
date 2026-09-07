import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/auth/auth_controller.dart';
import '../../core/widgets/app_toast.dart';
import '../../core/widgets/field_action_button.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../theming/brand_dimens.dart';
import '../../theming/brand_widgets.dart';
import 'organization_repository.dart';

/// The second onboarding exit for a user with no organization (FR-ONB-2 as
/// amended, D-3 / #365 live testing): "I'm waiting for an invitation".
///
/// Why this screen exists. Onboarding used to offer exactly one way out —
/// create an organization — and that is a **one-way door**: an account holds
/// at most one active membership, accept-on-login only runs for a caller with
/// none, and there is no leave path yet (#506). So a user whose invitation had
/// not arrived was pushed through the only available door and walked
/// irreversibly past the invitation they were waiting for.
///
/// What it does NOT do: there is no client-side "accept" and no new endpoint.
/// Checking simply re-asks `GET /v1/organizations/me`, which is *itself* the
/// server's accept-on-login step (auth.md §8.7) — so a matching pending
/// invitation is claimed by the very act of looking. Waiting is a client
/// route, never a membership status and never a pending organization.
///
/// Navigation on success is likewise not this screen's job: the router's
/// redirect already watches [organizationProvider] and carries the user home
/// the moment one resolves.
class OrganizationWaitingScreen extends ConsumerStatefulWidget {
  const OrganizationWaitingScreen({super.key});

  @override
  ConsumerState<OrganizationWaitingScreen> createState() =>
      _OrganizationWaitingScreenState();
}

class _OrganizationWaitingScreenState
    extends ConsumerState<OrganizationWaitingScreen> {
  bool _checking = false;
  bool _stillNone = false;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    // Re-check when the user comes back to the app — the common case is
    // "ask the admin to invite me, switch away, switch back". Silent, so
    // returning to the app never shows a "no invitation yet" message the
    // user did not ask for. No polling timer: button + resume only.
    _lifecycle = AppLifecycleListener(
      onResume: () => unawaited(_check(silent: true)),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _check({bool silent = false}) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _stillNone = false;
    });
    final l10n = AppLocalizations.of(context);
    try {
      await ref.read(organizationProvider.notifier).refresh();
      if (!mounted) return;
      // Deliberately no navigation here: the router's redirect owns that.
      if (ref.read(organizationProvider).value == null && !silent) {
        setState(() => _stillNone = true);
      }
    } on Exception catch (_) {
      // Narrowed to Exception, and a FIXED localized message — the same rule
      // the profile screen follows: a raw exception is never field-user text.
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(appToast(l10n.organizationWaitingCheckError));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.organizationWaitingTitle)),
      // Deliberately still a `Center`, unlike the screens #630/#769
      // top-aligned. This is a short holding page — one paragraph, one hint
      // card, three actions — with little to fill the height with, and it
      // sits outside the app shell (no bottom nav). Top aligned, its content
      // would cling to the header with the rest of a tall phone left empty
      // below; centred, the "Check again" action it exists to offer lands
      // squarely in thumb reach. The dead band #769 is about is only a defect
      // where content wants to start at the top and grow; here it is the
      // layout (FR-UX-1, #769). It still centres wherever the content plus
      // the band below fits — a tablet, a desktop window — but no longer on a
      // 375x812 phone; see the band's own note.
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            // The bottom gutter is the chrome band, not a gutter (#789): the
            // one toast this page raises ("Could not check for an invitation
            // right now. Try again.") wraps to two lines even at 1x and
            // covered the Log out row by a measured 57 — and out here, with
            // no bottom navigation and no account screen to reach, Log out is
            // this page's only escape hatch. The band is the toast's own
            // height, which off the shell includes the home-indicator inset
            // the toast's bar carries; `scrollBottomInsetOf` adds it.
            //
            // It costs the `Center` above on a phone: content plus this band
            // overruns a 375x812 viewport, so the page top-aligns and scrolls
            // where it used to sit centred. Everything still renders above the
            // fold — the band is what scrolls into view, not the actions — and
            // a toast covering the only way off this screen is the worse of
            // the two.
            //
            // It does not clear that message at 200% text, where it wraps to
            // seven lines and measures 302, past any fixed band. That is
            // #790, not something padding here can close.
            padding: EdgeInsets.fromLTRB(
              24,
              24,
              24,
              BrandDimens.scrollBottomInsetOf(context),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.organizationWaitingIntro, style: textTheme.bodyLarge),
                const SizedBox(height: 16),
                NotesCard(
                  icon: Icons.mark_email_unread_outlined,
                  text: l10n.organizationWaitingHint,
                ),
                if (_stillNone) ...[
                  const SizedBox(height: 16),
                  Text(
                    l10n.organizationWaitingStillNone,
                    key: const Key('organization-waiting-still-none'),
                    style: textTheme.bodyMedium,
                  ),
                ],
                const SizedBox(height: 24),
                PrimaryActionButton(
                  key: const Key('organization-waiting-check-button'),
                  label: l10n.organizationWaitingCheckButton,
                  semanticsLabel: _checking
                      ? l10n.organizationWaitingChecking
                      : l10n.organizationWaitingCheckButton,
                  busy: _checking,
                  onPressed: () => _check(),
                ),
                const SizedBox(height: 12),
                SecondaryActionButton(
                  key: const Key('organization-waiting-create-button'),
                  label: l10n.organizationWaitingCreateInsteadButton,
                  icon: Icons.add_business_outlined,
                  onPressed: () => context.go('/organization/new'),
                ),
                const SizedBox(height: 12),
                // The escape hatch: this route sits outside the app shell, so
                // there is no bottom nav and no account screen to reach.
                SecondaryActionButton(
                  key: const Key('organization-waiting-logout-button'),
                  label: l10n.logout,
                  icon: Icons.logout,
                  destructive: true,
                  onPressed: () =>
                      ref.read(authControllerProvider.notifier).logout(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
