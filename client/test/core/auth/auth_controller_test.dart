import 'dart:convert';

import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/auth/auth_platform.dart';
import 'package:beekeepingit_client/core/config/app_config.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// An in-memory [AuthPlatform] fake — no browser, no `package:web`, so these
/// tests run on the VM like the rest of `client/test/`.
class FakeAuthPlatform implements AuthPlatform {
  FakeAuthPlatform({Uri? initialUri})
    : currentUri = initialUri ?? Uri.parse('https://app.example/apiaries');

  @override
  String get redirectUri => 'https://app.example/';

  @override
  Uri currentUri;

  String? assignedLocation;
  Uri? replacedUri;
  final Map<String, String> _session = {};

  @override
  void assignLocation(String url) => assignedLocation = url;

  @override
  void replaceLocation(Uri uri) => replacedUri = uri;

  @override
  String? readSession(String key) => _session[key];

  @override
  void writeSession(String key, String value) => _session[key] = value;

  @override
  void removeSession(String key) => _session.remove(key);

  bool get hasAnySession => _session.isNotEmpty;
}

/// Builds a container with a session already populated by driving the real
/// code-exchange path in `build()` (rather than poking notifier internals),
/// so `accessToken()`/`logout()` tests start from a realistic logged-in state.
/// The seed session's access/refresh token values and expiry come entirely
/// from what [client] returns for the code-exchange POST.
Future<(ProviderContainer, FakeAuthPlatform, AuthController)> buildLoggedInContainer({
  required http.Client client,
}) async {
  final platform = FakeAuthPlatform(
    initialUri: Uri.parse('https://app.example/?code=seed-code&state=seed-state'),
  );
  platform.writeSession('bk.oauth_state', 'seed-state');

  final container = ProviderContainer(
    overrides: [
      authControllerProvider.overrideWith(
        () => AuthController(platform: platform, httpClient: client),
      ),
    ],
  );
  addTearDown(container.dispose);

  final session = await container.read(authControllerProvider.future);
  expect(session, isNotNull, reason: 'seed login via code-exchange must succeed');

  final notifier = container.read(authControllerProvider.notifier);
  return (container, platform, notifier);
}

http.Response _tokenResponse({
  String access = 'access-1',
  String refresh = 'refresh-1',
  int expiresIn = 300,
}) {
  return http.Response(
    jsonEncode({
      'access_token': access,
      'refresh_token': refresh,
      'expires_in': expiresIn,
      'token_type': 'Bearer',
    }),
    200,
  );
}

