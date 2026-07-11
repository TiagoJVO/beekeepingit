import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:openid_client/openid_client.dart';

import '../config/app_config.dart';
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
final oidcIssuerProvider = FutureProvider<Issuer>((ref) {
  return Issuer.discover(Uri.parse(AppConfig.oidcIssuer));
});

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
}

final authControllerProvider =
    AsyncNotifierProvider<AuthController, AuthSession?>(AuthController.new);

/// Whether there is a current session — used by the router to gate routes.
final isAuthenticatedProvider = Provider<bool>((ref) {
  return ref.watch(authControllerProvider).value != null;
});

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
  AuthController({AuthPlatform? platform, http.Client? httpClient})
    : _injectedPlatform = platform,
      _http = httpClient;

  final AuthPlatform? _injectedPlatform;
  AuthPlatform? _platform;

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
    } catch (_) {
      // Non-web target (widget tests) or a transient failure: logged out.
    }
    return null;
  }

  /// Starts login by redirecting the browser to the provider's authorize
  /// endpoint (read from discovery). We generate the PKCE `code_verifier`
  /// ourselves (openid_client's [Flow] keeps it private) and persist it plus the
  /// CSRF `state`, so the callback — a fresh page load — can reconstruct the
  /// same flow and let openid_client validate the state + complete the exchange.
  Future<void> login() async {
    final platform = _platform ??= _injectedPlatform ?? createAuthPlatform();
    final issuer = await _issuer();
    final verifier = randomVerifier();
    final flow = Flow.authorizationCodeWithPKCE(
      _client(issuer),
      codeVerifier: verifier,
      scopes: const ['openid', 'profile', 'email'],
    )..redirectUri = Uri.parse(platform.redirectUri);

    platform.writeSession(_kVerifier, verifier);
    platform.writeSession(_kState, flow.state);
    platform.assignLocation(flow.authenticationUri.toString());
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
  /// Also disconnects/tears down the local PowerSync database (invalidating
  /// [powerSyncProvider], whose `onDispose` already calls `disconnect()` +
  /// `close()`) so a second user logging in on the same shared browser/device
  /// doesn't see the previous session's replicated rows before the next sync
  /// reconciles — the tenancy-holds-offline guarantee (auth.md §6.5) extends
  /// to the moment **between** sessions, not just within one.
  Future<void> logout() async {
    final session = state.value;
    final platform = _platform;

    // Clear local state FIRST — the redirect below may never complete offline,
    // but the user must still end up locally logged out.
    _clearLocalSession();
    ref.invalidate(powerSyncProvider);
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
        } catch (_) {
          // Non-fatal: front-channel end-session below still ends the session.
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
    } catch (_) {
      // Offline / discovery failure: local state is already cleared above, so
      // the user is logged out locally. The provider SSO session/cookie will
      // outlive this device until it expires naturally.
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

    final refreshed = await _refresh(platform, session.refreshToken);
    state = AsyncData(refreshed);
    return refreshed?.accessToken;
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
      scopes: const ['openid', 'profile', 'email'],
    )..redirectUri = Uri.parse(platform.redirectUri);

    // Flow.callback throws ArgumentError('State does not match') on a CSRF
    // mismatch; build() swallows it and resolves logged-out.
    final credential = await flow.callback(params);
    final token = await credential.getTokenResponse();

    platform.removeSession(_kVerifier);
    platform.removeSession(_kState);
    return _persist(platform, token);
  }

  Future<AuthSession?> _refresh(AuthPlatform platform, String refreshToken) async {
    try {
      final issuer = await _issuer();
      final idToken = platform.readSession(_kIdToken);
      final credential = _client(issuer).createCredential(
        refreshToken: refreshToken,
        idToken: idToken,
      );
      final token = await credential.getTokenResponse(true);
      return _persist(platform, token);
    } catch (_) {
      // A rejected/expired refresh token (or discovery failure): drop the
      // persisted session so we resolve to logged-out rather than looping.
      platform.removeSession(_kRefresh);
      platform.removeSession(_kIdToken);
      return null;
    }
  }

  AuthSession? _persist(AuthPlatform platform, TokenResponse token) {
    final access = token.accessToken;
    if (access == null) return null;
    final refresh = token.refreshToken ?? '';
    // openid_client keeps the prior refresh token across a refresh when the
    // provider omits it, so read it back off the token, falling back to the
    // stored one so a refresh that doesn't re-issue it keeps the session alive.
    final effectiveRefresh =
        refresh.isNotEmpty ? refresh : (platform.readSession(_kRefresh) ?? '');
    // Read `id_token` off the raw response (not the typed `.idToken` getter,
    // which throws when absent): a refresh often omits it, so fall back to the
    // previously-stored value to keep it available for RP-initiated logout.
    final rawIdToken = token['id_token'] as String?;
    final idToken =
        (rawIdToken != null && rawIdToken.isNotEmpty)
            ? rawIdToken
            : (platform.readSession(_kIdToken) ?? '');
    final expiresAt = token.expiresAt ??
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
