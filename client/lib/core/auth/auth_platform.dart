import 'auth_platform_stub.dart'
    if (dart.library.js_interop) 'auth_platform_web.dart';

/// Browser-side capabilities the OIDC redirect flow needs, abstracted so the
/// web implementation (package:web) stays out of VM-run widget tests. On the
/// VM a stub is used (auth is never exercised there).
abstract interface class AuthPlatform {
  /// The redirect URI registered with Keycloak — the app's own origin unless
  /// overridden by `--dart-define=OIDC_REDIRECT_URI`.
  String get redirectUri;

  /// Current page URL (to read the `?code=`/`?state=` callback params).
  Uri get currentUri;

  /// Navigate the browser to [url] (the Keycloak authorize endpoint).
  void assignLocation(String url);

  /// Replace the current URL without reloading (to strip callback params).
  void replaceLocation(Uri uri);

  String? readSession(String key);
  void writeSession(String key, String value);
  void removeSession(String key);
}

/// Constructs the platform implementation for the current target.
AuthPlatform createAuthPlatform() => makeAuthPlatform();
