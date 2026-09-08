import 'dart:convert';

import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/core/sync/local_store_owner.dart';
import 'package:flutter_test/flutter_test.dart';

/// An in-memory [LocalPrefs] — a fake, not a mock: what the marker is left
/// holding after each decision is part of what these tests assert.
class _FakePrefs implements LocalPrefs {
  final Map<String, String> values = {};

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;

  @override
  void remove(String key) => values.remove(key);
}

/// What a browser `localStorage` failure looks like on the Dart side: an
/// opaque object thrown across the JS interop boundary (a `SecurityError` when
/// site data is blocked or the page is a partitioned third-party context, a
/// `QuotaExceededError` when the origin is full). Deliberately **not** a Dart
/// `Error` subtype — those are programming bugs and the production code
/// rethrows them rather than reclassifying them as "storage unavailable"
/// (dart-conventions.md); `_BuggyPrefs` below covers that half.
class _StorageFailure {
  const _StorageFailure();

  @override
  String toString() => 'SecurityError: storage unavailable';
}

/// A [LocalPrefs] whose backend is unavailable.
class _ThrowingPrefs implements LocalPrefs {
  @override
  String? read(String key) => throw const _StorageFailure();

  @override
  void write(String key, String value) => throw const _StorageFailure();

  @override
  void remove(String key) => throw const _StorageFailure();
}

/// A [LocalPrefs] implementation with a *bug* in it, as distinct from an
/// unavailable backend. The production code must let this escape rather than
/// swallow it into a silent, data-destructive purge.
class _BuggyPrefs implements LocalPrefs {
  @override
  String? read(String key) => throw StateError('bug in the prefs backend');

  @override
  void write(String key, String value) =>
      throw StateError('bug in the prefs backend');

  @override
  void remove(String key) => throw StateError('bug in the prefs backend');
}

/// A syntactically valid, unsigned JWT carrying [claims] as its payload —
/// enough for [oidcSubject], which reads the claim without verifying.
String _jwt(Object? claims) {
  String segment(String s) =>
      base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  return '${segment('{"alg":"none"}')}.${segment(jsonEncode(claims))}.sig';
}

