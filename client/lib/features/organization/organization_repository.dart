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
    // Defaulted rather than required (FR-AP-9, #296): empty IS the unset value
    // server-side (a NOT NULL DEFAULT '' column), so every existing construction
    // site means exactly "no number" without restating it.
    this.registrationNumber = '',
    required this.createdBy,
    required this.role,
    required this.createdAt,
    required this.updatedAt,
    this.etag,
  });

  /// [etag] is the `ETag` header of the response [json] came from — NOT a
  /// field of the JSON body, which is why it is a separate argument. It
  /// travels with the organization so a later write can round it back as
  /// `If-Match` (see [etag]).
  factory Organization.fromJson(Map<String, dynamic> json, {String? etag}) =>
      Organization(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        address: json['address'] as String? ?? '',
        registrationNumber: json['registration_number'] as String? ?? '',
        createdBy: json['created_by'] as String? ?? '',
        role: json['role'] as String? ?? 'user',
        createdAt: DateTime.parse(json['created_at'] as String),
        updatedAt: DateTime.parse(json['updated_at'] as String),
        etag: etag,
      );

  final String id;
  final String name;
  final String address;

  /// The organization-wide DEFAULT beekeeper registration number
  /// (FR-AP-9, #296) — empty when unset. The authority issues one number per
  /// BEEKEEPER, so this is where it belongs; an apiary may override it
  /// (`Apiary.registrationNumber`) when one organization covers several
  /// beekeepers. Resolve what an apiary actually displays through
  /// `features/organization/registration_number.dart`, never from either half
  /// alone.
  ///
  /// Read offline: [OrganizationRepository.fetchMine] caches the whole
  /// organization JSON in local prefs, so every screen still resolves numbers
  /// with no connectivity. WRITING it needs connectivity (it is a REST PATCH,
  /// not a synced entity) — acceptable for a reference number entered once,
  /// and the reason FR-AP-9 says "read offline, edited online".
  final String registrationNumber;
  final String createdBy;

  /// The caller's own membership role in this org (admin/user) — not a
  /// property of the organization itself (#172).
  final String role;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// The opaque version stamp of the READ this instance came from — the
  /// server's `ETag` header (`etagFor`, derived from `updated_at`;
  /// services/organizations/api/organizations.go). Sent back as `If-Match` on
  /// the details PATCH so a save built on a version another admin has since
  /// replaced is answered 409 rather than silently winning (#601,
  /// FR-TEN-2/FR-HIS-1).
  ///
  /// It must stay glued to the organization it was read WITH — the details
  /// screen diffs against the organization it seeded from, and validating a
  /// save against any later version would check nothing. Carrying it on the
  /// value, rather than in a repository-side "last ETag" slot, is what makes
  /// that true by construction.
  ///
  /// Null when this organization did not come from a live read: the offline
  /// cache stores the response BODY only, so a cached organization has no
  /// version stamp and its save falls back to today's unconditional PATCH
  /// (the server treats an absent `If-Match` as "proceed"). Acceptable — the
  /// cache exists so the onboarding gate stays passable offline, and editing
  /// these details needs connectivity anyway; the first online read re-arms
  /// the check.
  final String? etag;

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
          registrationNumber == other.registrationNumber &&
          createdBy == other.createdBy &&
          role == other.role &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt &&
          // Part of the value, not incidental: two instances holding
          // different version stamps are NOT interchangeable as the baseline
          // of a save. In practice the stamp is a function of updatedAt, so
          // this only ever separates a live read from a cached one (whose
          // stamp is null).
          etag == other.etag);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    address,
    registrationNumber,
    createdBy,
    role,
    createdAt,
    updatedAt,
    etag,
  );
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
      final resp = await _api.get('/organizations/me');
      _prefs.write(kOrganizationCacheKey, jsonEncode(resp.body));
      // The version stamp of THIS read travels with the organization it
      // describes (see [Organization.etag]) — the cache keeps the body only.
      return Organization.fromJson(resp.body, etag: resp.headers['etag']);
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

  /// Updates the organization's editable details — name, address and the
  /// registration-number default (FR-ONB-2/FR-AP-9, #296) — via
  /// `PATCH /v1/organizations/{id}`, and refreshes the offline cache with the
  /// server's response so every screen resolves them correctly the next time
  /// the device is offline.
  ///
  /// One call rather than three: the organization-details screen edits the
  /// three fields together behind a single save, and the contract's
  /// `OrganizationUpdate` accepts them together.
  ///
  /// **Sends only what actually changed**, diffed against [current] — the
  /// organization the calling screen was seeded from. A PATCH that always
  /// carried all three keys would make a save a lost-update machine: a field
  /// the user never touched would silently overwrite whatever a concurrent
  /// admin had changed meanwhile, AND the server's audit row (`FR-HIS-1`,
  /// "who changed what") would name this caller as having changed a field
  /// they never looked at. Omitting unchanged keys makes both impossible by
  /// construction. Returns `null` when nothing changed — no request is sent
  /// at all, since `OrganizationUpdate` has `minProperties: 1` and an empty
  /// body would 422.
  ///
  /// **Conditional on [current]'s version stamp** (#601): the PATCH carries
  /// `If-Match: <etag of the read [current] came from>`, so the remaining
  /// race — two admins editing the SAME field — ends in a 409 the caller
  /// surfaces, not in a silent last-write-wins. The stamp must be [current]'s
  /// own; anything newer would validate the save against a version the user
  /// never saw. Omitted when [current] has none (a cached, offline read), in
  /// which case the server proceeds as it does today.
  ///
  /// Admin-only server-side (the same guard every other org edit carries);
  /// a non-admin caller gets a 403 [ApiException] the calling screen
  /// surfaces. A field the user BLANKED is sent as an explicit `null` — the
  /// contract's clear — so a mistyped value can be removed, not only
  /// overwritten; a field the user never touched is absent entirely. Those
  /// two are different requests and must stay so.
  Future<Organization?> updateDetails(
    Organization current, {
    required String name,
    required String address,
    required String registrationNumber,
  }) async {
    final body = <String, dynamic>{};
    final trimmedName = name.trim();
    if (trimmedName != current.name) body['name'] = trimmedName;
    final trimmedAddress = address.trim();
    if (trimmedAddress != current.address) {
      body['address'] = trimmedAddress.isEmpty ? null : trimmedAddress;
    }
    final trimmedNumber = registrationNumber.trim();
    if (trimmedNumber != current.registrationNumber) {
      body['registration_number'] = trimmedNumber.isEmpty
          ? null
          : trimmedNumber;
    }
    if (body.isEmpty) return null;

    final resp = await _api.patch(
      '/organizations/${current.id}',
      body,
      // Absent, not empty, when the baseline carries no stamp.
      headers: {'If-Match': ?current.etag},
    );
    _prefs.write(kOrganizationCacheKey, jsonEncode(resp.body));
    // The PATCH answers with the row's NEW stamp; carrying it forward is what
    // lets a second save from the same screen be conditional too.
    return Organization.fromJson(resp.body, etag: resp.headers['etag']);
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
    return _fetch();
  }

  /// The fetch itself, without the logged-out gate, so [refresh] can re-run
  /// exactly the same request-and-404-mapping [build] does.
  Future<Organization?> _fetch() async {
    final repo = ref.read(organizationRepositoryProvider);
    try {
      return await repo.fetchMine();
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Re-asks `GET /v1/organizations/me`, which is also the server's
  /// accept-on-login step (auth.md §8.7) — so a pending invitation matching
  /// the caller's verified address is claimed by this call. There is no
  /// client-side accept endpoint and none is needed.
  ///
  /// Deliberately no `AsyncLoading` transition: the waiting screen drives its
  /// own spinner, and emitting one here would wake every
  /// `ref.watch(organizationProvider.future)` consumer across the app for a
  /// check the user did not navigate away from.
  Future<void> refresh() async {
    state = await AsyncValue.guard(_fetch);
  }

  /// Creates the organization and refreshes state with the server's
  /// response. Rethrows on failure (e.g. [ApiException] for a 422) so the
  /// calling screen can surface field errors.
  Future<void> submit({required String name, String? address}) async {
    final repo = ref.read(organizationRepositoryProvider);
    final created = await repo.create(name: name, address: address);
    state = AsyncData(created);
  }

  /// Saves the organization's editable details — name, address and the
  /// registration-number default (FR-ONB-2/FR-AP-9, #296) — and refreshes
  /// state with the server's response, so every apiary's effective number
  /// re-resolves immediately.
  ///
  /// [from] is the organization the calling screen's fields were SEEDED from,
  /// not necessarily the current [state] — that is deliberate. A refresh can
  /// land while the user is mid-edit (the details screen won't re-seed over
  /// live typing), and diffing against anything but the seed would turn the
  /// screen's now-stale untouched fields into overwrites of whatever arrived.
  /// See [OrganizationRepository.updateDetails].
  ///
  /// Leaves state untouched when nothing changed (no request was sent).
  /// Rethrows on failure (403 for a non-admin, 422 for an over-long value,
  /// **409 when another admin changed the organization since [from] was
  /// read**) so the calling screen can surface it — the 409 needs its own
  /// copy, since "try again" is the wrong advice for it (#601).
  ///
  /// Returns whether a PATCH was actually SENT — `false` means every field
  /// still matched [from], so there was nothing to save. The caller needs
  /// this to tell a real save apart from a no-op: reporting "saved" for a
  /// request that never left the device is exactly how a silently-dropped
  /// edit looks identical to a stored one.
  Future<bool> saveDetails({
    required Organization from,
    required String name,
    required String address,
    required String registrationNumber,
  }) async {
    final repo = ref.read(organizationRepositoryProvider);
    final updated = await repo.updateDetails(
      from,
      name: name,
      address: address,
      registrationNumber: registrationNumber,
    );
    if (updated == null) return false;
    state = AsyncData(updated);
    return true;
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
