import 'local_prefs.dart';

/// VM/non-web stub — silently a no-op (no cache), unlike
/// `core/auth/auth_platform_stub.dart`'s throwing stub. Caching is
/// best-effort and this target (widget/unit tests, run on the VM) is not a
/// real deployment target for the web-only client, so callers should not
/// need to special-case it: reads simply miss, writes/removes are dropped.
LocalPrefs makeLocalPrefs() => _StubLocalPrefs();

class _StubLocalPrefs implements LocalPrefs {
  @override
  String? read(String key) => null;

  @override
  void write(String key, String value) {}

  @override
  void remove(String key) {}
}
