import 'dart:async';

import 'package:beekeepingit_client/core/auth/auth_controller.dart';
import 'package:beekeepingit_client/features/organization/organization_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the two *membership predicates* derived from
/// `organizationProvider` — [hasOrganizationProvider] and
/// [isOrgAdminProvider].
///
/// [hasOrganizationProvider] stopped being a convenience read for widgets with
/// #622: it is now the precondition the whole sync layer hangs off
/// (`core/sync/powersync_service.dart`'s `applySyncPreconditions`, the
/// connector's `fetchCredentials`, and `syncNowProvider`), so *when exactly it
/// answers `true`* decides whether an onboarded beekeeper's queued writes
/// leave the device at all. That contract is pinned here, once, rather than
/// implied by each of those call sites.
///
/// The interesting case is the last one: an `AsyncError` that arrives **after**
/// a good load still reports `true`, because Riverpod copies the previous value
/// onto the new error state (`AsyncError.copyWithPrevious`, riverpod
/// `element.dart`'s `asyncTransition`). That is what keeps a fully onboarded
/// user syncing across a transient `GET /v1/organizations/me` failure — a
/// behavior inherited from the framework, so it is asserted here rather than
/// assumed.
Organization _org({String role = 'user'}) => Organization(
  id: 'org-1',
  name: 'Serra Apiaries',
  address: '123 Serra Rd',
  createdBy: 'user-1',
  role: role,
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 1, 2),
);

/// A scripted [OrganizationController] whose `build()` is driven by the test
/// and **counted** — the count is what makes "logged out fetches nothing"
/// assertable: `hasOrganizationProvider` returning `false` proves nothing on
/// its own, since a provider that eagerly fired an unauthenticated
/// `GET /v1/organizations/me` and then defaulted to `false` would look
/// identical.
///
/// A fake, not a mock (Dart conventions) — and deliberately replacing
/// `build()` wholesale rather than the repository underneath it, so these
/// tests exercise the *predicate's* handling of each `AsyncValue` shape
/// without re-testing `OrganizationController`'s own 404 mapping (covered in
/// organization_repository_test.dart).
class _ScriptedOrganizationController extends OrganizationController {
  _ScriptedOrganizationController(this._build);

  /// Resolves to an organization straight away.
  _ScriptedOrganizationController.resolving(Organization? org)
    : _build = (() async => org);

  /// Never resolves — the "still loading" case.
  _ScriptedOrganizationController.pending()
    : _build = (() => Completer<Organization?>().future);

  /// Fails on the very first load, with no previous value to fall back on.
  _ScriptedOrganizationController.failing(Object error)
    : _build = (() async => throw error);

  final Future<Organization?> Function() _build;

  int buildCalls = 0;

  @override
  Future<Organization?> build() {
    buildCalls++;
    return _build();
  }

  /// The transition `OrganizationController.refresh()` produces when a
  /// re-fetch fails (`state = await AsyncValue.guard(_fetch)`).
  void failWith(Object error) => state = AsyncError(error, StackTrace.current);
}

