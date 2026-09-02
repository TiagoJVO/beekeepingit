import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_controller.dart';
import '../config/app_config.dart';

/// Field-level detail on a 422 (RFC 9457 `Problem.errors[]`).
class ApiFieldError {
  const ApiFieldError({
    required this.field,
    required this.code,
    required this.message,
  });

  factory ApiFieldError.fromJson(Map<String, dynamic> json) => ApiFieldError(
    field: json['field'] as String? ?? '',
    code: json['code'] as String? ?? '',
    message: json['message'] as String? ?? '',
  );

  final String field;
  final String code;
  final String message;
}

/// A non-2xx REST response, carrying the RFC 9457 Problem Details fields
/// (api-contracts.md §7) so callers can branch on [code] rather than parsing
/// [detail] text. [fieldErrors] is populated for 422 validation failures.
class ApiException implements Exception {
  const ApiException({
    required this.statusCode,
    required this.code,
    required this.detail,
    this.fieldErrors = const [],
  });

  final int statusCode;
  final String code;

  /// Free-text, server-supplied and **not localized** to the app's EN/PT
  /// locales (MEDIUM-5) — genuinely translating it would need a shared
  /// translation-key protocol between every backend service and this client
  /// (RFC 9457 `detail` is prose, not a key), which is out of scope here.
  /// UI code should prefer branching on [code] (already the documented
  /// pattern above) and showing its own localized copy, falling back to
  /// [detail] only as a last-resort, un-translated diagnostic string.
  final String detail;
  final List<ApiFieldError> fieldErrors;

  @override
  String toString() => 'ApiException($statusCode, $code, $detail)';
}

/// A network-level failure — the request never reached the server (or its
/// response never came back): no connectivity, DNS failure, a dropped
/// connection, a timeout. Distinct from [ApiException] (a response WAS
/// received, just a non-2xx one) so an offline-aware caller can branch on
/// "no signal" vs. "the server rejected this" without inspecting the raw
/// underlying exception type (MEDIUM-5).
class ApiNetworkException implements Exception {
  const ApiNetworkException(this.cause);

  /// The underlying exception `package:http` (or the platform) threw —
  /// typically a `SocketException`/`http.ClientException`/`TimeoutException`.
  final Object cause;

  @override
  String toString() => 'ApiNetworkException($cause)';
}

/// A decoded 2xx response together with the response's own headers — for the
/// few callers that need something the JSON body does not carry.
///
/// Today that is exactly one thing: the `ETag` version stamp
/// `GET /v1/organizations/me` and `PATCH /v1/organizations/{id}` return
/// (`etagFor`, services/organizations/api/organizations.go), which the
/// organization-details save rounds back as `If-Match` so a concurrent
/// same-field edit is answered with a 409 instead of being silently
/// overwritten (#601, FR-TEN-2/FR-HIS-1). Kept as a general body+headers pair
/// rather than an ETag-shaped accessor so no HTTP semantics leak into
/// [ApiClient]'s surface, and deliberately NOT the default return type: the
/// `*Json` methods below stay body-only, so no existing caller changes.
class ApiResponse {
  const ApiResponse({required this.body, required this.headers});

  final Map<String, dynamic> body;

  /// The response headers, lower-cased (`package:http` normalizes them), so a
  /// lookup is `headers['etag']`, never `headers['ETag']`.
  final Map<String, String> headers;
}

/// Generic, profile-agnostic REST client wrapping `package:http`: injects the
/// bearer token from the auth feature's public surface, encodes/decodes JSON,
/// and maps non-2xx responses to [ApiException]. Feature repositories (e.g.
/// `features/profile`) build on this rather than talking to `http` directly.
class ApiClient {
  ApiClient(this._ref, {http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  final Ref _ref;
  final http.Client _http;

  Uri _uri(String path) => Uri.parse('${AppConfig.gatewayBaseUrl}/v1$path');

  /// The headers every request carries, plus any per-request [extra] — which
  /// wins on a collision, so a caller can override a default deliberately
  /// (nothing does today) but cannot drop the bearer token by accident.
  Future<Map<String, String>> _headers([Map<String, String>? extra]) async {
    final token = await _ref
        .read(authControllerProvider.notifier)
        .accessToken();
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      ...?extra,
    };
  }

  Future<Map<String, dynamic>> getJson(String path) async =>
      (await get(path)).body;

  /// As [getJson], but also hands back the response headers (see
  /// [ApiResponse]) — for a caller that needs the `ETag` of the exact read it
  /// is about to base a write on (#601).
  Future<ApiResponse> get(String path) async {
    final headers = await _headers();
    final resp = await _send(() => _http.get(_uri(path), headers: headers));
    return _response(resp);
  }

  /// [headers] are merged into the standard set for this one request — the
  /// seam `If-Match` goes through (#601). Optional, so every existing call
  /// site is unchanged.
  Future<Map<String, dynamic>> patchJson(
    String path,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
  }) async => (await patch(path, body, headers: headers)).body;

