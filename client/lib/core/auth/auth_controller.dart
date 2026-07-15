import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:http/http.dart' as http;
import 'package:openid_client/openid_client.dart';

import '../config/app_config.dart';
import '../sync/local_store.dart';
import '../sync/powersync_service.dart';
import 'auth_platform.dart';
import 'pkce.dart';

const _kVerifier = 'bk.pkce_verifier';
const _kState = 'bk.oauth_state';
const _kRefresh = 'bk.refresh_token';
const _kIdToken = 'bk.id_token';

/// Cached OIDC discovery: fetches the provider's `.well-known` document once
/// (its endpoints — authorize, token, end-session, JWKS — are read from here,
/// never hard-coded) and memoizes the resulting [Issuer] for the app's
/// lifetime. Provider-agnostic: swapping the IdP is just changing
/// `--dart-define=OIDC_ISSUER` (docs/architecture/oidc-integration.md §7, D-7).
///
/// Injectable: unit tests override this with a fake [Issuer] built from an
/// in-memory metadata map, so they exercise the real [AuthController] flow
/// without touching the network / `.well-known`.
///
/// `retry: null` (never retry) is deliberate: Riverpod 3's container-level
/// default retry policy would otherwise silently re-attempt a failed
/// discovery fetch up to 10 times with exponential backoff (up to ~1 minute
/// total) *inside* this provider before `oidcIssuerProvider.future` ever
/// rejects — which would make a beekeeper tapping "Sign in" (or the app
/// silently trying to refresh) while offline appear to hang for up to a
/// minute before [AuthController.login]/[AuthController._refresh] ever get a
/// chance to run their own (immediate) offline-friendly fallback. Discovery
/// failures should surface promptly so those callers' own handling — not a
/// generic background-retry policy meant for best-effort data fetches — is
/// what decides how to degrade offline.
final oidcIssuerProvider = FutureProvider<Issuer>((ref) {
  return Issuer.discover(Uri.parse(AppConfig.oidcIssuer));
}, retry: (retryCount, error) => null);

/// A logged-in session (OIDC tokens). Tokens live in per-tab session storage —
/// acceptable for the dev/CI skeleton; a hardened BFF/httpOnly-cookie flow is a
/// later concern (auth.md, EPIC-14).
///
/// [idToken] is retained (not just access/refresh) because RP-initiated logout
/// needs it as the `id_token_hint` for the provider's `end_session_endpoint`
/// (docs/architecture/oidc-integration.md §7).
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.idToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
  final String idToken;
  final DateTime expiresAt;

  bool get isExpired =>
      DateTime.now().isAfter(expiresAt.subtract(const Duration(seconds: 30)));

  // Value equality (MEDIUM-2): without this, two structurally-identical
  // sessions (e.g. the same one re-persisted by _persist) compare unequal
  // (default identity equality), causing redundant AsyncData emissions/
  // rebuilds for consumers watching authControllerProvider.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AuthSession &&
          runtimeType == other.runtimeType &&
          accessToken == other.accessToken &&
          refreshToken == other.refreshToken &&
          idToken == other.idToken &&
          expiresAt == other.expiresAt);

  @override
  int get hashCode =>
      Object.hash(accessToken, refreshToken, idToken, expiresAt);
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthSession?>(AuthController.new);

/// Whether there is a current session — used by the router to gate routes.
final isAuthenticatedProvider = Provider<bool>((ref) {
  return ref.watch(authControllerProvider).value != null;
});

/// Non-null when the most recent [AuthController.login] attempt failed (e.g.
/// OIDC discovery unreachable while tapping "Sign in" offline). Surfaced
/// through state — rather than letting the failure throw into an unhandled
/// zone error with no user feedback — so [LoginScreen] can watch it and show
/// an error message; the button itself is the retry affordance, since every
/// new [AuthController.login] attempt resets this to null first.
final loginErrorProvider = StateProvider<Object?>((ref) => null);

