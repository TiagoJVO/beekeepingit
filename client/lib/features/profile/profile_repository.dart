import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/storage/local_prefs.dart';

/// The authenticated caller's own profile
/// (contracts/openapi/identity.openapi.yaml's Profile schema, FR-ONB-1).
class Profile {
  const Profile({
    required this.id,
    required this.name,
    required this.email,
    required this.locale,
    required this.profileComplete,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Profile.fromJson(Map<String, dynamic> json) => Profile(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    email: json['email'] as String? ?? '',
    locale: json['locale'] as String? ?? 'en',
    profileComplete: json['profile_complete'] as bool? ?? false,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );

  final String id;
  final String name;
  final String email;
  final String locale;
  final bool profileComplete;
  final DateTime createdAt;
  final DateTime updatedAt;

  // Value equality (MEDIUM-2): profileProvider is watched by the router's
  // redirect logic (app_router.dart) — without this, a re-fetch that
  // returns the same profile compares unequal (default identity equality)
  // and can trigger a redundant redirect re-evaluation/rebuild.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Profile &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          name == other.name &&
          email == other.email &&
          locale == other.locale &&
          profileComplete == other.profileComplete &&
          createdAt == other.createdAt &&
          updatedAt == other.updatedAt);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    email,
    locale,
    profileComplete,
    createdAt,
    updatedAt,
  );
}

/// Reads/writes the caller's profile via `GET`/`PATCH /v1/profile`. GET
/// lazily get-or-creates the row server-side on first login; PATCH is a
/// partial update — only the fields passed are sent.
///
/// Caches the last-known-good [fetch] response in durable local storage
/// (#390) so the onboarding gate (`routing/app_router.dart`) stays passable
/// offline for a previously-onboarded user: [fetch] serves that cached
/// snapshot when the request fails with [ApiNetworkException] rather than
/// bouncing them to `/profile`; a genuine server response (200 or an
/// [ApiException]) always wins over the cache.
class ProfileRepository {
  ProfileRepository(this._api, {LocalPrefs? prefs})
    : _prefs = prefs ?? createLocalPrefs();

  final ApiClient _api;
  final LocalPrefs _prefs;

  Future<Profile> fetch() async {
    try {
      final json = await _api.getJson('/profile');
      _prefs.write(kProfileCacheKey, jsonEncode(json));
      return Profile.fromJson(json);
    } on ApiNetworkException {
      final cached = _prefs.read(kProfileCacheKey);
      // No cache (never fetched successfully before, or already cleared by
      // logout) → nothing to fall back to; the network failure is the real,
      // actionable answer, so rethrow rather than fabricating a profile.
      if (cached == null) rethrow;
      return Profile.fromJson(jsonDecode(cached) as Map<String, dynamic>);
    }
  }

  Future<Profile> update({String? name, String? email, String? locale}) async {
    final body = <String, dynamic>{
      if (name != null) 'name': name,
      if (email != null) 'email': email,
      if (locale != null) 'locale': locale,
    };
    final json = await _api.patchJson('/profile', body);
    return Profile.fromJson(json);
  }
}

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  return ProfileRepository(ref.watch(apiClientProvider));
});

/// The caller's profile, fetched (and lazily created server-side) on first
/// read. `AsyncNotifier` (not a plain `FutureProvider`) because the
/// onboarding/edit form needs to mutate it and refetch.
class ProfileController extends AsyncNotifier<Profile> {
  @override
  Future<Profile> build() {
    // Logged out: stay pending (a never-completing future) WITHOUT touching
    // the network. This provider has eager initializers that exist for other
    // reasons — the router's redirect listens (app_router.dart) and
    // localeProvider (core/l10n) — and without this gate each of them fires
    // an unauthenticated 401 `GET /v1/profile` at boot, which Riverpod's
    // default policy then retries ~10x (the "401 storm"). Gating here, in
    // the one place the fetch originates, keeps every watcher safe by
    // construction; the isAuthenticated watch re-runs build the moment a
    // session appears, so login still fetches exactly as before.
    if (!ref.watch(isAuthenticatedProvider)) {
      return Completer<Profile>().future;
    }
    return ref.watch(profileRepositoryProvider).fetch();
  }

  /// Submits a (possibly partial) update and refreshes state with the
  /// server's response. Rethrows on failure (e.g. [ApiException] for a 422)
  /// so the calling screen can surface field errors; state is left as the
  /// last-known-good profile.
  ///
  /// Named `submit`, not `update` — `AsyncNotifier` already declares an
  /// `update(fn)` helper with an incompatible signature, and reusing that
  /// name here is a Dart `invalid_override` compile error.
  Future<void> submit({String? name, String? email, String? locale}) async {
    final repo = ref.read(profileRepositoryProvider);
    final updated = await repo.update(name: name, email: email, locale: locale);
    state = AsyncData(updated);
  }
}

final profileProvider = AsyncNotifierProvider<ProfileController, Profile>(
  ProfileController.new,
);

/// Whether the caller's profile is complete — derived from [profileProvider],
/// defaulting to `false` while loading/erroring. The router gates on
/// [profileProvider]'s own `AsyncValue` directly (so it can tell "still
/// loading" apart from "resolved incomplete" and avoid bouncing to /profile
/// on a loading flicker); this provider is for callers, like the profile
/// screen, that only care about the resolved-or-default answer. Only watches
/// [profileProvider] once authenticated: reading it while logged out would
/// otherwise fire an unauthenticated (401) GET /v1/profile for no reason —
/// there is nothing to gate before a session exists (the router already
/// sends an unauthenticated caller to /login first).
final profileCompleteProvider = Provider<bool>((ref) {
  if (!ref.watch(isAuthenticatedProvider)) return false;
  return ref.watch(profileProvider).value?.profileComplete ?? false;
});
