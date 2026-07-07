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

  /// OIDC realm + public client (docs/architecture/auth.md §3, D-7). The realm
  /// is served under the gateway at `/realms/<realm>` (#84).
  static const String oidcRealm = String.fromEnvironment(
    'OIDC_REALM',
    defaultValue: 'beekeepingit',
  );
  static const String oidcClientId = String.fromEnvironment(
    'OIDC_CLIENT_ID',
    defaultValue: 'beekeepingit-pwa',
  );

  /// Where Keycloak redirects back after login. When empty, the web auth
  /// platform uses the app's own origin at runtime.
  static const String oidcRedirectUri = String.fromEnvironment(
    'OIDC_REDIRECT_URI',
    defaultValue: '',
  );

  /// PowerSync sync-stream endpoint (gateway route `/sync-stream/**` → the
  /// PowerSync service). The **trailing slash is required**: the SDK builds each
  /// request as `Uri.parse(endpoint).resolve('sync/stream')`, and RFC 3986
  /// resolution against a base without a trailing slash *replaces* the last path
  /// segment — dropping `/sync-stream` and POSTing to `/sync/stream`, which
  /// misses the gateway route and hits the PWA (405). With the slash it resolves
  /// to `/sync-stream/sync/stream`, which the gateway strips before PowerSync.
  static const String powerSyncUrl = String.fromEnvironment(
    'POWERSYNC_URL',
    defaultValue: 'https://keycloak.beekeepingit.local:8443/sync-stream/',
  );

  /// OIDC endpoints derived from the issuer.
  static String get oidcIssuer => '$gatewayBaseUrl/realms/$oidcRealm';
  static String get oidcAuthorizeUrl =>
      '$oidcIssuer/protocol/openid-connect/auth';
  static String get oidcTokenUrl => '$oidcIssuer/protocol/openid-connect/token';

  /// RP-initiated logout (OIDC session management) — revokes the Keycloak
  /// SSO session server-side on logout (auth.md §7, NFR-SEC-1), not just the
  /// client's local token cache.
  static String get oidcEndSessionUrl =>
      '$oidcIssuer/protocol/openid-connect/logout';

  /// Keycloak's built-in Account Console — where password change is
  /// delegated to (FR-AU-1, #29), per auth.md §7's "use Keycloak's built-ins,
  /// no custom auth build" stance. Served under the same `/realms/<realm>`
  /// path the gateway already proxies to Keycloak (no new route needed).
  static String get oidcAccountConsoleUrl => '$oidcIssuer/account';

  /// Sync service client-facing endpoints (gateway route `/v1/sync/**`).
  static String get syncTokenUrl => '$gatewayBaseUrl/v1/sync/token';
  static String get syncBatchUrl => '$gatewayBaseUrl/v1/sync/batch';
}