  /// As [patchJson], but also hands back the response headers (see
  /// [ApiResponse]) — a `PATCH` answers with the row's NEW `ETag`, which the
  /// next write must send, so dropping it would make optimistic concurrency
  /// work exactly once per read (#601).
  Future<ApiResponse> patch(
    String path,
    Map<String, dynamic> body, {
    Map<String, String>? headers,
  }) async {
    final merged = await _headers(headers);
    final resp = await _send(
      () => _http.patch(_uri(path), headers: merged, body: jsonEncode(body)),
    );
    return _response(resp);
  }

  Future<Map<String, dynamic>> postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final headers = await _headers();
    final resp = await _send(
      () => _http.post(_uri(path), headers: headers, body: jsonEncode(body)),
    );
    return _decode(resp);
  }

  /// For endpoints with no request body and a `204 No Content` success
  /// response (e.g. revoking an invitation, #27) — `_decode` already treats
  /// an empty response body as `{}` on a 2xx, so no separate no-content
  /// handling is needed here.
  Future<void> deleteJson(String path) async {
    final headers = await _headers();
    final resp = await _send(() => _http.delete(_uri(path), headers: headers));
    _decode(resp);
  }

  /// Runs [request], rewrapping any failure to actually *reach* the server
  /// (or get a response back) as an [ApiNetworkException] (MEDIUM-5) — a
  /// non-2xx response is not caught here; that's a successful round trip,
  /// handled by [_decode] as an [ApiException] instead.
  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } on Exception catch (e) {
      throw ApiNetworkException(e);
    }
  }

  /// Releases the underlying `http.Client`'s resources (connection pool /
  /// platform HTTP client). Wired to `apiClientProvider`'s `ref.onDispose`
  /// (MEDIUM-3) rather than left to the garbage collector — an unclosed
  /// `http.Client` keeps its connections/isolate resources alive for the
  /// life of the process.
  void close() => _http.close();

  /// [_decode]'s body paired with [resp]'s headers — the same non-2xx →
  /// [ApiException] mapping, since it is [_decode] that throws.
  ApiResponse _response(http.Response resp) =>
      ApiResponse(body: _decode(resp), headers: resp.headers);

  Map<String, dynamic> _decode(http.Response resp) {
    // A non-JSON body (e.g. a gateway's plain-text/HTML 502/503 page rather
    // than the service's own RFC 9457 Problem response) must not crash the
    // caller with a raw FormatException/TypeError — fall back to an empty
    // map so the code/detail defaults below kick in (HIGH-5).
    Map<String, dynamic> decoded;
    try {
      decoded = resp.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(resp.body) as Map<String, dynamic>;
    } on FormatException {
      decoded = <String, dynamic>{};
    } on TypeError {
      // Valid JSON but not an object (e.g. a bare array/string/number).
      decoded = <String, dynamic>{};
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return decoded;
    }
    final errors = (decoded['errors'] as List<dynamic>? ?? [])
        .map((e) => ApiFieldError.fromJson(e as Map<String, dynamic>))
        .toList();
    throw ApiException(
      statusCode: resp.statusCode,
      code: decoded['code'] as String? ?? 'unknown',
      detail: decoded['detail'] as String? ?? 'request failed',
      fieldErrors: errors,
    );
  }
}

/// The shared REST client, so features depend on the provider rather than
/// constructing an [ApiClient] themselves (matches `apiariesRepositoryProvider`/
/// `powerSyncProvider`'s pattern).
///
/// Closes its `http.Client` on disposal (MEDIUM-3) — otherwise the client's
/// connection pool/platform resources leak for the life of the process
/// (e.g. every time this provider is recreated after a logout/`invalidate`).
final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(ref);
  ref.onDispose(client.close);
  return client;
});
