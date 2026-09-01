import 'package:web/web.dart' as web;

import 'external_link_platform.dart';

/// Web implementation of [ExternalLinkPlatform] over `package:web`.
ExternalLinkPlatform makeExternalLinkPlatform() => _WebExternalLinkPlatform();

class _WebExternalLinkPlatform implements ExternalLinkPlatform {
  @override
  void openInNewTab(String url) => web.window.open(url, '_blank');
}
