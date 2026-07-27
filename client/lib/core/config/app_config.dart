/// Compile-time configuration (`--dart-define`), so one build can point at a
/// different gateway host or identity provider per environment without a code
/// change.
abstract final class AppConfig {
  /// Base URL of the platform gateway (Traefik ingress; NFR-ARC-2 boundary) —
  /// the **app host** serving the PWA, the Go APIs (`/v1/*`) and PowerSync
  /// (`/sync-stream`). Defaults to the local k3d dev mapping documented in
  /// `infra/README.md`; override with `--dart-define=GATEWAY_BASE_URL=https://...`.
  ///
  /// Note this is a **different host** from the OIDC issuer ([oidcIssuer]): the
  /// identity provider lives on its own `auth.` host (see
  /// `docs/architecture/oidc-integration.md` §2). The app depends on the issuer
  /// only through OIDC discovery, so swapping providers is a config change here.
  static const String gatewayBaseUrl = String.fromEnvironment(
    'GATEWAY_BASE_URL',
    defaultValue: 'https://app.beekeepingit.local:8443',
  );

  /// OIDC **issuer** URL (the auth host). This is the single knob the app needs
  /// for identity: every endpoint (authorize, token, end-session, JWKS, …) is
  /// read at runtime from the issuer's discovery document
  /// (`<issuer>/.well-known/openid-configuration`) — the app hard-codes **no**
  /// provider URL scheme, so swapping the IdP is just changing this value
  /// (`docs/architecture/oidc-integration.md` §1/§7, D-7).
  static const String oidcIssuer = String.fromEnvironment(
    'OIDC_ISSUER',
    defaultValue:
        'https://auth.beekeepingit.local:8443/application/o/beekeepingit/',
  );

  /// The public client id registered with the provider
  /// (docs/architecture/auth.md §3, D-7).
  static const String oidcClientId = String.fromEnvironment(
    'OIDC_CLIENT_ID',
    defaultValue: 'beekeepingit-pwa',
  );

  /// Where the provider redirects back after login. When empty, the web auth
  /// platform uses the app's own origin at runtime.
  static const String oidcRedirectUri = String.fromEnvironment(
    'OIDC_REDIRECT_URI',
    defaultValue: '',
  );

  /// The provider's self-service account page — where password change is
  /// delegated to (FR-AU-1, #29), opened in a new tab. A **config value**, not
  /// a derived provider path, so the app stays provider-agnostic
  /// (`docs/architecture/oidc-integration.md` §7). Defaults to Authentik's
  /// user settings page in the local dev deployment.
  static const String oidcAccountUrl = String.fromEnvironment(
    'OIDC_ACCOUNT_URL',
    defaultValue: 'https://auth.beekeepingit.local:8443/if/user/#/settings',
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
    defaultValue: 'https://app.beekeepingit.local:8443/sync-stream/',
  );

  /// Sync service client-facing endpoints (gateway route `/v1/sync/**`).
  static String get syncTokenUrl => '$gatewayBaseUrl/v1/sync/token';
  static String get syncBatchUrl => '$gatewayBaseUrl/v1/sync/batch';
}
