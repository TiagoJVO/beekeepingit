import 'dart:convert';
import 'dart:developer' as developer;

import '../storage/local_prefs.dart';

/// **Who the on-device local store belongs to** (#664, D-38, FR-TEN-1,
/// FR-TEN-2, FR-OF-1, NFR-SEC-1).
///
/// The PWA opens **one** on-disk database per browser profile —
/// `powersync_service.dart`'s `_dbFilename` is a constant, not a per-user
/// path — so on a shared field device the store user B opens is byte-for-byte
/// the one user A left behind. Logout wipes it (`AuthController.logout`) and
/// so does a membership loss (`local_data_purge.dart`), but **closing the
/// browser without logging out does neither**. This file is the third
/// trigger: the store is checked against the signed-in OIDC subject every
/// time it is opened, and purged when they differ.
///
/// Why the previous user's rows are visible at all, given the org filter every
/// repository applies (`WHERE organization_id = ? OR organization_id IS NULL`):
/// the `IS NULL` half is deliberate — a row created offline carries a NULL
/// `organization_id` until write-back stamps it server-side — and it is
/// precisely the hole. A never-synced row matches for **any** org, so user B
/// reads user A's offline todos, journeys and activities. Offline (FR-OF-1 —
/// the normal field case) PowerSync never reconciles buckets, so nothing
/// self-corrects.

/// Who the app believes is opening the local store, as far as its own OIDC
/// session can say. Three closed cases, each with a different answer to "may
/// this store be handed over as-is?" — see [ensureLocalStoreBelongsTo].
sealed class StoreOwner {
  const StoreOwner();
}

/// No session at all: signed out, or a boot that resolved logged-out (an
/// expired refresh token, a first run).
///
/// **Defers, does not purge.** Nobody is being shown anything yet — the
/// router keeps an unauthenticated user on `/login` — so there is no leak to
/// close here, and the next open that *does* carry a subject decides. Purging
/// on this case instead would destroy the returning user's own unsynced field
/// work every time their refresh token expired, which is exactly what #664's
/// second acceptance criterion forbids.
final class SignedOutOwner extends StoreOwner {
  const SignedOutOwner();
}

/// A session exists, but its OIDC subject could not be read out of the id
/// token — the store's owner is therefore unproven, so it is purged.
final class UnprovenOwner extends StoreOwner {
  const UnprovenOwner();
}

/// A session whose OIDC `sub` is known; [subject] is what the marker is
/// compared against.
final class KnownOwner extends StoreOwner {
  const KnownOwner(this.subject);

  final String subject;
}

/// Classifies the current auth session for [ensureLocalStoreBelongsTo].
///
/// Takes the two facts it needs rather than an `AuthSession`, so this file
/// stays free of a dependency on `core/auth/` (which already imports the sync
/// layer, so the reverse edge would close a cycle).
StoreOwner storeOwnerFromSession({
  required bool signedIn,
  required String? idToken,
}) {
  if (!signedIn) return const SignedOutOwner();
  final subject = oidcSubject(idToken);
  return subject == null ? const UnprovenOwner() : KnownOwner(subject);
}

/// Reads the OIDC `sub` claim out of a raw id token, or `null` when it cannot
/// be read for any reason (absent/empty token, not a three-part JWT, a payload
/// that is not base64url, not UTF-8, not JSON, not a JSON *object*, or one with
/// no usable `sub`).
///
/// **Unverified, and that is correct here.** The signature is not checked: this
/// reads a claim out of a token the app has *already* obtained through the
/// authorization-code + PKCE exchange (`auth_controller.dart`) purely to decide
/// **whose rows are on this disk**. It is not an authentication or
/// authorization boundary — the server re-verifies every token on every
/// request, and the sync token is minted server-side and org-scoped
/// (sync.md §3.4). A forged `sub` here buys an attacker nothing but a *purge*
/// of their own device: mismatching wipes, and matching only skips a wipe of
/// data they must already have had local access to in order to forge against.
///
/// **Never throws.** It runs ahead of the local store opening, and
/// [ensureLocalStoreBelongsTo] has to be able to fail *closed* (purge) rather
/// than crash the app on a malformed token.
String? oidcSubject(String? idToken) {
  if (idToken == null || idToken.isEmpty) return null;
  final parts = idToken.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = utf8.decode(
      base64Url.decode(base64Url.normalize(parts[1])),
    );
    final claims = jsonDecode(payload);
    // A JWT payload is a JSON object; anything else (an array, a bare string)
    // is not a token we can read an owner out of.
    if (claims is! Map) return null;
    final sub = claims['sub'];
    return (sub is String && sub.isNotEmpty) ? sub : null;
  } on FormatException {
    // The one exception family every step above throws: `base64Url.normalize`
    // on a non-base64url segment, `base64Url.decode` on bad padding,
    // `utf8.decode` on invalid bytes, `jsonDecode` on non-JSON.
    return null;
  }
}

