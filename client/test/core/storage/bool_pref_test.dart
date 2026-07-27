import 'package:beekeepingit_client/core/storage/bool_pref.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalPrefs] fake — mirrors the convention already used by
/// `profile_repository_test.dart`/`auth_controller_test.dart` (a fake, not a
/// mock, per the project's Dart testing conventions).
class _FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> _store = {};

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

void main() {
  group('BoolPref', () {
    test('read() returns the default value when nothing is stored', () {
      final pref = BoolPref(_FakeLocalPrefs(), 'k', defaultValue: true);

      expect(pref.read(), isTrue);
    });

    test('read() returns the other default value when nothing is stored', () {
      final pref = BoolPref(_FakeLocalPrefs(), 'k', defaultValue: false);

      expect(pref.read(), isFalse);
    });

    test('write(true) then read() round-trips true', () {
      final prefs = _FakeLocalPrefs();
      final pref = BoolPref(prefs, 'k', defaultValue: false);

      pref.write(true);

      expect(pref.read(), isTrue);
    });

    test('write(false) then read() round-trips false, overriding a true '
        'default', () {
      final prefs = _FakeLocalPrefs();
      final pref = BoolPref(prefs, 'k', defaultValue: true);

      pref.write(false);

      expect(pref.read(), isFalse);
    });

    test('persists under the given key, independent of other keys', () {
      final prefs = _FakeLocalPrefs();
      final a = BoolPref(prefs, 'a', defaultValue: false);
      final b = BoolPref(prefs, 'b', defaultValue: false);

      a.write(true);

      expect(a.read(), isTrue);
      expect(b.read(), isFalse);
      expect(prefs.read('b'), isNull);
    });
  });
}
