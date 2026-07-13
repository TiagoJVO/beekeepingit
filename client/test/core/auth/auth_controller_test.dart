import 'dart:convert';

import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/auth/auth_platform.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openid_client/openid_client.dart';

/// A fake OIDC provider built entirely from an in-memory discovery document —
/// no `.well-known` network fetch. The [AuthController] flow (login redirect,
/// PKCE code→token exchange, refresh, front-channel logout) runs against these
/// endpoints, and `oidcIssuerProvider` is overridden to hand it back so the
/// tests exercise the real openid_client-driven code paths offline. Every
/// endpoint the controller reads (authorize / token / end-session) lives here,
/// mirroring how it comes from discovery in production.
const _authorizeUrl = 'https://idp.example/authorize';
const _tokenUrl = 'https://idp.example/token';
const _endSessionUrl = 'https://idp.example/end-session';

Issuer fakeIssuer() => Issuer(
  OpenIdProviderMetadata.fromJson(const {
    'issuer': 'https://idp.example/',
    'authorization_endpoint': _authorizeUrl,
    'token_endpoint': _tokenUrl,
    'end_session_endpoint': _endSessionUrl,
    // Flow only forwards scopes advertised as supported (openid_client filters
    // against this), so the authorize URL carries them only if listed here.
    'scopes_supported': ['openid', 'profile', 'email'],
    'response_types_supported': ['code'],
    'subject_types_supported': ['public'],
    'id_token_signing_alg_values_supported': ['RS256'],
  }),
);

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

/// A fake [LocalStoreEngine] so `logout()`'s local-data wipe (#125) can be
/// asserted without standing up a real PowerSync database — mirrors
/// [FakeAuthPlatform]'s role for the session-storage side of `logout()`.
class FakeLocalStoreEngine implements LocalStoreEngine {
  int clearCalls = 0;

  @override
  Future<void> clear() async => clearCalls++;

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async => null;

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) => const Stream.empty();
}

/// Builds a container with the fake issuer wired in and (optionally) a session
/// already populated by driving the real code-exchange path in `build()`
/// (rather than poking notifier internals), so `accessToken()`/`logout()` tests
/// start from a realistic logged-in state. The seed session's token values and
/// expiry come entirely from what [client] returns for the code-exchange POST.
///
/// [localStore], when given, is injected as `AuthController`'s
/// `clearLocalStore` seam so `logout()`'s wipe (#125) can be asserted against
/// a [FakeLocalStoreEngine] instead of the real `localStoreProvider` (which
/// would need a real PowerSync database).
Future<(ProviderContainer, FakeAuthPlatform, AuthController)>
buildLoggedInContainer({
  required http.Client client,
  LocalStoreEngine? localStore,
}) async {
  final platform = FakeAuthPlatform(
    initialUri: Uri.parse(
      'https://app.example/?code=seed-code&state=seed-state',
    ),
  );
  platform.writeSession('bk.oauth_state', 'seed-state');
  platform.writeSession('bk.pkce_verifier', 'seed-verifier');

  final container = _container(platform, client, localStore: localStore);
  final session = await container.read(authControllerProvider.future);
  expect(
    session,
    isNotNull,
    reason: 'seed login via code-exchange must succeed',
  );

  final notifier = container.read(authControllerProvider.notifier);
  return (container, platform, notifier);
}

