import 'package:beekeepingit_client/core/auth/auth_platform.dart';
import 'package:beekeepingit_client/core/sync/local_data_purge.dart';
import 'package:beekeepingit_client/core/sync/local_store.dart';
import 'package:beekeepingit_client/core/sync/powersync_service.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal in-memory [AuthPlatform] fake — this file only exercises
/// session-storage reads/writes (`bk.last_org_id`), never the OIDC redirect
/// surface, so it stubs the rest rather than importing
/// auth_controller_test.dart's fuller [AuthPlatform] fake.
class _FakeSessionPlatform implements AuthPlatform {
  final Map<String, String> _session = {};
  final Map<String, String> _local = {};

  @override
  String get redirectUri => 'https://app.example/';

  @override
  Uri get currentUri => Uri.parse('https://app.example/apiaries');

  @override
  void assignLocation(String url) {}

  @override
  void replaceLocation(Uri uri) {}

  @override
  String? readSession(String key) => _session[key];

  @override
  void writeSession(String key, String value) => _session[key] = value;

  @override
  void removeSession(String key) => _session.remove(key);

  @override
  String? readLocal(String key) => _local[key];

  @override
  void writeLocal(String key, String value) => _local[key] = value;

  @override
  void removeLocal(String key) => _local.remove(key);
}

/// A fake [LocalStoreEngine] so the purge's `clear()` call can be asserted
/// without a real PowerSync database (mirrors
/// auth_controller_test.dart's FakeLocalStoreEngine).
class _FakeLocalStoreEngine implements LocalStoreEngine {
  int clearCalls = 0;

  @override
  Future<void> clear() async => clearCalls++;

  @override
  Future<void> execute(String sql, [List<Object?> args = const []]) async {}

  @override
  Future<Map<String, Object?>?> getOptional(
    String sql, [
    List<Object?> args = const [],
  ]) async => null;

  @override
  Future<List<Map<String, Object?>>> getAll(
    String sql, [
    List<Object?> args = const [],
  ]) async => const [];

  @override
  Stream<List<Map<String, Object?>>> watch(
    String sql, [
    List<Object?> args = const [],
  ]) => const Stream.empty();
}

class _FakeOrganizationController extends OrganizationController {
  _FakeOrganizationController(this._initial);

  final Organization? _initial;

  @override
  Future<Organization?> build() async => _initial;

  /// Drives a re-fetch the way the real controller's `ref.invalidateSelf()`
  /// callers do, so tests can simulate "the next fetch comes back
  /// different" without a real ApiClient/HTTP call.
  void resolveTo(Organization? org) {
    state = AsyncData(org);
  }
}

Organization _org(String id) => Organization(
  id: id,
  name: 'Apiary Co.',
  address: '',
  createdBy: 'u1',
  role: 'user',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 1),
);

void main() {
  group('membershipLossPurgeProvider', () {
    test(
      'purges the local store when a resolved org disappears (membership revoked)',
      () async {
        final platform = _FakeSessionPlatform();
        final store = _FakeLocalStoreEngine();
        final controller = _FakeOrganizationController(_org('org-1'));

        final container = ProviderContainer(
          overrides: [
            organizationProvider.overrideWith(() => controller),
            authPlatformProvider.overrideWithValue(platform),
            localStoreProvider.overrideWith((ref) async => store),
          ],
        );
        addTearDown(container.dispose);

        // Start the listener and let the initial (has-an-org) resolution settle.
        container.listen(membershipLossPurgeProvider, (_, __) {});
        await container.read(organizationProvider.future);
        await Future<void>.delayed(Duration.zero);

        expect(platform.readSession('bk.last_org_id'), 'org-1');
        expect(store.clearCalls, 0, reason: 'no loss yet — must not purge');

        // Membership revoked: the next resolution comes back with no org.
        controller.resolveTo(null);
        await Future<void>.delayed(Duration.zero);

        expect(store.clearCalls, 1);
        expect(
          platform.readSession('bk.last_org_id'),
          isNull,
          reason: 'the stale marker is cleared once the purge fires',
        );
      },
    );

    test(
      'first-time onboarding (no org yet, no prior marker) does not purge',
      () async {
        final platform = _FakeSessionPlatform();
        final store = _FakeLocalStoreEngine();
        final controller = _FakeOrganizationController(null);

        final container = ProviderContainer(
          overrides: [
            organizationProvider.overrideWith(() => controller),
            authPlatformProvider.overrideWithValue(platform),
            localStoreProvider.overrideWith((ref) async => store),
          ],
        );
        addTearDown(container.dispose);

        container.listen(membershipLossPurgeProvider, (_, __) {});
        await container.read(organizationProvider.future);
        await Future<void>.delayed(Duration.zero);

        expect(store.clearCalls, 0);
        expect(platform.readSession('bk.last_org_id'), isNull);
      },
    );

    test(
      'records the org marker again after a legitimate re-onboarding',
      () async {
        final platform = _FakeSessionPlatform();
        final store = _FakeLocalStoreEngine();
        final controller = _FakeOrganizationController(_org('org-1'));

        final container = ProviderContainer(
          overrides: [
            organizationProvider.overrideWith(() => controller),
            authPlatformProvider.overrideWithValue(platform),
            localStoreProvider.overrideWith((ref) async => store),
          ],
        );
        addTearDown(container.dispose);

        container.listen(membershipLossPurgeProvider, (_, __) {});
        await container.read(organizationProvider.future);
        await Future<void>.delayed(Duration.zero);

        controller.resolveTo(_org('org-2'));
        await Future<void>.delayed(Duration.zero);

        expect(
          store.clearCalls,
          0,
          reason: 'switching to a resolved org is not a loss',
        );
        expect(platform.readSession('bk.last_org_id'), 'org-2');
      },
    );
  });
}