/// Drives the OIDC Authorization Code + PKCE flow (auth.md §3.2) for the PWA
/// public client via `package:openid_client` (discovery-driven, so no provider
/// URL scheme lives here — oidc-integration.md §7), entirely client-side (no
/// server session in the skeleton).
class AuthController extends AsyncNotifier<AuthSession?> {
  /// Test-only seams: production always uses the defaults (`createAuthPlatform()`,
  /// the [oidcIssuerProvider]'s real `Issuer.discover`, and a real `http.Client`);
  /// unit tests pass a fake [AuthPlatform], override [oidcIssuerProvider] with a
  /// fake [Issuer], and a `package:http/testing.dart` `MockClient` to stub the
  /// token endpoint (via `authControllerProvider.overrideWith(() =>
  /// AuthController(...))`) — no redirect-based web platform, no network.
  ///
  /// [clearLocalStore] is a further test-only seam: production reads the real
  /// [localStoreProvider] (which opens/reuses the on-device PowerSync
  /// database), but unit tests inject a fake so `logout()`'s purge can be
  /// asserted without standing up PowerSync itself.
  AuthController({
    AuthPlatform? platform,
    http.Client? httpClient,
    Future<LocalStoreEngine> Function()? clearLocalStore,
  }) : _injectedPlatform = platform,
       _http = httpClient,
       _injectedLocalStore = clearLocalStore;

  final AuthPlatform? _injectedPlatform;
  AuthPlatform? _platform;
  final Future<LocalStoreEngine> Function()? _injectedLocalStore;

  /// Injected only in tests; production lets `openid_client` create its own
  /// per-request client. Not closed here — a `MockClient` needs none and a
  /// caller-provided real client is the caller's to dispose.
  final http.Client? _http;

  // Imperative read (not watch): discovery is a one-shot cached value, and this
  // is called from event handlers (login/logout/refresh) as well as build(), so
  // `ref.read` is the right pattern — `ref.watch` outside build() is disallowed.
  Future<Issuer> _issuer() => ref.read(oidcIssuerProvider.future);

  Client _client(Issuer issuer) =>
      Client(issuer, AppConfig.oidcClientId, httpClient: _http);

  @override
  Future<AuthSession?> build() async {
    try {
      final platform = _platform = _injectedPlatform ?? createAuthPlatform();
      final uri = platform.currentUri;
      final code = uri.queryParameters['code'];
      if (code != null) {
        final session = await _exchangeCallback(platform, uri.queryParameters);
        platform.replaceLocation(uri.replace(queryParameters: {}));
        return session;
      }
      final refresh = platform.readSession(_kRefresh);
      if (refresh != null) {
        return await _refresh(platform, refresh);
      }
    } catch (e, st) {
      // Deliberately catch-all (not narrowed to Exception): the non-web
      // stub AuthPlatform (widget tests) throws UnsupportedError — an
      // Error, not an Exception — by design (auth_platform_stub.dart), and
      // that must resolve to logged-out here just like a real transient
      // failure would.
      developer.log(
        'AuthController.build() failed (non-web target, or a transient '
        'failure) — resolving logged-out',
        name: 'auth',
        error: e,
        stackTrace: st,
      );
    }
    return null;
  }

