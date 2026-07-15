import 'package:beekeepingit_client/core/config/app_config.dart';
import 'package:beekeepingit_client/core/sync/connectivity_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('HttpConnectivityProbe', () {
    test(
      'probes the PowerSync liveness endpoint through the gateway\'s '
      'existing strip-prefix route (no new server endpoint needed)',
      () async {
        Uri? requested;
        final client = MockClient((req) async {
          requested = req.url;
          return http.Response('', 200);
        });
        final probe = HttpConnectivityProbe(client: client);

        final ok = await probe.check();

        expect(ok, isTrue);
        expect(
          requested,
          Uri.parse('${AppConfig.gatewayBaseUrl}/sync-stream/probes/liveness'),
        );
      },
    );

    test('a non-2xx response still counts as a pass (reachability, not '
        'a status-code contract)', () async {
      final client = MockClient((req) async => http.Response('', 503));
      final probe = HttpConnectivityProbe(client: client);

      expect(await probe.check(), isTrue);
    });

    test(
      'a thrown transport error resolves to a fail, never propagates',
      () async {
        final client = MockClient((req) async => throw Exception('offline'));
        final probe = HttpConnectivityProbe(client: client);

        expect(await probe.check(), isFalse);
      },
    );

    test('a request slower than the timeout resolves to a fail', () async {
      final client = MockClient((req) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('', 200);
      });
      final probe = HttpConnectivityProbe(
        client: client,
        timeout: const Duration(milliseconds: 5),
      );

      expect(await probe.check(), isFalse);
    });

    test(
      'dispose() closes the injected http.Client (HIGH #1 — resource leak: '
      'the probe owns an http.Client never closed on logout/membership-purge '
      'teardown)',
      () {
        final client = _TrackingHttpClient();
        final probe = HttpConnectivityProbe(client: client);

        probe.dispose();

        expect(client.closed, isTrue);
      },
    );
  });
}

/// A minimal [http.Client] that records whether [close] was called, so
/// [HttpConnectivityProbe.dispose] can be asserted to actually release its
/// injected client rather than merely existing as a no-op method.
class _TrackingHttpClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      throw UnsupportedError('not used by this test');

  @override
  void close() => closed = true;
}