void main() {
  group('login()', () {
    test('redirects to the authorize URL with PKCE challenge/state/redirect_uri', () async {
      final platform = FakeAuthPlatform();
      final client = MockClient((req) async => http.Response('not found', 404));
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(
            () => AuthController(platform: platform, httpClient: client),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authControllerProvider.future);

      await container.read(authControllerProvider.notifier).login();

      expect(platform.assignedLocation, isNotNull);
      final uri = Uri.parse(platform.assignedLocation!);
      expect(uri.toString(), startsWith(AppConfig.oidcAuthorizeUrl));
      expect(uri.queryParameters['response_type'], 'code');
      expect(uri.queryParameters['client_id'], AppConfig.oidcClientId);
      expect(uri.queryParameters['redirect_uri'], platform.redirectUri);
      expect(uri.queryParameters['code_challenge_method'], 'S256');
      expect(uri.queryParameters['code_challenge'], isNotEmpty);
      expect(uri.queryParameters['state'], isNotEmpty);

      // The verifier/state are persisted so the callback can validate them.
      expect(platform.readSession('bk.pkce_verifier'), isNotEmpty);
      expect(platform.readSession('bk.oauth_state'), uri.queryParameters['state']);
    });
  });

  group('code exchange (build())', () {
    test('success populates AuthSession and persists the refresh token', () async {
      final client = MockClient((req) async {
        expect(req.url.toString(), AppConfig.oidcTokenUrl);
        final body = Uri(query: req.body).queryParameters;
        expect(body['grant_type'], 'authorization_code');
        expect(body['code'], 'the-code');
        expect(body['code_verifier'], 'verifier-abc');
        return _tokenResponse(access: 'access-xyz', refresh: 'refresh-xyz');
      });

      final platform = FakeAuthPlatform(
        initialUri: Uri.parse('https://app.example/?code=the-code&state=state-abc'),
      );
      platform.writeSession('bk.oauth_state', 'state-abc');
      platform.writeSession('bk.pkce_verifier', 'verifier-abc');

      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(
            () => AuthController(platform: platform, httpClient: client),
          ),
        ],
      );
      addTearDown(container.dispose);

      final session = await container.read(authControllerProvider.future);

      expect(session, isNotNull);
      expect(session!.accessToken, 'access-xyz');
      expect(session.refreshToken, 'refresh-xyz');
      expect(platform.readSession('bk.refresh_token'), 'refresh-xyz');
      // Callback params are stripped from the URL after exchange.
      expect(platform.replacedUri?.queryParameters, isEmpty);
      // Single-use PKCE artifacts are removed after the exchange.
      expect(platform.readSession('bk.pkce_verifier'), isNull);
      expect(platform.readSession('bk.oauth_state'), isNull);
    });

    test('mismatched state throws (rejects CSRF) and session stays logged out', () async {
      final client = MockClient((req) async => _tokenResponse());
      final platform = FakeAuthPlatform(
        initialUri: Uri.parse('https://app.example/?code=the-code&state=attacker-state'),
      );
      platform.writeSession('bk.oauth_state', 'expected-state');

      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(
            () => AuthController(platform: platform, httpClient: client),
          ),
        ],
      );
      addTearDown(container.dispose);

      final session = await container.read(authControllerProvider.future);
      // build() swallows the StateError (matches non-web/transient handling)
      // and resolves to logged-out rather than throwing out of the provider.
      expect(session, isNull);
    });
  });

  group('accessToken()', () {
    test('returns the cached token when not expired', () async {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add(req.url.toString());
        // Seed exchange only; a second call here would mean an unwanted refresh.
        return _tokenResponse(expiresIn: 300);
      });
      final (_, _, notifier) = await buildLoggedInContainer(client: client);
      calls.clear(); // ignore the seed code-exchange call itself

      final token = await notifier.accessToken();
      expect(token, 'access-1');
      expect(calls, isEmpty); // no refresh network call made — still fresh
    });

    test('refreshes when the access token is within 30s of expiry', () async {
      final client = MockClient((req) async {
        final body = Uri(query: req.body).queryParameters;
        if (body['grant_type'] == 'refresh_token') {
          return _tokenResponse(access: 'refreshed-token', refresh: 'refresh-2');
        }
        // Seed code-exchange: expire almost immediately so accessToken() refreshes.
        return _tokenResponse(expiresIn: 5);
      });
      final (_, platform, notifier) = await buildLoggedInContainer(client: client);

      final token = await notifier.accessToken();
      expect(token, 'refreshed-token');
      expect(platform.readSession('bk.refresh_token'), 'refresh-2');
    });
  });

  group('refresh-token-rejected', () {
    test('a 400/401 from Keycloak clears the session without throwing', () async {
      final client = MockClient((req) async {
        final body = Uri(query: req.body).queryParameters;
        if (body['grant_type'] == 'refresh_token') {
          return http.Response('invalid_grant', 400);
        }
        // Seed code-exchange: expire almost immediately to force a refresh.
        return _tokenResponse(refresh: 'revoked-refresh', expiresIn: 5);
      });
      final (_, platform, notifier) = await buildLoggedInContainer(client: client);

      final token = await notifier.accessToken();

      expect(token, isNull);
      expect(notifier.state.value, isNull);
      expect(platform.readSession('bk.refresh_token'), isNull);
    });
  });

  group('logout()', () {
    test('calls the end-session endpoint and clears all local session keys', () async {
      final endSessionCalls = <Uri>[];
      final client = MockClient((req) async {
        if (req.url.toString() == AppConfig.oidcEndSessionUrl) {
          endSessionCalls.add(req.url);
          final body = Uri(query: req.body).queryParameters;
          expect(body['client_id'], AppConfig.oidcClientId);
          expect(body['refresh_token'], 'refresh-1');
          return http.Response('', 204);
        }
        return _tokenResponse(); // seed code-exchange
      });
      final (_, platform, notifier) = await buildLoggedInContainer(client: client);
      // A leftover mid-flow-login artifact the defensive sweep must also clear.
      platform.writeSession('bk.pkce_verifier', 'leftover-verifier');

      await notifier.logout();

      expect(endSessionCalls, hasLength(1));
      expect(notifier.state.value, isNull);
      expect(platform.hasAnySession, isFalse);
    });

    test('degrades gracefully to locally-logged-out when the network call fails', () async {
      final client = MockClient((req) async {
        if (req.url.toString() == AppConfig.oidcEndSessionUrl) {
          throw const http.ClientException('offline');
        }
        return _tokenResponse(); // seed code-exchange
      });
      final (_, platform, notifier) = await buildLoggedInContainer(client: client);

      await notifier.logout();

      expect(notifier.state.value, isNull);
      expect(platform.hasAnySession, isFalse);
    });

    test('logging out with no session (already logged out) does not call end-session', () async {
      final endSessionCalls = <Uri>[];
      final client = MockClient((req) async {
        endSessionCalls.add(req.url);
        return http.Response('', 204);
      });
      final platform = FakeAuthPlatform();
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(
            () => AuthController(platform: platform, httpClient: client),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(authControllerProvider.future); // no code/refresh in URL → null session
      final notifier = container.read(authControllerProvider.notifier);

      await notifier.logout();

      expect(endSessionCalls, isEmpty);
      expect(notifier.state.value, isNull);
    });
  });
}
