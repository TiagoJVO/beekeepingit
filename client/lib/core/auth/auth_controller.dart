import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import '../sync/powersync_service.dart';
import 'auth_platform.dart';
import 'pkce.dart';

const _kVerifier = 'bk.pkce_verifier';
const _kState = 'bk.oauth_state';
const _kRefresh = 'bk.refresh_token';

/// A logged-in session (OIDC access + refresh tokens). Tokens live in
/// per-tab session storage — acceptable for the dev/CI skeleton; a hardened
/// BFF/httpOnly-cookie flow is a later concern (auth.md, EPIC-14).
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String refreshToken;
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
/// public client, entirely client-side (no server session in the skeleton).
class AuthController extends AsyncNotifier<AuthSession?> {
  /// Test-only seams: production always uses the defaults (`createAuthPlatform()`
  /// / a real `http.Client`); unit tests pass a fake [AuthPlatform] and a
  /// `package:http/testing.dart` `MockClient` (e.g. via
  /// `authControllerProvider.overrideWith(() => AuthController(...))`) without
  /// touching the redirect-based web platform or the network.
  AuthController({AuthPlatform? platform, http.Client? httpClient})
    : _injectedPlatform = platform,
      _http = httpClient ?? http.Client();

  final AuthPlatform? _injectedPlatform;
  AuthPlatform? _platform;
  final http.Client _http;

  @override
  Future<AuthSession?> build() async {
    ref.onDispose(_http.close);
    try {
      final platform = _platform = _injectedPlatform ?? createAuthPlatform();
      final uri = platform.currentUri;
      final code = uri.queryParameters['code'];
      if (code != null) {
        final session = await _exchangeCode(platform, code, uri.queryParameters['state']);
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

  /// Starts login by redirecting the browser to Keycloak's authorize endpoint.
  Future<void> login() async {
    final platform = _platform ??= _injectedPlatform ?? createAuthPlatform();
    final pkce = Pkce.generate();
    final state = randomState();
    platform.writeSession(_kVerifier, pkce.verifier);
    platform.writeSession(_kState, state);

    final authorize = Uri.parse(AppConfig.oidcAuthorizeUrl).replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': AppConfig.oidcClientId,
        'redirect_uri': platform.redirectUri,
        'scope': 'openid profile email',
        'state': state,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
      },
    );
    platform.assignLocation(authorize.toString());
  }

  /// Logs out: revokes the server-side Keycloak SSO session via **RP-initiated
  /// logout** (`end_session_endpoint`, NFR-SEC-1) so a stolen/replayed refresh
  /// token can't outlive a "local-only" logout, then clears all local session
  /// state regardless of whether the network call succeeded (offline logout
  /// still degrades to locally-logged-out — D-10 doesn't require offline
  /// logout to reach Keycloak).
  ///
  /// Also disconnects/tears down the local PowerSync database (invalidating
  /// [powerSyncProvider], whose `onDispose` already calls `disconnect()` +
  /// `close()`) so a second user logging in on the same shared browser/device
  /// doesn't see the previous session's replicated rows before the next sync
  /// reconciles — the tenancy-holds-offline guarantee (auth.md §6.5) extends
  /// to the moment **between** sessions, not just within one.
  Future<void> logout() async {
    final refreshToken = state.value?.refreshToken;
    if (refreshToken != null && refreshToken.isNotEmpty) {
      try {
        await _http.post(
          Uri.parse(AppConfig.oidcEndSessionUrl),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: {
            'client_id': AppConfig.oidcClientId,
            'refresh_token': refreshToken,
          },
        );
      } catch (_) {
        // Offline logout: still clear local state below so the user isn't
        // stuck "logged in" locally. The Keycloak SSO session/cookie will
        // outlive this device until it expires naturally.
      }
    }
    _clearLocalSession();
    ref.invalidate(powerSyncProvider);
    state = const AsyncData(null);
  }

  /// Defensive sweep of every local-storage key this controller ever writes —
  /// not just the refresh token — so an abandoned mid-flow login (PKCE
  /// verifier/state written but never exchanged) can't leave stale entries.
  void _clearLocalSession() {
    final platform = _platform;
    platform?.removeSession(_kVerifier);
    platform?.removeSession(_kState);
    platform?.removeSession(_kRefresh);
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

  Future<AuthSession?> _exchangeCode(AuthPlatform platform, String code, String? state) async {
    final expected = platform.readSession(_kState);
    if (expected != null && state != expected) {
      throw StateError('OAuth state mismatch');
    }
    final verifier = platform.readSession(_kVerifier);
    final resp = await _http.post(
      Uri.parse(AppConfig.oidcTokenUrl),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': platform.redirectUri,
        'client_id': AppConfig.oidcClientId,
        if (verifier != null) 'code_verifier': verifier,
      },
    );
    platform.removeSession(_kVerifier);
    platform.removeSession(_kState);
    if (resp.statusCode != 200) {
      throw StateError('token exchange failed: ${resp.statusCode}');
    }
    return _sessionFromJson(platform, jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<AuthSession?> _refresh(AuthPlatform platform, String refreshToken) async {
    final resp = await _http.post(
      Uri.parse(AppConfig.oidcTokenUrl),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': AppConfig.oidcClientId,
      },
    );
    if (resp.statusCode != 200) {
      platform.removeSession(_kRefresh);
      return null;
    }
    return _sessionFromJson(platform, jsonDecode(resp.body) as Map<String, dynamic>);
  }

  AuthSession _sessionFromJson(AuthPlatform platform, Map<String, dynamic> json) {
    final access = json['access_token'] as String;
    final refresh = (json['refresh_token'] as String?) ?? '';
    final expiresIn = (json['expires_in'] as num?)?.toInt() ?? 300;
    if (refresh.isNotEmpty) platform.writeSession(_kRefresh, refresh);
    return AuthSession(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: DateTime.now().add(Duration(seconds: expiresIn)),
    );
  }
}
