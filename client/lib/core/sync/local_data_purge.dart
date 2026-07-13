import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/organization/organization_repository.dart';
import '../auth/auth_platform.dart';
import 'powersync_service.dart';

const _kLastOrgId = 'bk.last_org_id';

/// The browser session-storage seam this file compares "had an org before"
/// against. Defaults to the real [createAuthPlatform] (throws
/// [UnsupportedError] on the VM, same as [AuthPlatform]'s other production
/// callers); overridden in widget/unit tests with a fake so the purge logic
/// can run without a real web platform.
final authPlatformProvider = Provider<AuthPlatform>(
  (ref) => createAuthPlatform(),
);

/// **Membership-loss purge** (#125 AC): if the device already held a
/// replicated org slice and the server-resolved organization then
/// disappears — the caller was removed from it — the on-device local store
/// is wiped, the same way `AuthController.logout()` (auth_controller.dart)
/// wipes it deliberately.
///
/// **Why this file, not `organization_repository.dart`:** the repository's
/// job is fetching/creating the org; deciding what a "no org" *transition*
/// means (first-time onboarding vs. a membership that just disappeared) and
/// acting on it (wiping local data) is a cross-cutting sync/tenancy concern,
/// matching the split `AuthController` already draws between session
/// management and its own local-store wipe.
///
/// **The signal.** `GET /v1/organizations/me` returns **404 for both** "never
/// onboarded" and "was a member, removed" (services/organizations/api — by
/// design, so a brand-new signup reaches onboarding). The client can't tell
/// these apart from the status code alone, so it tracks its own marker: the
/// last-resolved org id is written to session storage
/// (`bk.last_org_id`, mirroring `AuthController`'s `bk.*` session keys)
/// whenever [organizationProvider] resolves an org. A **subsequent**
/// resolution in the same session that comes back `null` while that marker
/// is still set is unambiguous — the caller had access and now doesn't — and
/// triggers the purge. A fresh signup with no marker set never purges
/// (nothing to purge yet). This also covers **"at next app start"** (AC
/// bullet 3): [organizationProvider] is re-fetched on every app start for an
/// authenticated user (the router's onboarding gate reads it immediately),
/// and the marker persists across reloads in the same browser session/tab
/// the same way the refresh token does (auth_controller.dart) — matching
/// this app's existing offline-login persistence model (D-7, auth.md §6.1)
/// rather than inventing a new one.
///
/// **Multi-org (C-1, future) — out of scope note (#125 AC):** v1 is
/// single-active-org per device; this purge fires on "the org disappeared",
/// not "switched to another org". Org-switch purge/repartitioning for a user
/// in >1 org is explicitly future scope per the issue.
///
/// **Pending-writes-at-purge policy:** same as `AuthController.logout()` —
/// discarded, not blocked-and-warned. Unlike logout, this purge is not a
/// user action at all (it fires from a background re-fetch), so there is no
/// user present to prompt; silently keeping stale/inaccessible data around
/// instead would violate the tenancy guarantee this purge exists to enforce
/// (FR-TEN-1, FR-TEN-2, NFR-SEC-1), so discarding is the only safe default.
/// The conflict-log server-side (sync.md §4.2) is the safety net for a
/// last-write-wins loss in general; a removed member's unsynced writes were
/// never going to be accepted server-side anyway (auth.md §6.4 — "gains
/// nothing server-side").
///
/// Wired from `app.dart` via `ref.watch(membershipLossPurgeProvider)` so it
/// starts observing as soon as the app boots, independent of which screen is
/// on top — mirroring how `routerProvider` itself already listens to
/// [organizationProvider] for redirect purposes.
final membershipLossPurgeProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<Organization?>>(organizationProvider, (previous, next) {
    // Don't act on a loading transition — wait for the fetch to actually
    // resolve one way or the other (matches app_router.dart's own
    // "don't gate on loading" rule for this same provider).
    if (next.isLoading) return;

    try {
      final platform = ref.read(authPlatformProvider);
      final org = next.value;
      if (org != null) {
        platform.writeSession(_kLastOrgId, org.id);
        return;
      }
      // org == null: only a purge-worthy transition if we previously
      // recorded one — otherwise this is first-time onboarding, not a loss.
      if (platform.readSession(_kLastOrgId) != null) {
        platform.removeSession(_kLastOrgId);
        _purge(ref);
      }
    } on UnsupportedError {
      // Non-web target (VM tests that don't override authPlatformProvider):
      // there is no real session storage to compare against, so there is
      // nothing safe to do here — matches AuthController's own non-web
      // handling of the same stub.
    }
  });
});

/// Fire-and-forget by design: the `ref.listen` callback above must stay
/// synchronous, and there is no UI awaiting this — it is a background
/// consistency sweep, not a user-initiated action (contrast
/// `AuthController.logout()`, which the caller does await).
void _purge(Ref ref) {
  () async {
    try {
      final store = await ref.read(localStoreProvider.future);
      await store.clear();
    } catch (_) {
      // Best-effort: PowerSync may not be open yet, or the wipe failed. The
      // next successful membership check (or a subsequent logout) still
      // enforces the guarantee; failing silently here must never crash the
      // app over a background consistency sweep.
    }
    if (ref.mounted) ref.invalidate(powerSyncProvider);
  }();
}
