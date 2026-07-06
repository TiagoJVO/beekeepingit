import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';

enum GatewayReachability { reachable, unreachable }

/// AC5 of #21: "the skeleton ... can call a backend endpoint through the
/// gateway". No domain Go service exists yet (#20/#23 are still open) — the
/// one real backend routed through the gateway today is Keycloak (#84), so
/// this calls its OIDC discovery document. It is a genuine reachability
/// check, not a stub, and gets superseded by a real API call once #23 lands.
final gatewayReachabilityProvider = FutureProvider<GatewayReachability>((
  ref,
) async {
  final uri = Uri.parse(
    '${AppConfig.gatewayBaseUrl}/realms/beekeepingit/.well-known/openid-configuration',
  );
  try {
    final response = await http.get(uri).timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) return GatewayReachability.unreachable;
    final body = jsonDecode(response.body);
    return body is Map<String, dynamic> && body.containsKey('issuer')
        ? GatewayReachability.reachable
        : GatewayReachability.unreachable;
  } catch (_) {
    return GatewayReachability.unreachable;
  }
});