ProviderContainer _containerWith({
  required bool authenticated,
  required OrganizationController controller,
}) {
  final container = ProviderContainer(
    overrides: [
      isAuthenticatedProvider.overrideWithValue(authenticated),
      organizationProvider.overrideWith(() => controller),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('hasOrganizationProvider (#622 — the switch sync now hangs off)', () {
    test('logged out: false, and organizationProvider is never even built — '
        'no unauthenticated GET /v1/organizations/me at boot', () {
      final controller = _ScriptedOrganizationController.resolving(_org());
      final container = _containerWith(
        authenticated: false,
        controller: controller,
      );

      expect(container.read(hasOrganizationProvider), isFalse);
      expect(
        controller.buildCalls,
        0,
        reason: 'the auth gate must short-circuit before the fetch',
      );
    });

    test('still loading: false — fails closed, so sync stays parked until the '
        'membership question has an actual answer', () async {
      final container = _containerWith(
        authenticated: true,
        controller: _ScriptedOrganizationController.pending(),
      );

      container.read(organizationProvider);
      await pumpEventQueue();

      expect(container.read(organizationProvider).isLoading, isTrue);
      expect(container.read(hasOrganizationProvider), isFalse);
    });

    test('resolved to an organization: true', () async {
      final container = _containerWith(
        authenticated: true,
        controller: _ScriptedOrganizationController.resolving(_org()),
      );

      await container.read(organizationProvider.future);

      expect(container.read(hasOrganizationProvider), isTrue);
    });

    test('resolved to null (the 404 "no org yet" answer): false — this is the '
        'onboarding case #622 stops from probing/connecting', () async {
      final container = _containerWith(
        authenticated: true,
        controller: _ScriptedOrganizationController.resolving(null),
      );

      await container.read(organizationProvider.future);

      expect(container.read(hasOrganizationProvider), isFalse);
    });

    test('errored AFTER a good load: still true — a transient '
        'GET /v1/organizations/me failure must not silently stop an onboarded '
        "user's sync", () async {
      final controller = _ScriptedOrganizationController.resolving(_org());
      final container = _containerWith(
        authenticated: true,
        controller: controller,
      );
      // Listen so the derived provider is recomputed on the transition rather
      // than being read once and cached.
      container.listen(hasOrganizationProvider, (_, _) {});
      await container.read(organizationProvider.future);
      expect(container.read(hasOrganizationProvider), isTrue);

      controller.failWith(Exception('offline'));

      final async = container.read(organizationProvider);
      expect(async.hasError, isTrue, reason: 'test setup sanity check');
      // The mechanism, asserted rather than believed: Riverpod hands the new
      // AsyncError the previous state's value
      // (`AsyncError.copyWithPrevious`), so `.value` survives the failure.
      expect(async.value, _org());
      expect(
        container.read(hasOrganizationProvider),
        isTrue,
        reason: 'membership is last-known-good across a failed re-fetch',
      );
    });

    test('errored cold, with no previous value: false', () async {
      final container = _containerWith(
        authenticated: true,
        controller: _ScriptedOrganizationController.failing(
          Exception('offline'),
        ),
      );

      // Listened, not awaited through `.future`: an un-listened failing
      // provider parks its `.future` (and would surface as an unhandled
      // async error), whereas what this test is about is the *state* the
      // predicate reads.
      container.listen(organizationProvider, (_, _) {});
      await pumpEventQueue();
      expect(
        container.read(organizationProvider).hasError,
        isTrue,
        reason: 'test setup sanity check',
      );

      // Fail-closed, and nothing is lost by it: the router gates onboarding on
      // `organizationProvider`'s own AsyncValue (app_router.dart), so a caller
      // whose very first membership read failed is sitting on
      // /organization/new — sync being off matches exactly what they can see.
      expect(container.read(hasOrganizationProvider), isFalse);
    });
  });

  group('isOrgAdminProvider (the same fail-closed default, for admin-only '
      'UI)', () {
    test('logged out: false', () {
      final controller = _ScriptedOrganizationController.resolving(
        _org(role: 'admin'),
      );
      final container = _containerWith(
        authenticated: false,
        controller: controller,
      );

      expect(container.read(isOrgAdminProvider), isFalse);
      expect(controller.buildCalls, 0);
    });

    test('resolved admin: true; resolved plain member: false', () async {
      final admin = _containerWith(
        authenticated: true,
        controller: _ScriptedOrganizationController.resolving(
          _org(role: 'admin'),
        ),
      );
      await admin.read(organizationProvider.future);
      expect(admin.read(isOrgAdminProvider), isTrue);

      final member = _containerWith(
        authenticated: true,
        controller: _ScriptedOrganizationController.resolving(
          _org(role: 'user'),
        ),
      );
      await member.read(organizationProvider.future);
      expect(member.read(isOrgAdminProvider), isFalse);
    });

    test('still loading: false — admin-only navigation stays hidden until '
        'proven otherwise', () async {
      final container = _containerWith(
        authenticated: true,
        controller: _ScriptedOrganizationController.pending(),
      );

      container.read(organizationProvider);
      await pumpEventQueue();

      expect(container.read(isOrgAdminProvider), isFalse);
    });
  });
}
