import 'dart:convert';
import 'dart:math';

/// A high-entropy PKCE `code_verifier` (RFC 7636 §4.1): 43–128 chars from the
/// URL-safe unreserved set. We generate it ourselves and hand it to
/// `openid_client`'s `Flow.authorizationCodeWithPKCE(codeVerifier: …)` — the
/// library derives the S256 `code_challenge` and keeps the verifier private, so
/// owning it here is what lets us persist it across the redirect and reconstruct
/// the flow in the callback (auth.md §3.2 — the PWA is a public client, S256).
String randomVerifier() {
  final rnd = Random.secure();
  final data = List<int>.generate(48, (_) => rnd.nextInt(256));
  return base64UrlEncode(data).replaceAll('=', '');
}
