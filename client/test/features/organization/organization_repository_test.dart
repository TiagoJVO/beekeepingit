import 'dart:convert';

import 'package:beekeepingit_client/core/api/api_client.dart';
import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/core/storage/local_prefs.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

// Built via a runtime function (not a `const` literal, and Organization has
// no const constructor anyway since DateTime isn't a const-constructible
// type) so two "equal" instances are genuinely distinct objects.
Organization _org({String name = 'Serra Apiaries'}) => Organization(
  id: 'org-1',
  name: name,
  address: '123 Serra Rd',
  createdBy: 'user-1',
  role: 'admin',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 2),
);

Map<String, dynamic> _orgJson({String name = 'Serra Apiaries'}) => {
  'id': 'org-1',
  'name': name,
  'address': '123 Serra Rd',
  'created_by': 'user-1',
  'role': 'admin',
  'created_at': '2026-01-01T00:00:00.000Z',
  'updated_at': '2026-01-02T00:00:00.000Z',
};

/// A no-op [LocalPrefs] fake — mirrors auth_controller_test.dart's own
/// `FakeLocalPrefs`/profile_repository_test.dart's `_FakeLocalPrefs`.
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
/// profile_repository_test.dart's own fake-seam approach.
class _FakeAuthController extends AuthController {
  @override
  Future<AuthSession?> build() async => null;

  @override
  Future<String?> accessToken() async => 'tok';
}

/// Builds an [OrganizationRepository] wired to [client] (a MockClient — no
/// real network) and [prefs] (defaults to a fresh [_FakeLocalPrefs]).
OrganizationRepository _buildRepo({
  required http.Client client,
  LocalPrefs? prefs,
}) {
  final container = ProviderContainer(
    overrides: [
      authControllerProvider.overrideWith(() => _FakeAuthController()),
      apiClientProvider.overrideWith(
        (ref) => ApiClient(ref, httpClient: client),
      ),
    ],
  );
  addTearDown(container.dispose);
  return OrganizationRepository(
    container.read(apiClientProvider),
    prefs: prefs ?? _FakeLocalPrefs(),
  );
}

void main() {
  group('Organization value equality (MEDIUM-2)', () {
    test('two distinct instances with the same fields are ==', () {
      final a = _org();
      final b = _org();

      expect(identical(a, b), isFalse, reason: 'test setup sanity check');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('instances differing in a field are not ==', () {
      expect(_org(), isNot(equals(_org(name: 'Other Apiaries'))));
    });
  });

  // #390: the onboarding gate must stay passable offline for a
  // previously-onboarded user — OrganizationRepository.fetchMine() caches
  // the last-known-good response and serves it back on a network failure.
  group('OrganizationRepository.fetchMine() — offline cache (#390)', () {
    test('a successful fetch writes the cache', () async {
      final prefs = _FakeLocalPrefs();
      final client = MockClient(
        (req) async => http.Response(
          jsonEncode(_orgJson()),
          200,
          headers: {'content-type': 'application/json'},
          request: req,
        ),
      );
      final repo = _buildRepo(client: client, prefs: prefs);

      final org = await repo.fetchMine();

      expect(org.name, 'Serra Apiaries');
      expect(prefs.read(kOrganizationCacheKey), isNotNull);
    });

    test('a network failure with a cached snapshot returns the cached '
        'organization instead of throwing', () async {
      final prefs = _FakeLocalPrefs()
        ..write(kOrganizationCacheKey, jsonEncode(_orgJson(name: 'Cached')));
      final client = MockClient((req) async {
        throw http.ClientException('Failed host lookup');
      });
      final repo = _buildRepo(client: client, prefs: prefs);

      final org = await repo.fetchMine();

      expect(org.name, 'Cached');
    });

    test(
      'a network failure with no cache rethrows ApiNetworkException',
      () async {
        final client = MockClient((req) async {
          throw http.ClientException('Failed host lookup');
        });
        final repo = _buildRepo(client: client);

        await expectLater(
          repo.fetchMine(),
          throwsA(isA<ApiNetworkException>()),
        );
      },
    );

    test('a 404 ("no organization yet") is NOT masked by the cache — it is a '
        'real, resolved answer', () async {
      final prefs = _FakeLocalPrefs()
        ..write(kOrganizationCacheKey, jsonEncode(_orgJson(name: 'Cached')));
      final client = MockClient(
        (req) async => http.Response(
          jsonEncode({'code': 'not_found'}),
          404,
          headers: {'content-type': 'application/json'},
          request: req,
        ),
      );
      final repo = _buildRepo(client: client, prefs: prefs);

      await expectLater(repo.fetchMine(), throwsA(isA<ApiException>()));
    });
  });

  // Regression: every logged-out boot used to fire an unauthenticated
  // `GET /v1/organizations/me` — retried ~10x by Riverpod's default policy
  // (a "401 storm") — because eager watchers (the router's redirect listens,
  // app.dart's membership-loss purge listener) initialize this provider
  // before any session exists. OrganizationController.build now stays
  // pending without fetching until authenticated (mirrors
  // profile_repository_test.dart's same gate group).
  group('organizationProvider — logged-out fetch gate', () {
    late int requests;

    ProviderContainer buildContainer(StateProvider<bool> authed) {
      requests = 0;
      final client = MockClient((req) async {
        requests++;
        return http.Response(
          jsonEncode(_orgJson()),
          200,
          headers: {'content-type': 'application/json'},
          request: req,
        );
      });
      final container = ProviderContainer(
        overrides: [
          authControllerProvider.overrideWith(() => _FakeAuthController()),
          isAuthenticatedProvider.overrideWith((ref) => ref.watch(authed)),
          apiClientProvider.overrideWith(
            (ref) => ApiClient(ref, httpClient: client),
          ),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test(
      'initializing the provider while logged out fetches nothing',
      () async {
        final authed = StateProvider<bool>((_) => false);
        final container = buildContainer(authed);

        container.listen(organizationProvider, (_, __) {});
        // Drain microtasks so any (wrongly) started fetch gets a chance to run.
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(requests, 0);
        expect(container.read(organizationProvider).isLoading, isTrue);
      },
    );

    test('the fetch fires once a session appears', () async {
      final authed = StateProvider<bool>((_) => false);
      final container = buildContainer(authed);

      container.listen(organizationProvider, (_, __) {});
      await Future<void>.delayed(Duration.zero);
      expect(requests, 0, reason: 'still logged out — no fetch yet');

      container.read(authed.notifier).state = true;
      final org = await container.read(organizationProvider.future);

      expect(org?.name, 'Serra Apiaries');
      expect(requests, 1);
    });
  });
}
