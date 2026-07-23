import 'package:web/web.dart' as web;

import 'local_prefs.dart';

/// Web implementation of [LocalPrefs] over `package:web`'s `localStorage`.
LocalPrefs makeLocalPrefs() => _WebLocalPrefs();

class _WebLocalPrefs implements LocalPrefs {
  @override
  String? read(String key) => web.window.localStorage.getItem(key);

  @override
  void write(String key, String value) =>
      web.window.localStorage.setItem(key, value);

  @override
  void remove(String key) => web.window.localStorage.removeItem(key);
}
