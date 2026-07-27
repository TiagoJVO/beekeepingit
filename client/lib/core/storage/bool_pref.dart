import 'local_prefs.dart';

/// A tiny typed boolean seam over [LocalPrefs] (FR-ST-1, #81): every local,
/// per-device setting the app persists so far (auto-sync, notifications
/// master switch) is "a boolean under a string key with a default", and
/// duplicating that read/parse/write dance per setting invites drift — this
/// is the one place it's written. [LocalPrefs] itself only stores strings,
/// so `'true'`/anything-else is the on-disk representation.
class BoolPref {
  const BoolPref(this._prefs, this._key, {required this.defaultValue});

  final LocalPrefs _prefs;
  final String _key;

  /// Returned by [read] when nothing has been persisted yet (first run, or
  /// after a purge — see `AuthController.logout()`'s onboarding-cache
  /// clearing, which this joins).
  final bool defaultValue;

  bool read() {
    final raw = _prefs.read(_key);
    if (raw == null) return defaultValue;
    return raw == 'true';
  }

  void write(bool value) => _prefs.write(_key, value ? 'true' : 'false');
}
