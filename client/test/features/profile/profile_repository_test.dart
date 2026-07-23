import 'dart:convert';

import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/profile/profile_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Built via a runtime function so two "equal" instances are genuinely
// distinct objects, not compiler-canonicalized.
Profile _profile({String name = 'Test User'}) => Profile(
  id: 'user-1',
  name: name,
  email: 'test@example.com',
  locale: 'en',
  profileComplete: true,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 2),
);

Map<String, dynamic> _profileJson({String name = 'Test User'}) => {
  'id': 'user-1',
  'name': name,
  'email': 'test@example.com',
  'locale': 'en',
  'profile_complete': true,
  'created_at': '2026-01-01T00:00:00.000Z',
  'updated_at': '2026-01-02T00:00:00.000Z',
};

/// A no-op [LocalPrefs] fake — no real localStorage on the VM tests run on
/// (mirrors auth_controller_test.dart's own `FakeLocalPrefs`).
class _FakeLocalPrefs implements LocalPrefs {
  final Map<String, String> _store = {};

  @override
  String? read(String key) => _store[key];

  @override
  void write(String key, String value) => _store[key] = value;

  @override
  void remove(String key) => _store.remove(key);
}

/// A minimal [AuthController] stand-in returning a fixed token — mirrors
/// api_client_test.dart's own fake-seam approach; [ProfileRepository] only
/// ever needs [ApiClient.getJson]/`patchJson`, which go through
/// [AuthController.accessToken].
class _FakeAuthController extends AuthController {
  @override
  Future<AuthSession?> build() async => null;

  @override
  Future<String?> accessToken() async => 'tok';
}

/// Builds a [ProfileRepository] wired to [client] (a
/// `package:http/testing.dart` [MockClient] — no real network) and [prefs]
/// (defaults to a fresh [_FakeLocalPrefs]) — mirrors auth_controller_test.dart's
/// container-based test pattern.
ProfileRepository _buildRepo({required http.Client client, LocalPrefs? prefs}) {
  final container = ProviderContainer(
    overrides: [
      authControllerProvider.overrideWith(() => _FakeAuthController()),
      apiClientProvider.overrideWith(
        (ref) => ApiClient(ref, httpClient: client),
      ),
    ],
  );
  addTearDown(container.dispose);
  return ProfileRepository(
    container.read(apiClientProvider),
    prefs: prefs ?? _FakeLocalPrefs(),
  );
}

void main() {
  group('Profile value equality (MEDIUM-2)', () {
    test('two distinct instances with the same fields are ==', () {
      final a = _profile();
      final b = _profile();

      expect(identical(a, b), isFalse, reason: 'test setup sanity check');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('instances differing in a field are not ==', () {
      expect(_profile(), isNot(equals(_profile(name: 'Other User'))));
    });
  });

  // #390: the onboarding gate must stay passable offline for a
  // previously-onboarded user — ProfileRepository.fetch() caches the
  // last-known-good response and serves it back on a network failure.
  group('ProfileRepository.fetch() — offline cache (#390)', () {
    test('a successful fetch writes the cache', () async {
      final prefs = _FakeLocalPrefs();
      final client = MockClient(
        (req) async => http.Response(
          jsonEncode(_profileJson()),
          200,
          headers: {'content-type': 'application/json'},
          request: req,
        ),
      );
      final repo = _buildRepo(client: client, prefs: prefs);

      final profile = await repo.fetch();

      expect(profile.name, 'Test User');
      expect(prefs.read(kProfileCacheKey), isNotNull);
      expect(
        Profile.fromJson(
          jsonDecode(prefs.read(kProfileCacheKey)!) as Map<String, dynamic>,
        ),
        profile,
      );
    });

    test('a network failure with a cached snapshot returns the cached profile '
        'instead of throwing', () async {
      final prefs = _FakeLocalPrefs()
        ..write(kProfileCacheKey, jsonEncode(_profileJson(name: 'Cached')));
      final client = MockClient((req) async {
        throw http.ClientException('Failed host lookup');
      });
      final repo = _buildRepo(client: client, prefs: prefs);

      final profile = await repo.fetch();

      expect(profile.name, 'Cached');
    });

    test(
      'a network failure with no cache rethrows ApiNetworkException',
      () async {
        final client = MockClient((req) async {
          throw http.ClientException('Failed host lookup');
        });
        final repo = _buildRepo(client: client);

        await expectLater(repo.fetch(), throwsA(isA<ApiNetworkException>()));
      },
    );

    test(
      'a non-2xx server response (ApiException) is NOT masked by the cache',
      () async {
        final prefs = _FakeLocalPrefs()
          ..write(kProfileCacheKey, jsonEncode(_profileJson(name: 'Cached')));
        final client = MockClient(
          (req) async => http.Response(
            jsonEncode({'code': 'unauthorized'}),
            401,
            headers: {'content-type': 'application/json'},
            request: req,
          ),
        );
        final repo = _buildRepo(client: client, prefs: prefs);

        // The request DID reach the server — a resolved, real answer — so
        // the cache must not paper over it.
        await expectLater(repo.fetch(), throwsA(isA<ApiException>()));
      },
    );
  });
}
