import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'external_link_platform_stub.dart'
    if (dart.library.js_interop) 'external_link_platform_web.dart';

/// Browser-side capability for opening an external URL in a **new tab**, so
/// the PWA's own session/local state isn't navigated away from.
///
/// Both current callers send the user to the identity provider's own
/// self-service account page (`AppConfig.oidcAccountUrl`) — account settings
/// for a password change, and the profile screen for the account email, which
/// the app deliberately does not own (D-7, auth.md §7: "no custom auth
/// build"). It lives in `core/` rather than inside a feature because it now
/// has two consumers in different features; it was previously a feature-local
/// copy in `features/account/` for file-ownership reasons only.
///
/// Mirrors `core/auth/auth_platform.dart`'s stub/web conditional-import split,
/// which keeps the web implementation out of VM-run widget tests.
abstract interface class ExternalLinkPlatform {
  /// Opens [url] in a new browser tab/window.
  void openInNewTab(String url);
}

/// Constructs the platform implementation for the current target.
ExternalLinkPlatform createExternalLinkPlatform() => makeExternalLinkPlatform();

/// Injectable seam for the above. Widget tests override this with a recording
/// fake — the concrete implementation is constructed at import time on web and
/// throws on the VM, so a test could not otherwise assert that a link-out
/// happened at all.
final externalLinkPlatformProvider = Provider<ExternalLinkPlatform>(
  (ref) => createExternalLinkPlatform(),
);
