import 'account_platform_stub.dart'
    if (dart.library.js_interop) 'account_platform_web.dart';

/// Browser-side capability account settings needs: opening an external URL
/// (the identity provider's own self-service account page, for password
/// change — auth.md §7, "no custom auth build") in a **new tab**, so the PWA's
/// own session/local state
/// isn't navigated away from. Mirrors `core/auth/auth_platform.dart`'s
/// stub/web conditional-import split (web implementation kept out of
/// VM-run widget tests) — kept as this feature's **own** copy rather than
/// reusing/extending `core/auth/`, which is out of this feature's file
/// ownership.
abstract interface class AccountPlatform {
  /// Opens [url] in a new browser tab/window.
  void openInNewTab(String url);
}

/// Constructs the platform implementation for the current target.
AccountPlatform createAccountPlatform() => makeAccountPlatform();
