/// Compile-time configuration (`--dart-define`), so one build can point at a
/// different gateway host per environment without a code change.
abstract final class AppConfig {
  /// Base URL of the platform gateway (Traefik ingress; NFR-ARC-2 boundary).
  /// Defaults to the local k3d dev mapping documented in `infra/README.md`;
  /// override with `--dart-define=GATEWAY_BASE_URL=https://...`.
  static const String gatewayBaseUrl = String.fromEnvironment(
    'GATEWAY_BASE_URL',
    defaultValue: 'https://keycloak.beekeepingit.local:8443',
  );
}
