import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// A PKCE (RFC 7636) verifier/challenge pair for the OIDC Authorization Code
/// flow (auth.md §3.2 — the PWA is a public client, S256).
class Pkce {
  const Pkce({required this.verifier, required this.challenge});

  final String verifier;
  final String challenge;

  static Pkce generate() {
    final verifier = _randomUrlSafe(64);
    final digest = sha256.convert(ascii.encode(verifier));
    final challenge = base64UrlEncode(digest.bytes).replaceAll('=', '');
    return Pkce(verifier: verifier, challenge: challenge);
  }
}

/// A URL-safe random string (also used for the OAuth `state`).
String randomState() => _randomUrlSafe(32);

String _randomUrlSafe(int bytes) {
  final rnd = Random.secure();
  final data = List<int>.generate(bytes, (_) => rnd.nextInt(256));
  return base64UrlEncode(data).replaceAll('=', '');
}
