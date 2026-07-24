import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/storage/local_prefs.dart';

/// The caller's organization
/// (contracts/openapi/organizations.openapi.yaml's Organization schema,
/// FR-ONB-2).
class Organization {
  const Organization({
    required this.id,
    required this.name,
    required this.address,
    required this.createdBy,
    required this.role,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Organization.fromJson(Map<String, dynamic> json) => Organization(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    address: json['address'] as String? ?? '',
    createdBy: json['created_by'] as String? ?? '',
    role: json['role'] as String? ?? 'user',
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );

  final String id;
  final String name;
  final String address;
  final String createdBy;

  /// The caller's own membership role in this org (admin/user) — not a
  /// property of the organization itself (#172).
  final String role;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Value equality (MEDIUM-2): organizationProvider is watched by the
  // router's redirect logic (app_router.dart) — without this, a re-fetch
  // that returns the same organization compares unequal (default identity
  // equality) and can trigger a redundant redirect re-evaluation/rebuild.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Organization &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          address == other.address &&
          createdBy == other.createdBy &&
          role == other.role &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt);

  @override
  int get hashCode =>
      Object.hash(id, name, address, createdBy, role, createdAt, updatedAt);
}

/// Reads/creates the caller's organization via `GET /v1/organizations/me` and
/// `POST /v1/organizations`. Unlike apiaries, this is a direct REST call, not
/// PowerSync-mediated: organization creation is a one-off onboarding step
/// (like profile), not a field-recorded, offline-first entity — there is
/// nothing to sync until an org (and its replicated slice) exists.
///
/// Caches the last-known-good [fetchMine] response in durable local storage
/// (#390) — see [ProfileRepository]'s own doc for the same rationale: the
/// onboarding gate (`routing/app_router.dart`) stays passable offline for a
/// previously-onboarded user, falling back to the cache only on
/// [ApiNetworkException] (never on the 404 "no org yet" [ApiException] —
/// that is a real, resolved answer, not a network failure).
class OrganizationRepository {
  OrganizationRepository(this._api, {LocalPrefs? prefs})
    : _prefs = prefs ?? createLocalPrefs();

  final ApiClient _api;
  final LocalPrefs _prefs;
  static const _uuid = Uuid();

  /// Fetches the caller's own organization, or throws [ApiException] (404)
  /// if they have none yet — the signal the org-completion gate probes for.
  Future<Organization> fetchMine() async {
    try {
      final json = await _api.getJson('/organizations/me');
      _prefs.write(kOrganizationCacheKey, jsonEncode(json));
      return Organization.fromJson(json);
    } on ApiNetworkException {
      final cached = _prefs.read(kOrganizationCacheKey);
      if (cached == null) rethrow;
      return Organization.fromJson(jsonDecode(cached) as Map<String, dynamic>);
    }
  }

  /// Creates an organization with the caller as its first admin (D-3). The
  /// id is client-generated so the caller can address the resource from the
  /// response without a round trip.
  Future<Organization> create({required String name, String? address}) async {
    final body = <String, dynamic>{
      'id': _uuid.v4(),
      'name': name,
      if (address != null && address.isNotEmpty) 'address': address,
    };
    final json = await _api.postJson('/organizations', body);
    return Organization.fromJson(json);
  }
}

final organizationRepositoryProvider = Provider<OrganizationRepository>((ref) {
  return OrganizationRepository(ref.watch(apiClientProvider));
});

/// The caller's organization, or `null` when they have none yet (a 404 from
/// `GET /organizations/me` is the expected "not onboarded" case, not an
/// error — everything else rethrows). `AsyncNotifier` so the onboarding form
/// can create one and refresh state, matching `ProfileController`'s shape.
class OrganizationController extends AsyncNotifier<Organization?> {
  @override
  Future<Organization?> build() async {
    // Same logged-out gate as ProfileController.build (see its comment):
    // stay pending without fetching so this provider's eager initializers
    // (the router's redirect listens, app.dart's membership-loss purge
    // listener) can't fire unauthenticated 401 `GET /v1/organizations/me`
    // retry storms at boot; the watch re-runs build on login.
    if (!ref.watch(isAuthenticatedProvider)) {
      return Completer<Organization?>().future;
    }
    final repo = ref.watch(organizationRepositoryProvider);
    try {
      return await repo.fetchMine();
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Creates the organization and refreshes state with the server's
  /// response. Rethrows on failure (e.g. [ApiException] for a 422) so the
  /// calling screen can surface field errors.
  Future<void> submit({required String name, String? address}) async {
    final repo = ref.read(organizationRepositoryProvider);
    final created = await repo.create(name: name, address: address);
    state = AsyncData(created);
  }
}

final organizationProvider =
    AsyncNotifierProvider<OrganizationController, Organization?>(
      OrganizationController.new,
    );

/// Whether the caller has completed org onboarding — derived from
/// [organizationProvider], defaulting to `false` while loading/erroring. The
/// router gates on [organizationProvider]'s own `AsyncValue` directly instead
/// (so it can tell "still loading" apart from "resolved: no org yet" and
/// avoid bouncing on a loading flicker, exactly like
/// profileProvider/app_router.dart); this provider is for callers that only
/// care about the resolved-or-default answer. Mirrors
/// [profileCompleteProvider]'s same auth-gated-read shape: only watches
/// [organizationProvider] once authenticated, since reading it while logged
/// out would otherwise fire an unauthenticated (401) `GET
/// /v1/organizations/me` for no reason — there is nothing to gate before a
/// session exists (the router already sends an unauthenticated caller to
/// /login first).
final hasOrganizationProvider = Provider<bool>((ref) {
  if (!ref.watch(isAuthenticatedProvider)) return false;
  return ref.watch(organizationProvider).value != null;
});

/// Whether the caller is an admin of their own org — derived from
/// [organizationProvider]'s resolved `role`, defaulting to `false` while
/// loading/erroring/absent (fails closed: admin-only UI stays hidden until
/// proven otherwise, same posture as [profileCompleteProvider]/
/// [hasOrganizationProvider]). Used to gate admin-only navigation (#172) —
/// the server independently enforces the same admin-only rule on the
/// destination endpoints (auth.md §5.3), so this is a UX nicety (don't show
/// a link that would just 403), not the security boundary itself.
final isOrgAdminProvider = Provider<bool>((ref) {
  if (!ref.watch(isAuthenticatedProvider)) return false;
  return ref.watch(organizationProvider).value?.role == 'admin';
});
