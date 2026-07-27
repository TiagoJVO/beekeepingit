import 'package:web/web.dart' as web;

import '../config/app_config.dart';
import 'auth_platform.dart';

/// Web implementation of [AuthPlatform] over `package:web`.
AuthPlatform makeAuthPlatform() => _WebAuthPlatform();

class _WebAuthPlatform implements AuthPlatform {
  @override
  String get redirectUri => AppConfig.oidcRedirectUri.isNotEmpty
      ? AppConfig.oidcRedirectUri
      : web.window.location.origin;

  @override
  Uri get currentUri => Uri.parse(web.window.location.href);

  @override
  void assignLocation(String url) => web.window.location.assign(url);

  @override
  void replaceLocation(Uri uri) =>
      web.window.history.replaceState(null, '', uri.toString());

  @override
  String? readSession(String key) => web.window.sessionStorage.getItem(key);

  @override
  void writeSession(String key, String value) =>
      web.window.sessionStorage.setItem(key, value);

  @override
  void removeSession(String key) => web.window.sessionStorage.removeItem(key);

  @override
  String? readLocal(String key) => web.window.localStorage.getItem(key);

  @override
  void writeLocal(String key, String value) =>
      web.window.localStorage.setItem(key, value);

  @override
  void removeLocal(String key) => web.window.localStorage.removeItem(key);
}
