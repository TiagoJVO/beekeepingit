import 'dart:async';

import 'package:http/http.dart' as http;

import '../config/app_config.dart';

/// Measures link quality before the sync engine is allowed to connect/flush
/// (FR-OF-3, sync.md §7.1): "roughly usable 3G or better", decided by a tiny
/// probe request rather than the mere presence of a connection. Injectable so
/// [SyncGate] can be unit-tested with a fake pass/fail sequence, no network.
abstract interface class ConnectivityProbe {
  /// Attempts one probe and reports whether the link is currently usable.
  /// Must never throw — a failed/timed-out probe resolves to `false`.
  Future<bool> check();

  /// Releases any resources the probe owns (e.g. [HttpConnectivityProbe]'s
  /// `http.Client` — HIGH finding: it was never closed, leaking a client on
  /// every logout/membership-purge cycle). A no-op default so fakes that
  /// don't own resources (e.g. tests' scripted probes) need not implement it.
  void dispose() {}
}

/// The real probe: a `GET` against PowerSync's own liveness endpoint,
/// reachable through the gateway at `[gatewayBaseUrl]/sync-stream/probes/
/// liveness` (the existing strip-prefix route in
/// `infra/helm/beekeepingit/charts/gateway/templates/powersync-route.yaml`,
/// unauthenticated, no DB/business logic — genuinely the "tiny probe request"
/// sync.md §7.1 asks for). Chosen over a `/v1/*` domain-service `/healthz`
/// because none of those are actually gateway-reachable today: the gateway's
/// main Ingress routes `/v1/<service>` to each service **without** stripping
/// the prefix, but every service mounts `/healthz`/`/readyz` at its own root
/// (servicetemplate.go), so `/v1/sync/healthz` 404s. PowerSync's route is the
/// one gateway path that already strips its prefix, making `/probes/liveness`
/// land exactly where the pod actually serves it.
///
/// Pass/fail is decided purely by **reachability within the timeout** — a
/// non-2xx response still proves the link carried a full HTTP round trip, so
/// it counts as a pass; only a timeout or transport error counts as a
/// failure. This matches sync.md §7.1's intent (RTT + hard timeout as the
/// signal), without coupling the gate to the probe endpoint's exact status
/// code contract.
class HttpConnectivityProbe implements ConnectivityProbe {
  HttpConnectivityProbe({
    http.Client? client,
    this.timeout = const Duration(seconds: 3),
  }) : _http = client ?? http.Client();

  final http.Client _http;

  /// Hard timeout on the probe request (sync.md §7.1: "RTT + hard timeout").
  /// Configurable — sync.md §7.1 notes thresholds are tuned in EPIC-06 field
  /// testing, not hard-coded guesses; this default is a starting point.
  final Duration timeout;

  static final Uri _probeUri = Uri.parse(
    '${AppConfig.gatewayBaseUrl}/sync-stream/probes/liveness',
  );

  @override
  Future<bool> check() async {
    try {
      await _http.get(_probeUri).timeout(timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Closes the injected `http.Client` (HIGH finding: this was previously
  /// never called, leaking a client on every logout/membership-purge
  /// cycle). Wired from `powersync_service.dart`'s provider teardown.
  @override
  void dispose() => _http.close();
}
