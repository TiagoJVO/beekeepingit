import 'package:web/web.dart' as web;

import 'account_platform.dart';

/// Web implementation of [AccountPlatform] over `package:web`.
AccountPlatform makeAccountPlatform() => _WebAccountPlatform();

class _WebAccountPlatform implements AccountPlatform {
  @override
  void openInNewTab(String url) => web.window.open(url, '_blank');
}
