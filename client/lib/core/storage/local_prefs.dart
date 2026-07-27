import 'local_prefs_stub.dart'
    if (dart.library.js_interop) 'local_prefs_web.dart';

/// A tiny key-value seam over durable browser storage (`localStorage` on
/// web), used to cache last-known-good snapshots for offline-first reads
/// (#390) — e.g. the onboarding gate's profile/organization checks
/// (`features/profile/profile_repository.dart`,
/// `features/organization/organization_repository.dart`). Kept separate from
/// `core/auth/auth_platform.dart`'s own `readLocal`/`writeLocal`: that seam is
/// scoped to the OIDC redirect flow's concerns (session tokens, PKCE
/// verifier/state, browser navigation) and its non-web stub deliberately
/// *throws* (auth is only available on web) — general-purpose caching should
/// instead degrade silently (no cache) on a non-web/VM target, which is what
/// widget/unit tests run on.
abstract interface class LocalPrefs {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
}

/// Constructs the platform implementation for the current target.
LocalPrefs createLocalPrefs() => makeLocalPrefs();

/// Cache key for the onboarding gate's last-known-good profile snapshot
/// (`ProfileRepository.fetch()`). Public (not private to
/// profile_repository.dart) because `AuthController.logout()`/
/// `_clearLocalSession()` also needs it, to purge the cache on logout so a
/// second user on the same shared device never sees a prior user's cached
/// onboarding state (#390).
const kProfileCacheKey = 'bk.profile';

/// Cache key for the onboarding gate's last-known-good organization snapshot
/// (`OrganizationRepository.fetchMine()`) — see [kProfileCacheKey].
const kOrganizationCacheKey = 'bk.organization';