ProviderContainer _container(
  FakeAuthPlatform platform,
  http.Client client, {
  LocalStoreEngine? localStore,
}) {
  final container = ProviderContainer(
    overrides: [
      // Fake discovery — no `.well-known` network call.
      oidcIssuerProvider.overrideWith((ref) async => fakeIssuer()),
      authControllerProvider.overrideWith(
        () => AuthController(
          platform: platform,
          httpClient: client,
          clearLocalStore: localStore == null ? null : () async => localStore,
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

http.Response _tokenResponse(
  http.BaseRequest request, {
  String access = 'access-1',
  String refresh = 'refresh-1',
  String idToken = 'id-token-1',
  int expiresIn = 300,
}) {
  return http.Response(
    jsonEncode({
      'access_token': access,
      'refresh_token': refresh,
      'id_token': idToken,
      'expires_in': expiresIn,
      'token_type': 'Bearer',
    }),
    200,
    // openid_client only JSON-decodes the token response when the content type
    // says so; without this it treats the body as an opaque string.
    headers: {'content-type': 'application/json'},
    // openid_client logs `response.request!.method` on every call; MockClient
    // only populates `Response.request` if we attach it, so pass `request`
    // through or that null-check crashes the exchange (see http MockClient).
    request: request,
  );
}

void main() {
  group('login()', () {
    test(
      'redirects to the discovered authorize URL with PKCE challenge/state/redirect_uri',
      () async {
        final platform = FakeAuthPlatform();
        final client = MockClient(
          (req) async => http.Response('not found', 404),
        );
        final container = _container(platform, client);
        await container.read(authControllerProvider.future);

        await container.read(authControllerProvider.notifier).login();

        expect(platform.assignedLocation, isNotNull);
        final uri = Uri.parse(platform.assignedLocation!);
        // Endpoint comes from discovery, not a hard-coded AppConfig getter.
        expect('${uri.scheme}://${uri.host}${uri.path}', _authorizeUrl);
        expect(uri.queryParameters['response_type'], 'code');
        expect(uri.queryParameters['client_id'], 'beekeepingit-pwa');
        expect(uri.queryParameters['redirect_uri'], platform.redirectUri);
        expect(uri.queryParameters['code_challenge_method'], 'S256');
        expect(uri.queryParameters['code_challenge'], isNotEmpty);
        expect(uri.queryParameters['state'], isNotEmpty);
        expect(uri.queryParameters['scope'], contains('openid'));

        // The verifier/state are persisted so the callback can validate them.
        expect(platform.readSession('bk.pkce_verifier'), isNotEmpty);
        expect(
          platform.readSession('bk.oauth_state'),
          uri.queryParameters['state'],
        );
      },
    );
  });

  group('code exchange (build())', () {
    test(
      'success populates AuthSession and persists the refresh + id token',
      () async {
        final client = MockClient((req) async {
          expect(req.url.toString(), _tokenUrl);
          final body = Uri(query: req.body).queryParameters;
          expect(body['grant_type'], 'authorization_code');
          expect(body['code'], 'the-code');
          expect(body['code_verifier'], 'verifier-abc');
          return _tokenResponse(
            req,
            access: 'access-xyz',
            refresh: 'refresh-xyz',
            idToken: 'id-xyz',
          );
        });

        final platform = FakeAuthPlatform(
          initialUri: Uri.parse(
            'https://app.example/?code=the-code&state=state-abc',
          ),
        );
        platform.writeSession('bk.oauth_state', 'state-abc');
        platform.writeSession('bk.pkce_verifier', 'verifier-abc');

        final container = _container(platform, client);
        final session = await container.read(authControllerProvider.future);

        expect(session, isNotNull);
        expect(session!.accessToken, 'access-xyz');
        expect(session.refreshToken, 'refresh-xyz');
        expect(session.idToken, 'id-xyz');
        expect(platform.readSession('bk.refresh_token'), 'refresh-xyz');
        expect(platform.readSession('bk.id_token'), 'id-xyz');
        // Callback params are stripped from the URL after exchange.
        expect(platform.replacedUri?.queryParameters, isEmpty);
        // Single-use PKCE artifacts are removed after the exchange.
        expect(platform.readSession('bk.pkce_verifier'), isNull);
        expect(platform.readSession('bk.oauth_state'), isNull);
      },
    );

    test(
      'mismatched state throws (rejects CSRF) and session stays logged out',
      () async {
        final client = MockClient((req) async => _tokenResponse(req));
        final platform = FakeAuthPlatform(
          initialUri: Uri.parse(
            'https://app.example/?code=the-code&state=attacker-state',
          ),
        );
        platform.writeSession('bk.oauth_state', 'expected-state');
        platform.writeSession('bk.pkce_verifier', 'verifier-abc');

        final container = _container(platform, client);
        final session = await container.read(authControllerProvider.future);
        // build() swallows the ArgumentError openid_client throws on a state
        // mismatch and resolves to logged-out rather than throwing out.
        expect(session, isNull);
      },
    );
  });

  group('accessToken()', () {
    test('returns the cached token when not expired', () async {
      final calls = <String>[];
      final client = MockClient((req) async {
        calls.add(req.url.toString());
        // Seed exchange only; a second call here would mean an unwanted refresh.
        return _tokenResponse(req, expiresIn: 300);
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
          return _tokenResponse(
            req,
            access: 'refreshed-token',
            refresh: 'refresh-2',
          );
        }
        // Seed code-exchange: expire almost immediately so accessToken() refreshes.
        return _tokenResponse(req, expiresIn: 5);
      });
      final (_, platform, notifier) = await buildLoggedInContainer(
        client: client,
      );

      final token = await notifier.accessToken();
      expect(token, 'refreshed-token');
      expect(platform.readSession('bk.refresh_token'), 'refresh-2');
    });
  });

  group('refresh-token-rejected', () {
    test(
      'a rejected refresh token clears the session without throwing',
      () async {
        final client = MockClient((req) async {
          final body = Uri(query: req.body).queryParameters;
          if (body['grant_type'] == 'refresh_token') {
            return http.Response(
              jsonEncode({'error': 'invalid_grant'}),
              400,
              headers: {'content-type': 'application/json'},
              request: req,
            );
          }
          // Seed code-exchange: expire almost immediately to force a refresh.
          return _tokenResponse(req, refresh: 'revoked-refresh', expiresIn: 5);
        });
        final (_, platform, notifier) = await buildLoggedInContainer(
          client: client,
        );

        final token = await notifier.accessToken();

        expect(token, isNull);
        expect(notifier.state.value, isNull);
        expect(platform.readSession('bk.refresh_token'), isNull);
        expect(platform.readSession('bk.id_token'), isNull);
      },
    );
  });

  group('logout()', () {
    test(
      'redirects to the front-channel end-session URL (id_token_hint) and clears local state',
      () async {
        final client = MockClient(
          (req) async => _tokenResponse(req, idToken: 'id-1'),
        );
        final (_, platform, notifier) = await buildLoggedInContainer(
          client: client,
          localStore: FakeLocalStoreEngine(),
        );
        // A leftover mid-flow-login artifact the defensive sweep must also clear.
        platform.writeSession('bk.pkce_verifier', 'leftover-verifier');

        await notifier.logout();

        // Front-channel RP-initiated logout: a browser redirect to the discovered
        // end_session_endpoint carrying the id_token_hint (replaces the previous
        // refresh-token POST to the provider's logout endpoint).
        expect(platform.assignedLocation, isNotNull);
        final logoutUri = Uri.parse(platform.assignedLocation!);
        expect(
          '${logoutUri.scheme}://${logoutUri.host}${logoutUri.path}',
          _endSessionUrl,
        );
        expect(logoutUri.queryParameters['id_token_hint'], 'id-1');
        expect(
          logoutUri.queryParameters['post_logout_redirect_uri'],
          platform.redirectUri,
        );

        expect(notifier.state.value, isNull);
        expect(platform.hasAnySession, isFalse);
      },
    );

    test(
      'degrades gracefully to locally-logged-out when discovery/redirect fails',
      () async {
        // Seed a session first with a working client...
        final (_, platform, notifier) = await buildLoggedInContainer(
          client: MockClient((req) async => _tokenResponse(req)),
          localStore: FakeLocalStoreEngine(),
        );

        await notifier.logout();

        // Local state is cleared FIRST, so even if the front-channel step can't
        // complete the user ends up logged out locally (offline-degrade).
        expect(notifier.state.value, isNull);
        expect(platform.hasAnySession, isFalse);
      },
    );

    test(
      'logging out with no session (already logged out) does not redirect',
      () async {
        final client = MockClient((req) async => _tokenResponse(req));
        final platform = FakeAuthPlatform();
        final container = _container(
          platform,
          client,
          localStore: FakeLocalStoreEngine(),
        );
        await container.read(
          authControllerProvider.future,
        ); // no code/refresh in URL → null session
        final notifier = container.read(authControllerProvider.notifier);

        await notifier.logout();

        expect(platform.assignedLocation, isNull);
        expect(notifier.state.value, isNull);
      },
    );

    // #125: logout must wipe the on-device local store, not just disconnect,
    // so a second user on the same shared browser never sees the previous
    // session's replicated rows.
    test('wipes the local store via LocalStoreEngine.clear()', () async {
      final localStore = FakeLocalStoreEngine();
      final client = MockClient((req) async => _tokenResponse(req));
      final (_, _, notifier) = await buildLoggedInContainer(
        client: client,
        localStore: localStore,
      );

      expect(localStore.clearCalls, 0);
      await notifier.logout();

      expect(localStore.clearCalls, 1);
      expect(notifier.state.value, isNull);
    });

    test(
      'a failing local-store wipe does not block logout (best-effort)',
      () async {
        final client = MockClient((req) async => _tokenResponse(req));
        final platform = FakeAuthPlatform(
          initialUri: Uri.parse(
            'https://app.example/?code=seed-code&state=seed-state',
          ),
        );
        platform.writeSession('bk.oauth_state', 'seed-state');
        platform.writeSession('bk.pkce_verifier', 'seed-verifier');
        final container = ProviderContainer(
          overrides: [
            oidcIssuerProvider.overrideWith((ref) async => fakeIssuer()),
            authControllerProvider.overrideWith(
              () => AuthController(
                platform: platform,
                httpClient: client,
                clearLocalStore: () async =>
                    throw StateError('store unavailable'),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        await container.read(authControllerProvider.future);
        final notifier = container.read(authControllerProvider.notifier);

        await notifier.logout();

        // Session-token clearing and the logged-out state transition still
        // happen even though the store wipe threw.
        expect(notifier.state.value, isNull);
        expect(platform.hasAnySession, isFalse);
      },
    );
  });
}