  /// Starts login by redirecting the browser to the provider's authorize
  /// endpoint (read from discovery). We generate the PKCE `code_verifier`
  /// ourselves (openid_client's [Flow] keeps it private) and persist it plus the
  /// CSRF `state`, so the callback — a fresh page load — can reconstruct the
  /// same flow and let openid_client validate the state + complete the exchange.
  Future<void> login() async {
    // Reset any previous failure at the start of every attempt — tapping
    // "Sign in" again is the retry affordance.
    ref.read(loginErrorProvider.notifier).state = null;
    try {
      final platform = _platform ??= _injectedPlatform ?? createAuthPlatform();
      final issuer = await _issuer();
      final verifier = randomVerifier();
      final flow = Flow.authorizationCodeWithPKCE(
        _client(issuer),
        codeVerifier: verifier,
        // `offline_access` is required for the provider to issue a refresh
        // token; build() restores a session on (re)load only from a
        // persisted refresh token, so without it a full page reload logs the
        // user out (auth.md §7, #236). The Authentik blueprint already maps
        // offline_access + the refresh_token grant, so requesting it here is
        // all that's needed.
        scopes: const ['openid', 'profile', 'email', 'offline_access'],
      )..redirectUri = Uri.parse(platform.redirectUri);

      platform.writeSession(_kVerifier, verifier);
      platform.writeSession(_kState, flow.state);
      platform.assignLocation(flow.authenticationUri.toString());
    } on Exception catch (e, st) {
      // Most commonly OIDC discovery failing while offline (tapping "Sign
      // in" with no signal) — surface it through state so LoginScreen can
      // show an error/retry affordance instead of this throwing into an
      // unhandled zone error with no user feedback.
      developer.log(
        'login() failed (network/discovery failure while offline?)',
        name: 'auth',
        error: e,
        stackTrace: st,
      );
      ref.read(loginErrorProvider.notifier).state = e;
    }
  }

