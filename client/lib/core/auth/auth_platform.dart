import 'auth_platform_stub.dart'
    if (dart.library.js_interop) 'auth_platform_web.dart';

/// Browser-side capabilities the OIDC redirect flow needs, abstracted so the
/// web implementation (package:web) stays out of VM-run widget tests. On the
/// VM a stub is used (auth is never exercised there).
abstract interface class AuthPlatform {
  /// The redirect URI registered with the identity provider — the app's own
  /// origin unless overridden by `--dart-define=OIDC_REDIRECT_URI`.
  String get redirectUri;

  /// Current page URL (to read the `?code=`/`?state=` callback params).
  Uri get currentUri;

  /// Navigate the browser to [url] (the provider's authorize/end-session URL).
  void assignLocation(String url);

  /// Replace the current URL without reloading (to strip callback params).
  void replaceLocation(Uri uri);

  String? readSession(String key);
  void writeSession(String key, String value);
  void removeSession(String key);

  /// Durable (survives browser restart) storage — `localStorage` on web
  /// (#390). Used for the refresh + id token so a closed/reopened browser
  /// still has a session to restore, unlike [readSession]/[writeSession]'s
  /// per-tab `sessionStorage`, which the PKCE `code_verifier`/`state` stay on
  /// (intentionally ephemeral, single-flow — see auth_controller.dart).
  String? readLocal(String key);
  void writeLocal(String key, String value);
  void removeLocal(String key);
}

/// Constructs the platform implementation for the current target.
AuthPlatform createAuthPlatform() => makeAuthPlatform();
