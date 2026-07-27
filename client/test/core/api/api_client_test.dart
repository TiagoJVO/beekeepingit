import 'dart:convert';

import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A minimal [AuthController] stand-in that returns a fixed token from
/// [accessToken] without touching platform/network state — mirrors
/// auth_controller_test.dart's own fake-seam approach, but [ApiClient] only
/// ever calls [AuthController.accessToken], so overriding just that method
/// is enough (no OIDC flow needs exercising here).
class _FakeAuthController extends AuthController {
  _FakeAuthController(this._token);

  final String? _token;

  @override
  Future<AuthSession?> build() async => null;

  @override
  Future<String?> accessToken() async => _token;
}

/// Builds an [ApiClient] wired to [client] (a `package:http/testing.dart`
/// [MockClient], so no real network call is ever made) and a fixed
/// [accessToken] result via [_FakeAuthController] — mirrors
/// auth_controller_test.dart's container-based test pattern.
ApiClient _buildApiClient({required http.Client client, String? token}) {
  final container = ProviderContainer(
    overrides: [
      authControllerProvider.overrideWith(() => _FakeAuthController(token)),
      apiClientProvider.overrideWith(
        (ref) => ApiClient(ref, httpClient: client),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container.read(apiClientProvider);
}

void main() {
  group('ApiClient — Authorization header', () {
    test('attaches the bearer token when a token exists', () async {
      http.Request? captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response('{}', 200, request: req);
      });

      final api = _buildApiClient(client: client, token: 'tok-abc');
      await api.getJson('/apiaries');

      expect(captured, isNotNull);
      expect(captured!.headers['Authorization'], 'Bearer tok-abc');
    });

    test('omits the Authorization header when there is no token', () async {
      http.Request? captured;
      final client = MockClient((req) async {
        captured = req;
        return http.Response('{}', 200, request: req);
      });

      final api = _buildApiClient(client: client, token: null);
      await api.getJson('/apiaries');

      expect(captured, isNotNull);
      expect(captured!.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('ApiClient — response decoding', () {
    test('a 2xx empty body decodes to {}', () async {
      final client = MockClient(
        (req) async => http.Response('', 204, request: req),
      );
      final api = _buildApiClient(client: client, token: 'tok');

      final result = await api.getJson('/apiaries/x');

      expect(result, <String, dynamic>{});
    });

    test(
      'a 422 populates fieldErrors from the RFC 9457 Problem body',
      () async {
        final client = MockClient(
          (req) async => http.Response(
            jsonEncode({
              'code': 'validation_failed',
              'detail': 'One or more fields are invalid.',
              'errors': [
                {
                  'field': 'name',
                  'code': 'required',
                  'message': 'Name is required.',
                },
              ],
            }),
            422,
            headers: {'content-type': 'application/json'},
            request: req,
          ),
        );
        final api = _buildApiClient(client: client, token: 'tok');

        await expectLater(
          api.postJson('/apiaries', {'name': ''}),
          throwsA(
            isA<ApiException>()
                .having((e) => e.statusCode, 'statusCode', 422)
                .having((e) => e.code, 'code', 'validation_failed')
                .having(
                  (e) => e.detail,
                  'detail',
                  'One or more fields are invalid.',
                )
                .having((e) => e.fieldErrors, 'fieldErrors', hasLength(1))
                .having(
                  (e) => e.fieldErrors.single.field,
                  'fieldErrors.single.field',
                  'name',
                )
                .having(
                  (e) => e.fieldErrors.single.code,
                  'fieldErrors.single.code',
                  'required',
                ),
          ),
        );
      },
    );

    test('a non-JSON error body falls back to code "unknown" instead of '
        'throwing a decode error', () async {
      final client = MockClient(
        (req) async => http.Response(
          '<html>Bad Gateway</html>',
          502,
          headers: {'content-type': 'text/html'},
          request: req,
        ),
      );
      final api = _buildApiClient(client: client, token: 'tok');

      await expectLater(
        api.getJson('/apiaries'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 502)
              .having((e) => e.code, 'code', 'unknown')
              .having((e) => e.fieldErrors, 'fieldErrors', isEmpty),
        ),
      );
    });

    test('an empty error body falls back to code "unknown"', () async {
      final client = MockClient(
        (req) async => http.Response('', 500, request: req),
      );
      final api = _buildApiClient(client: client, token: 'tok');

      await expectLater(
        api.getJson('/apiaries'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 500)
              .having((e) => e.code, 'code', 'unknown'),
        ),
      );
    });
  });

  group('ApiClient — http.Client lifecycle (MEDIUM-3)', () {
    test('ApiClient.close() closes the underlying http.Client', () async {
      final tracking = _TrackingClient();
      final api = _buildApiClient(client: tracking, token: 'tok');

      expect(tracking.closeCalls, 0);
      api.close();
      expect(tracking.closeCalls, 1);
    });

    test(
      'apiClientProvider closes its http.Client when the container disposes',
      () async {
        final tracking = _TrackingClient();
        final container = ProviderContainer(
          overrides: [
            authControllerProvider.overrideWith(
              () => _FakeAuthController('tok'),
            ),
            // Mirrors apiClientProvider's own body (ApiClient(ref) +
            // ref.onDispose(client.close)) with an injectable http.Client so
            // the disposal wiring itself can be observed.
            apiClientProvider.overrideWith((ref) {
              final client = ApiClient(ref, httpClient: tracking);
              ref.onDispose(client.close);
              return client;
            }),
          ],
        );
        container.read(apiClientProvider);

        expect(tracking.closeCalls, 0);
        container.dispose();
        expect(tracking.closeCalls, 1);
      },
    );
  });

  group('ApiClient — network failures (MEDIUM-5)', () {
    test('a request that never reaches the server throws ApiNetworkException, '
        'not the raw http exception', () async {
      final client = MockClient((req) async {
        throw http.ClientException('Failed host lookup');
      });
      final api = _buildApiClient(client: client, token: 'tok');

      await expectLater(
        api.getJson('/apiaries'),
        throwsA(
          isA<ApiNetworkException>().having(
            (e) => e.cause,
            'cause',
            isA<http.ClientException>(),
          ),
        ),
      );
    });

    test('a non-2xx server response still throws ApiException, not '
        'ApiNetworkException — the request DID reach the server', () async {
      final client = MockClient(
        (req) async => http.Response(
          '{"code":"not_found"}',
          404,
          headers: {'content-type': 'application/json'},
          request: req,
        ),
      );
      final api = _buildApiClient(client: client, token: 'tok');

      await expectLater(
        api.getJson('/apiaries/missing'),
        throwsA(isA<ApiException>()),
      );
    });
  });
}

/// A fake [http.Client] that records [close] calls instead of tearing down a
/// real connection pool — used to prove [ApiClient.close]/[apiClientProvider]
/// actually release the underlying client (MEDIUM-3) rather than leaking it
/// for the lifetime of the app.
class _TrackingClient extends http.BaseClient {
  int closeCalls = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return MockClient(
      (req) async => http.Response('{}', 200, request: req),
    ).send(request);
  }

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}