  /// Logs out via **RP-initiated (front-channel) logout**: clears all local
  /// session state FIRST (so an offline logout still degrades to
  /// locally-logged-out — D-10 doesn't require offline logout to reach the
  /// provider), then redirects the browser to the discovered
  /// `end_session_endpoint` with `id_token_hint` + `post_logout_redirect_uri`
  /// so the provider's SSO session is ended server-side, not just the client's
  /// local token cache (NFR-SEC-1, oidc-integration.md §7). Best-effort also
  /// hits the `revocation_endpoint` for the refresh token.
  ///
  /// Also **wipes the on-device local store** (#125, FR-TEN-1/FR-TEN-2,
  /// NFR-SEC-1) via [LocalStoreEngine.clear] — not just a
  /// disconnect/dispose — so a second user logging in on the same shared
  /// browser/device never sees the previous session's replicated rows
  /// (SQLite over OPFS/IndexedDB on web) before the next sync reconciles.
  /// This is the offline mirror of the tenancy guarantee (auth.md §6.5): it
  /// holds for the moment **between** sessions, not just within one.
  ///
  /// **Pending-writes-at-purge policy (#125 AC):** logout is a *deliberate*
  /// user action, so any unsynced local writes still queued in PowerSync's
  /// upload queue at this point are **discarded**, not blocked-and-warned —
  /// `clear()` drops the queue along with the replicated rows
  /// (`disconnectAndClear`, powersync_local_store.dart). We accept this
  /// trade-off rather than blocking logout on a flush: the field-first UX
  /// (auth.md, D-10) favors a fast, always-available logout over a screen
  /// that can get stuck offline waiting to sync before it lets the user
  /// leave. There is no separate confirmation prompt for this in v1 — logout
  /// itself is the confirmation. (Membership-loss purges, by contrast, are
  /// not a user action; see `local_data_purge.dart`'s own note on the same
  /// question for that path.)
  Future<void> logout() async {
    final session = state.value;
    final platform = _platform;

    // Wipe the local store BEFORE clearing session tokens: `clear()` needs
    // no network (pure on-device SQLite teardown) so it is safe to run even
    // fully offline, and doing it first means a crash/interruption between
    // the two steps never leaves stale replicated data behind paired with a
    // session that looks logged out. Best-effort: a wipe failure must not
    // block the user from finishing logout.
    try {
      final store =
          await (_injectedLocalStore ??
              () => ref.read(localStoreProvider.future))();
      await store.clear();
    } catch (e, st) {
      // Deliberately catch-all (not narrowed to Exception): a test double's
      // wipe failure (or a real PowerSync failure) can surface as a
      // StateError — an Error, not an Exception — and this must stay
      // best-effort either way: PowerSync was never opened this session, or
      // the wipe failed — local session-token clearing below still logs the
      // user out.
      developer.log(
        'logout(): local-store wipe failed (best-effort, continuing)',
        name: 'auth',
        error: e,
        stackTrace: st,
      );
    }
    // `ref.mounted` guards against the async gap above racing this
    // controller's own disposal (e.g. a test container torn down mid-await;
    // see auth_controller_test.dart) — invalidating a disposed Ref throws.
    if (ref.mounted) ref.invalidate(powerSyncProvider);

    // Clear local session state — the redirect below may never complete
    // offline, but the user must still end up locally logged out.
    _clearLocalSession();
    state = const AsyncData(null);

    if (session == null || platform == null) return;

    try {
      final issuer = await _issuer();
      final metadata = issuer.metadata;

      // Best-effort refresh-token revocation (optional per §7).
      final revocation = metadata.revocationEndpoint;
      if (revocation != null && session.refreshToken.isNotEmpty) {
        try {
          final cred = _client(issuer).createCredential(
            refreshToken: session.refreshToken,
            idToken: session.idToken.isNotEmpty ? session.idToken : null,
          );
          await cred.revoke();
        } on Exception catch (e, st) {
          // Non-fatal: front-channel end-session below still ends the session.
          developer.log(
            'logout(): best-effort refresh-token revocation failed',
            name: 'auth',
            error: e,
            stackTrace: st,
          );
        }
      }

      // Front-channel end-session (RP-initiated logout).
      final endSession = metadata.endSessionEndpoint;
      if (endSession != null && session.idToken.isNotEmpty) {
        final logoutUrl = endSession.replace(
          queryParameters: {
            'id_token_hint': session.idToken,
            'post_logout_redirect_uri': platform.redirectUri,
          },
        );
        platform.assignLocation(logoutUrl.toString());
      }
    } on Exception catch (e, st) {
      // Offline / discovery failure: local state is already cleared above, so
      // the user is logged out locally. The provider SSO session/cookie will
      // outlive this device until it expires naturally.
      developer.log(
        'logout(): discovery/front-channel end-session failed — already '
        'logged out locally',
        name: 'auth',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Defensive sweep of every local-storage key this controller ever writes —
  /// not just the refresh/id token — so an abandoned mid-flow login (PKCE
  /// verifier/state written but never exchanged) can't leave stale entries.
  ///
  /// Swallows `UnsupportedError` from the non-web stub [AuthPlatform] (widget
  /// tests run on the VM, where `_platform` is a working object but every
  /// method throws by design — see `auth_platform_stub.dart`) so `logout()`
  /// stays a no-throw local state transition there, matching `build()`'s own
  /// non-web handling.
  void _clearLocalSession() {
    final platform = _platform;
    if (platform == null) return;
    try {
      platform.removeSession(_kVerifier);
      platform.removeSession(_kState);
      platform.removeSession(_kRefresh);
      platform.removeSession(_kIdToken);
    } on UnsupportedError {
      // Non-web target: there is no real session storage to clear.
    }
  }

  /// A valid access token, refreshed if within 30s of expiry, or null when
  /// logged out. Used by the PowerSync connector's fetchCredentials.
  Future<String?> accessToken() async {
    final session = state.value;
    final platform = _platform;
    if (session == null || platform == null) return null;
    if (!session.isExpired) return session.accessToken;

    try {
      final refreshed = await _refresh(platform, session.refreshToken);
      state = AsyncData(refreshed);
      return refreshed?.accessToken;
    } on Exception catch (e, st) {
      // Network/discovery failure while offline (see _refresh's own note):
      // keep the existing, now-expired session rather than logging the user
      // out just because they lack connectivity right now. The (stale)
      // access token is handed back so an offline-tolerant caller (e.g. a
      // request that will itself queue/fail gracefully) can still proceed;
      // the next accessToken() call retries the refresh.
      developer.log(
        'accessToken(): refresh failed (offline?) — keeping stale session',
        name: 'auth',
        error: e,
        stackTrace: st,
      );
      return session.accessToken;
    }
  }

  /// Completes the redirect callback: reconstructs the [Flow] with the persisted
  /// verifier + `state`, lets `openid_client` validate the `state` (CSRF) and
  /// perform the PKCE code→token exchange, then persists the resulting session.
  Future<AuthSession?> _exchangeCallback(
    AuthPlatform platform,
    Map<String, String> params,
  ) async {
    final issuer = await _issuer();
    final verifier = platform.readSession(_kVerifier);
    final expectedState = platform.readSession(_kState);
    final flow = Flow.authorizationCodeWithPKCE(
      _client(issuer),
      state: expectedState,
      codeVerifier: verifier,
      // Must match login()'s requested scopes — including `offline_access` — so
      // the reconstructed flow completes the same exchange and the provider
      // returns a refresh token to persist for session restore (auth.md §7,
      // #236).
      scopes: const ['openid', 'profile', 'email', 'offline_access'],
    )..redirectUri = Uri.parse(platform.redirectUri);

    // Flow.callback throws ArgumentError('State does not match') on a CSRF
    // mismatch; build() swallows it and resolves logged-out.
    final credential = await flow.callback(params);
    final token = await credential.getTokenResponse();

    platform.removeSession(_kVerifier);
    platform.removeSession(_kState);
    return _persist(platform, token);
  }

  Future<AuthSession?> _refresh(
    AuthPlatform platform,
    String refreshToken,
  ) async {
    try {
      final issuer = await _issuer();
      final idToken = platform.readSession(_kIdToken);
      final credential = _client(
        issuer,
      ).createCredential(refreshToken: refreshToken, idToken: idToken);
      final token = await credential.getTokenResponse(true);
      return _persist(platform, token);
    } on OpenIdException {
      // A genuine rejection (invalid_grant/expired) from the provider — the
      // refresh token itself is no longer good, so it's safe (and correct)
      // to drop the persisted session and resolve to logged-out rather than
      // looping.
      platform.removeSession(_kRefresh);
      platform.removeSession(_kIdToken);
      return null;
    }
    // Any other failure (network/discovery timeout, DNS failure, etc. while
    // offline) intentionally propagates rather than being swallowed here:
    // the refresh token was never actually rejected, so wiping it would
    // strand an offline beekeeper — they'd have to log in again even once
    // signal returns. Callers (accessToken()/build()) decide how to degrade.
  }

  AuthSession? _persist(AuthPlatform platform, TokenResponse token) {
    final access = token.accessToken;
    if (access == null) return null;
    final refresh = token.refreshToken ?? '';
    // openid_client keeps the prior refresh token across a refresh when the
    // provider omits it, so read it back off the token, falling back to the
    // stored one so a refresh that doesn't re-issue it keeps the session alive.
    final effectiveRefresh = refresh.isNotEmpty
        ? refresh
        : (platform.readSession(_kRefresh) ?? '');
    // Read `id_token` off the raw response (not the typed `.idToken` getter,
    // which throws when absent): a refresh often omits it, so fall back to the
    // previously-stored value to keep it available for RP-initiated logout.
    final rawIdToken = token['id_token'] as String?;
    final idToken = (rawIdToken != null && rawIdToken.isNotEmpty)
        ? rawIdToken
        : (platform.readSession(_kIdToken) ?? '');
    final expiresAt =
        token.expiresAt ??
        DateTime.now().add(token.expiresIn ?? const Duration(minutes: 5));

    if (effectiveRefresh.isNotEmpty) {
      platform.writeSession(_kRefresh, effectiveRefresh);
    }
    if (idToken.isNotEmpty) platform.writeSession(_kIdToken, idToken);
    return AuthSession(
      accessToken: access,
      refreshToken: effectiveRefresh,
      idToken: idToken,
      expiresAt: expiresAt,
    );
  }
}