void main() {
  group('oidcSubject', () {
    test('reads the sub claim out of a well-formed id token', () {
      expect(
        oidcSubject(_jwt({'sub': 'user-a', 'email': 'a@example.test'})),
        'user-a',
      );
    });

    test('tolerates a payload segment with the base64url padding stripped', () {
      // Real IdPs strip `=` padding; `base64Url.decode` alone would throw.
      final token = _jwt({'sub': 'padding-sensitive-subject-value'});
      expect(token.split('.')[1], isNot(contains('=')));
      expect(oidcSubject(token), 'padding-sensitive-subject-value');
    });

    test('is null for anything it cannot read a subject out of', () {
      expect(oidcSubject(null), isNull, reason: 'no token at all');
      expect(oidcSubject(''), isNull, reason: 'empty token');
      expect(oidcSubject('not-a-jwt'), isNull, reason: 'not three segments');
      expect(oidcSubject('a.b'), isNull, reason: 'two segments');
      expect(oidcSubject('a.!!!.c'), isNull, reason: 'payload not base64url');
      expect(
        oidcSubject('a.${base64Url.encode(utf8.encode('not json'))}.c'),
        isNull,
        reason: 'payload not JSON',
      );
      expect(
        oidcSubject(_jwt(['sub', 'user-a'])),
        isNull,
        reason: 'payload is a JSON array, not an object',
      );
      expect(oidcSubject(_jwt({'email': 'a@x'})), isNull, reason: 'no sub');
      expect(oidcSubject(_jwt({'sub': ''})), isNull, reason: 'empty sub');
      expect(
        oidcSubject(_jwt({'sub': 42})),
        isNull,
        reason: 'sub not a string',
      );
    });
  });

  group('storeOwnerFromSession', () {
    test('no session at all is SignedOutOwner', () {
      expect(
        storeOwnerFromSession(signedIn: false, idToken: null),
        isA<SignedOutOwner>(),
      );
    });

    test('a session with a readable subject is KnownOwner', () {
      final owner = storeOwnerFromSession(
        signedIn: true,
        idToken: _jwt({'sub': 'user-a'}),
      );
      expect(owner, isA<KnownOwner>());
      expect((owner as KnownOwner).subject, 'user-a');
    });

    test('a session whose subject cannot be read is UnprovenOwner', () {
      expect(
        storeOwnerFromSession(signedIn: true, idToken: ''),
        isA<UnprovenOwner>(),
        reason: 'the offline stale-session placeholder can carry no id token',
      );
      expect(
        storeOwnerFromSession(signedIn: true, idToken: 'garbage'),
        isA<UnprovenOwner>(),
      );
    });
  });

  group('ensureLocalStoreBelongsTo', () {
    test('the same subject reopening does NOT purge (#664 AC 2)', () async {
      final prefs = _FakePrefs()..write(kLocalStoreSubjectKey, 'user-a');
      var purges = 0;

      final purged = await ensureLocalStoreBelongsTo(
        owner: const KnownOwner('user-a'),
        prefs: prefs,
        purge: () async => purges++,
      );

      expect(purged, isFalse);
      expect(purges, 0);
      expect(prefs.values[kLocalStoreSubjectKey], 'user-a');
    });

    test('a different subject purges and re-stamps the marker', () async {
      final prefs = _FakePrefs()..write(kLocalStoreSubjectKey, 'user-a');
      var purges = 0;

      final purged = await ensureLocalStoreBelongsTo(
        owner: const KnownOwner('user-b'),
        prefs: prefs,
        purge: () async => purges++,
      );

      expect(purged, isTrue);
      expect(purges, 1);
      expect(prefs.values[kLocalStoreSubjectKey], 'user-b');
    });

    test('a first-ever login has no marker, so it purges and stamps', () async {
      final prefs = _FakePrefs();
      var purges = 0;

      final purged = await ensureLocalStoreBelongsTo(
        owner: const KnownOwner('user-a'),
        prefs: prefs,
        purge: () async => purges++,
      );

      expect(purged, isTrue, reason: 'unproven ownership always fails closed');
      expect(purges, 1);
      expect(prefs.values[kLocalStoreSubjectKey], 'user-a');
    });

    test('an empty/corrupt marker fails closed and purges', () async {
      final prefs = _FakePrefs()..write(kLocalStoreSubjectKey, '');
      var purges = 0;

      final purged = await ensureLocalStoreBelongsTo(
        owner: const KnownOwner('user-a'),
        prefs: prefs,
        purge: () async => purges++,
      );

      expect(purged, isTrue);
      expect(purges, 1);
      expect(prefs.values[kLocalStoreSubjectKey], 'user-a');
    });

    test('a signed-in session with an unreadable subject purges, and '
        'stamps no marker', () async {
      final prefs = _FakePrefs()..write(kLocalStoreSubjectKey, 'user-a');
      var purges = 0;

      final purged = await ensureLocalStoreBelongsTo(
        owner: const UnprovenOwner(),
        prefs: prefs,
        purge: () async => purges++,
      );

      expect(purged, isTrue);
      expect(purges, 1);
      expect(
        prefs.values.containsKey(kLocalStoreSubjectKey),
        isFalse,
        reason: 'we cannot claim a store for an owner we could not identify',
      );
    });

    test('signed out defers: no purge, and the marker is left alone', () async {
      final prefs = _FakePrefs()..write(kLocalStoreSubjectKey, 'user-a');
      var purges = 0;

      final purged = await ensureLocalStoreBelongsTo(
        owner: const SignedOutOwner(),
        prefs: prefs,
        purge: () async => purges++,
      );

      expect(
        purged,
        isFalse,
        reason:
            '#664 AC 2: a token expiry resolves '
            'logged-out on the next boot, and that must not destroy the '
            'returning user\'s own unsynced offline work',
      );
      expect(purges, 0);
      expect(prefs.values[kLocalStoreSubjectKey], 'user-a');
    });

    test('clears the marker BEFORE purging, so an interrupted purge '
        'fails closed next time', () async {
      final prefs = _FakePrefs()..write(kLocalStoreSubjectKey, 'user-a');
      String? markerDuringPurge = 'unset';

      await expectLater(
        ensureLocalStoreBelongsTo(
          owner: const KnownOwner('user-b'),
          prefs: prefs,
          purge: () async {
            markerDuringPurge = prefs.values[kLocalStoreSubjectKey];
            throw StateError('wipe interrupted');
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(markerDuringPurge, isNull);
      expect(
        prefs.values.containsKey(kLocalStoreSubjectKey),
        isFalse,
        reason: 'no marker survives a failed purge, so the next open purges',
      );
    });

    test('unusable storage is treated as an unproven owner, not a crash', () {
      expect(
        ensureLocalStoreBelongsTo(
          owner: const KnownOwner('user-a'),
          prefs: _ThrowingPrefs(),
          purge: () async {},
        ),
        completion(isTrue),
      );
    });

    test('a BUG in the prefs backend escapes rather than being swallowed as '
        '"storage unavailable" (dart-conventions.md)', () {
      expect(
        ensureLocalStoreBelongsTo(
          owner: const KnownOwner('user-a'),
          prefs: _BuggyPrefs(),
          purge: () async {},
        ),
        throwsA(isA<StateError>()),
        reason:
            'an Error out of a one-line marker accessor is a programming '
            'mistake. Reclassifying it would turn it into an unexplained '
            'purge of unsynced offline work instead of a fixable crash',
      );
    });
  });

  group('clearPerUserPrefs (#664, D-38)', () {
    test('removes every per-user key, including the owner marker', () {
      final prefs = _FakePrefs();
      for (final key in kPerUserPrefsKeys) {
        prefs.write(key, 'user-a value');
      }
      prefs.write('bk.some_device_key', 'kept');

      clearPerUserPrefs(prefs);

      expect(prefs.values.keys, ['bk.some_device_key']);
    });

    test('the list covers the caches that would otherwise leak the previous '
        'identity and org id to user B', () {
      expect(
        kPerUserPrefsKeys,
        containsAll(<String>[
          kProfileCacheKey,
          kOrganizationCacheKey,
          kLocalStoreSubjectKey,
        ]),
        reason:
            'bk.profile/bk.organization are read as last-known-good whenever a '
            'post-login fetch fails or the device is offline, so a store-only '
            'purge would still hand user B the previous name, email and org id',
      );
    });

    test('one key the backend refuses does not stop the others being '
        'cleared', () {
      var refusals = 0;
      final prefs = _PartlyRefusingPrefs(
        refuse: kOrganizationCacheKey,
        onRefuse: () => refusals++,
      );
      for (final key in kPerUserPrefsKeys) {
        prefs.values[key] = 'user-a value';
      }

      clearPerUserPrefs(prefs);

      expect(refusals, 1);
      expect(prefs.values.keys, [kOrganizationCacheKey]);
    });

    test('a BUG in the backend still escapes', () {
      expect(
        () => clearPerUserPrefs(_BuggyPrefs()),
        throwsA(isA<StateError>()),
      );
    });
  });
}

/// A [LocalPrefs] that refuses exactly one key, the way a storage backend can
/// fail per-entry rather than wholesale.
class _PartlyRefusingPrefs implements LocalPrefs {
  _PartlyRefusingPrefs({required this.refuse, required this.onRefuse});

  final String refuse;
  final void Function() onRefuse;
  final Map<String, String> values = {};

  @override
  String? read(String key) => values[key];

  @override
  void write(String key, String value) => values[key] = value;

  @override
  void remove(String key) {
    if (key == refuse) {
      onRefuse();
      throw const _StorageFailure();
    }
    values.remove(key);
  }
}
