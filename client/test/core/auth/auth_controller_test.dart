import 'dart:convert';

import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/auth/auth_platform.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
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
    // `offline_access` is advertised so the controller's request for it (#236)
    // survives that filter — mirrors the Authentik provider blueprint, which
    // maps offline_access + the refresh_token grant.
    'scopes_supported': ['openid', 'profile', 'email', 'offline_access'],
    'response_types_supported': ['code'],
    'subject_types_supported': ['public'],
    'id_token_signing_alg_values_supported': ['RS256'],
  }),
);

/// An in-memory [AuthPlatform] fake — no browser, no `package:web`, so these
/// tests run on the VM like the rest of `client/test/`. Models
/// sessionStorage and localStorage as two genuinely separate maps (#390) so
/// tests can exercise the sessionStorage→localStorage migration and prove a
/// simulated "browser restart" (which wipes sessionStorage but not
/// localStorage) still restores a session.
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
  final Map<String, String> _local = {};

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

  @override
  String? readLocal(String key) => _local[key];

  @override
  void writeLocal(String key, String value) => _local[key] = value;

  @override
  void removeLocal(String key) => _local.remove(key);

  bool get hasAnySession => _session.isNotEmpty;
  bool get hasAnyLocal => _local.isNotEmpty;

  /// Simulates a full browser restart: sessionStorage is per-tab and wiped
  /// (#390's reported bug), but localStorage — and thus anything already
  /// migrated/persisted there — survives.
  void simulateBrowserRestart({Uri? newUri}) {
    _session.clear();
    if (newUri != null) currentUri = newUri;
  }
}

