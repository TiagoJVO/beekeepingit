import 'account_platform.dart';

/// VM/non-web stub — opening a new browser tab is web-only, and widget tests
/// do not exercise it. Any call fails loudly rather than silently
/// mis-behaving, matching `core/auth/auth_platform_stub.dart`'s convention.
AccountPlatform makeAccountPlatform() => _StubAccountPlatform();

class _StubAccountPlatform implements AccountPlatform {
  @override
  void openInNewTab(String url) =>
      throw UnsupportedError('Opening an external URL is only available on web');
}