/// Enforces that the local store about to be handed out belongs to [owner],
/// purging it first when that cannot be proven. Returns `true` when it purged.
///
/// A [KnownOwner]'s subject is compared against a marker persisted alongside
/// the store under [kLocalStoreSubjectKey] in durable [LocalPrefs]
/// (`localStorage` on web, so it survives a browser restart exactly as the
/// store itself does).
///
/// **The decision table**, exhaustive by construction (`switch` over a sealed
/// [StoreOwner]):
///
/// - [SignedOutOwner] — **keep, and leave the marker alone.** See its own doc.
/// - [UnprovenOwner] — **purge**, and claim nothing: a signed-in session whose
///   subject we cannot read must not be handed a store we cannot attribute,
///   and must not be allowed to stamp its name on one either.
/// - [KnownOwner] with a marker equal to its subject — **keep.** A token
///   expiry, a background tab restored days later, a browser restart. That is
///   #664's second acceptance criterion and the whole reason a subject
///   comparison was chosen over an unconditional wipe at login: unsynced
///   offline work (FR-OF-1) must survive a session boundary for the person who
///   wrote it.
/// - [KnownOwner] with any other marker — **purge**, then stamp. That covers a
///   different subject (the shared-device case #664 is about), an empty or
///   corrupt marker, a first-ever login, and a device whose store predates
///   this check or whose `localStorage` was evicted while OPFS survived.
///
/// **Fails closed.** The store is kept only where ownership is positively
/// proven or nobody is asking for it. Keeping a store whose owner is unproven
/// is the one outcome that leaks another user's rows (FR-TEN-1, FR-TEN-2,
/// NFR-SEC-1); purging one that was in fact ours costs, at worst, a re-sync of
/// data the server still holds — and, in the narrow unproven cases, the
/// unsynced remainder, which D-38 accepts explicitly.
///
/// **Write order is load-bearing: forget → purge → remember.** The marker is
/// removed *before* [purge] runs and only re-stamped after it has completed,
/// so an interrupted purge (a thrown error, a tab closed mid-wipe) leaves no
/// marker at all and the next open fails closed and purges again. Advancing
/// the marker first would hand the next user a store that merely *claims* to
/// be theirs. A throwing [purge] propagates for the same reason: the caller
/// must not hand out a store it failed to clean.
Future<bool> ensureLocalStoreBelongsTo({
  required StoreOwner owner,
  required LocalPrefs prefs,
  required Future<void> Function() purge,
}) async {
  switch (owner) {
    case SignedOutOwner():
      return false;
    case UnprovenOwner():
      _removeMarker(prefs);
      await purge();
      return true;
    case KnownOwner(:final subject):
      if (_readMarker(prefs) == subject) return false;
      _removeMarker(prefs);
      await purge();
      _writeMarker(prefs, subject);
      return true;
  }
}

/// The three marker accessors below absorb a **storage** failure, as distinct
/// from a bad *value* — which the caller above already handles by purging.
/// Browser `localStorage` throws (a `SecurityError`) when site data is blocked
/// or the page runs in a partitioned third-party context, and `write` throws
/// `QuotaExceededError` when the origin is full. Letting either escape would
/// take the whole sync layer down for a user whose store is in fact their own.
///
/// `on Object` rather than a narrower clause is deliberate here, against this
/// repo's usual rule: what `package:web`'s `localStorage` throws across the JS
/// interop boundary is not a Dart type this code can name, and the answer is
/// the same whatever it is.
String? _readMarker(LocalPrefs prefs) {
  try {
    return prefs.read(kLocalStoreSubjectKey);
  } on Object catch (e, st) {
    // Unreadable marker == unproven owner: purge. Same answer as absent.
    developer.log(
      'store-owner marker unreadable — treating the store as unproven',
      name: 'sync',
      error: e,
      stackTrace: st,
    );
    return null;
  }
}

void _removeMarker(LocalPrefs prefs) {
  try {
    prefs.remove(kLocalStoreSubjectKey);
  } on Object catch (e, st) {
    // Non-fatal: a marker that could not be cleared is about to be overwritten
    // on success, and on failure the caller's next open re-reads whatever is
    // actually there and re-decides.
    developer.log(
      'store-owner marker could not be cleared',
      name: 'sync',
      error: e,
      stackTrace: st,
    );
  }
}

void _writeMarker(LocalPrefs prefs, String owner) {
  try {
    prefs.write(kLocalStoreSubjectKey, owner);
  } on Object catch (e, st) {
    // The store IS clean at this point, so nothing leaks — but with no marker
    // persisted the next open will purge again. Loud rather than silent: a
    // storage backend that cannot keep this marker (a quota-full origin, or a
    // platform whose `LocalPrefs` is the no-op stub) means the device wipes its
    // offline work on every sign-in, which is a bug report, not a mystery.
    developer.log(
      'store-owner marker could not be persisted — the next sign-in will '
      'purge, losing unsynced offline work (D-38, #664)',
      name: 'sync',
      error: e,
      stackTrace: st,
    );
  }
}