/// An in-memory [LocalPrefs] fake for the onboarding-cache-clearing
/// assertions (#390) — mirrors [FakeAuthPlatform]'s role for session storage.
class FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> _store = {};

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);

  bool get isEmpty => _store.isEmpty;
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
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => const [];

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
/// would need a real PowerSync database). [localPrefs], when given, is
/// injected so the onboarding-cache-clearing assertions (#390) can be made
/// against a [FakeLocalPrefs] instead of the real (VM-stubbed, always-empty)
/// `createLocalPrefs()`.
Future<(ProviderContainer, FakeAuthPlatform, AuthController)>
buildLoggedInContainer({
  required http.Client client,
  LocalStoreEngine? localStore,
  LocalPrefs? localPrefs,
}) async {
  final platform = FakeAuthPlatform(
    initialUri: Uri.parse(
      'https://app.example/?code=seed-code&state=seed-state',
    ),
  );
  platform.writeSession('bk.oauth_state', 'seed-state');
  platform.writeSession('bk.pkce_verifier', 'seed-verifier');

  final container = _container(
    platform,
    client,
    localStore: localStore,
    localPrefs: localPrefs,
  );
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
  LocalPrefs? localPrefs,
  Duration? authNetworkTimeout,
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
          localPrefs: localPrefs,
          authNetworkTimeout: authNetworkTimeout,
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
  group('AuthSession value equality (MEDIUM-2)', () {
    // Built via a runtime function (not a `const` literal) so two "equal"
    // instances are genuinely distinct objects, not the same
    // const-canonicalized instance — otherwise this would pass even
    // without a custom `operator==`.
    AuthSession session({String access = 'a', DateTime? expiresAt}) =>
        AuthSession(
          accessToken: access,
          refreshToken: 'r',
          idToken: 'i',
          expiresAt: expiresAt ?? DateTime.utc(2026, 1, 1),
        );

    test('two distinct instances with the same fields are ==', () {
      final a = session();
      final b = session();

      expect(identical(a, b), isFalse, reason: 'test setup sanity check');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('instances differing in any field are not ==', () {
      final base = session();

      expect(base, isNot(equals(session(access: 'other'))));
      expect(base, isNot(equals(session(expiresAt: DateTime.utc(2026, 2, 1)))));
    });
  });

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
        final requestedScopes = (uri.queryParameters['scope'] ?? '').split(' ');
        expect(requestedScopes, contains('openid'));
        // #236: `offline_access` MUST be requested so the provider issues a
        // refresh token — build() restores a session on reload only from a
        // persisted refresh token, so omitting this logs the user out on a full
        // page reload (auth.md §7). Guards against a silent regression.
        expect(
          requestedScopes,
          contains('offline_access'),
          reason:
              'offline_access must be requested so a refresh token is issued '
              'for session restore on reload (#236, auth.md §7)',
        );

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
        // Durable storage (localStorage, #390) — not sessionStorage.
        expect(platform.readLocal('bk.refresh_token'), 'refresh-xyz');
        expect(platform.readLocal('bk.id_token'), 'id-xyz');
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
      expect(platform.readLocal('bk.refresh_token'), 'refresh-2');
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
        final localStore = FakeLocalStoreEngine();
        final (_, platform, notifier) = await buildLoggedInContainer(
          client: client,
          localStore: localStore,
        );

        final token = await notifier.accessToken();

        expect(token, isNull);
        expect(notifier.state.value, isNull);
        expect(platform.readLocal('bk.refresh_token'), isNull);
        expect(platform.readLocal('bk.id_token'), isNull);
        // #390 regression: a genuine provider rejection must NOT wipe the
        // on-device PowerSync local store — that wipe stays exclusive to
        // explicit logout()/membership-loss purge (auth_controller.dart's
        // own `_refresh` note), so any queued offline writes survive a
        // subsequent re-login.
        expect(localStore.clearCalls, 0);
      },
    );
  });

  group('refresh-network-failure', () {
    test('refresh fails due to a network error, not rejection → session/tokens '
        'are retained', () async {
      final client = MockClient((req) async {
        final body = Uri(query: req.body).queryParameters;
        if (body['grant_type'] == 'refresh_token') {
          // A network/discovery failure while offline — distinct from a
          // provider-rejected grant (OpenIdException, covered by the
          // refresh-token-rejected group above). Offline-first: this must
          // NOT be treated the same as an explicit rejection.
          throw http.ClientException('Failed host lookup');
        }
        // Seed code-exchange: expire almost immediately to force a refresh.
        return _tokenResponse(req, refresh: 'refresh-keep', expiresIn: 5);
      });
      final (_, platform, notifier) = await buildLoggedInContainer(
        client: client,
      );

      final token = await notifier.accessToken();

      // The refresh token was never rejected — just unreachable — so the
      // session must be retained rather than wiped, and the stale access
      // token is still handed back rather than null.
      expect(token, 'access-1');
      expect(notifier.state.value, isNotNull);
      expect(platform.readLocal('bk.refresh_token'), 'refresh-keep');
      expect(platform.readLocal('bk.id_token'), isNotEmpty);
    });
  });

  group('session restore on boot (build()) — offline-first auth (#390)', () {
    test('restores the session from localStorage after a simulated browser '
        'restart (sessionStorage wiped, localStorage survives)', () async {
      // First "browser session": log in normally, which persists the
      // refresh/id token to localStorage (auth_controller.dart's
      // `_persist`).
      final client = MockClient((req) async {
        final body = Uri(query: req.body).queryParameters;
        if (body['grant_type'] == 'refresh_token') {
          return _tokenResponse(
            req,
            access: 'access-after-restart',
            refresh: 'refresh-after-restart',
          );
        }
        return _tokenResponse(req, refresh: 'refresh-before-restart');
      });
      final (container, platform, _) = await buildLoggedInContainer(
        client: client,
      );
      expect(platform.readLocal('bk.refresh_token'), 'refresh-before-restart');

      // Simulate the browser closing and reopening: sessionStorage (PKCE
      // artifacts, and pre-#390 this would have held the tokens too) is
      // wiped; localStorage is not. A fresh container/notifier stands in
      // for the fresh page load — build() must re-run and restore.
      platform.simulateBrowserRestart(
        newUri: Uri.parse('https://app.example/apiaries'),
      );
      container.dispose();
      final freshContainer = _container(platform, client);
      addTearDown(freshContainer.dispose);

      final restored = await freshContainer.read(authControllerProvider.future);

      expect(restored, isNotNull);
      expect(restored!.accessToken, 'access-after-restart');
      expect(restored.refreshToken, 'refresh-after-restart');
      expect(restored.isExpired, isFalse);
    });

    test(
      'sessionStorage→localStorage migration: a refresh token left over from '
      'before #390 is restored and rewritten to localStorage',
      () async {
        final platform = FakeAuthPlatform();
        // Simulates a pre-#390 session: tokens were written to sessionStorage.
        platform.writeSession('bk.refresh_token', 'legacy-refresh');
        platform.writeSession('bk.id_token', 'legacy-id');
        final client = MockClient(
          (req) async => _tokenResponse(
            req,
            access: 'migrated-access',
            refresh: 'migrated-refresh',
          ),
        );

        final container = _container(platform, client);
        addTearDown(container.dispose);
        final session = await container.read(authControllerProvider.future);

        expect(session, isNotNull);
        expect(session!.accessToken, 'migrated-access');
        // The legacy value migrated to localStorage...
        expect(platform.readLocal('bk.refresh_token'), 'migrated-refresh');
        // ...and no longer lives in sessionStorage.
        expect(platform.readSession('bk.refresh_token'), isNull);
      },
    );

    test(
      'offline boot (network failure restoring the session) resolves to a '
      'stale placeholder session, keeping the refresh token — not null',
      () async {
        final platform = FakeAuthPlatform();
        platform.writeLocal('bk.refresh_token', 'refresh-offline');
        platform.writeLocal('bk.id_token', 'id-offline');
        final client = MockClient((req) async {
          throw http.ClientException('Failed host lookup');
        });

        final container = _container(platform, client);
        addTearDown(container.dispose);
        final session = await container.read(authControllerProvider.future);

        expect(session, isNotNull);
        expect(session!.accessToken, isEmpty);
        expect(session.refreshToken, 'refresh-offline');
        expect(session.idToken, 'id-offline');
        expect(session.isExpired, isTrue);
        // The refresh token was never rejected — just unreachable — so it
        // must be retained for the next accessToken() retry, not wiped.
        expect(platform.readLocal('bk.refresh_token'), 'refresh-offline');

        // accessToken() must not hand back the empty placeholder token as a
        // bogus bearer token.
        final notifier = container.read(authControllerProvider.notifier);
        final token = await notifier.accessToken();
        expect(token, isNull);
      },
    );

    test('a provider rejection while restoring on boot clears the session and '
        'resolves to null (re-login required)', () async {
      final platform = FakeAuthPlatform();
      platform.writeLocal('bk.refresh_token', 'revoked-refresh');
      platform.writeLocal('bk.id_token', 'id-revoked');
      final client = MockClient(
        (req) async => http.Response(
          jsonEncode({'error': 'invalid_grant'}),
          400,
          headers: {'content-type': 'application/json'},
          request: req,
        ),
      );

      final localStore = FakeLocalStoreEngine();
      final container = ProviderContainer(
        overrides: [
          oidcIssuerProvider.overrideWith((ref) async => fakeIssuer()),
          authControllerProvider.overrideWith(
            () => AuthController(
              platform: platform,
              httpClient: client,
              clearLocalStore: () async => localStore,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final session = await container.read(authControllerProvider.future);

      expect(session, isNull);
      expect(platform.readLocal('bk.refresh_token'), isNull);
      expect(platform.readLocal('bk.id_token'), isNull);
      // Rejection must not wipe the on-device PowerSync local store — that
      // wipe stays exclusive to explicit logout()/membership-loss purge.
      expect(localStore.clearCalls, 0);
    });

    test('a discovery/refresh hang during boot restore completes within the '
        'bounded timeout, falling back to a stale session', () async {
      final platform = FakeAuthPlatform();
      platform.writeLocal('bk.refresh_token', 'refresh-slow-link');
      final client = MockClient((req) async {
        // Never resolves within the test's short injected timeout —
        // stands in for a dead/very slow link during the refresh-token
        // POST. Long enough to prove the boot path doesn't wait for it,
        // short enough not to slow the suite down.
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return _tokenResponse(req);
      });

      final container = _container(
        platform,
        client,
        // A short injected timeout (test-only seam) stands in for the
        // real 5s `_kAuthNetworkTimeout` so this test stays fast.
        authNetworkTimeout: const Duration(milliseconds: 10),
      );
      addTearDown(container.dispose);

      final stopwatch = Stopwatch()..start();
      final session = await container.read(authControllerProvider.future);
      stopwatch.stop();

      expect(session, isNotNull);
      expect(session!.accessToken, isEmpty);
      expect(session.refreshToken, 'refresh-slow-link');
      expect(session.isExpired, isTrue);
      // Bounded well under the mock's 60ms delay — proves the timeout, not
      // the mock's own completion, produced this result.
      expect(stopwatch.elapsedMilliseconds, lessThan(50));
    });
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
        // #390: the refresh/id token now live in localStorage, not
        // sessionStorage — logout must clear that store too.
        expect(platform.hasAnyLocal, isFalse);
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
        expect(platform.hasAnyLocal, isFalse);
      },
    );

    // #390: onboarding gate cache clearing — a second user on the same
    // shared browser must never see a prior user's cached profile/org.
    test(
      'clears the onboarding cache (profile/organization snapshots)',
      () async {
        final prefs = FakeLocalPrefs();
        prefs.write(kProfileCacheKey, '{"id":"prior-user"}');
        prefs.write(kOrganizationCacheKey, '{"id":"prior-org"}');
        final client = MockClient((req) async => _tokenResponse(req));
        final (_, _, notifier) = await buildLoggedInContainer(
          client: client,
          localStore: FakeLocalStoreEngine(),
          localPrefs: prefs,
        );

        await notifier.logout();

        expect(prefs.isEmpty, isTrue);
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
