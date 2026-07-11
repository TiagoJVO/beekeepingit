import 'auth_platform.dart';

/// VM/non-web stub — the OIDC redirect flow is web-only, and widget tests do
/// not exercise it. Any call fails loudly rather than silently mis-behaving.
AuthPlatform makeAuthPlatform() => _StubAuthPlatform();

class _StubAuthPlatform implements AuthPlatform {
  static Never _unsupported() =>
      throw UnsupportedError('OIDC redirect auth is only available on web');

  @override
  String get redirectUri => _unsupported();

  @override
  Uri get currentUri => _unsupported();

  @override
  void assignLocation(String url) => _unsupported();

  @override
  void replaceLocation(Uri uri) => _unsupported();

  @override
  String? readSession(String key) => _unsupported();

  @override
  void writeSession(String key, String value) => _unsupported();

  @override
  void removeSession(String key) => _unsupported();
}
