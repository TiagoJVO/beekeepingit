import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../auth/auth_controller.dart';
import '../config/app_config.dart';

/// Field-level detail on a 422 (RFC 9457 `Problem.errors[]`).
class ApiFieldError {
  const ApiFieldError({required this.field, required this.code, required this.message});

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
  final String detail;
  final List<ApiFieldError> fieldErrors;

  @override
  String toString() => 'ApiException($statusCode, $code, $detail)';
}

/// Generic, profile-agnostic REST client wrapping `package:http`: injects the
/// bearer token from the auth feature's public surface, encodes/decodes JSON,
/// and maps non-2xx responses to [ApiException]. Feature repositories (e.g.
/// `features/profile`) build on this rather than talking to `http` directly.
class ApiClient {
  ApiClient(this._ref, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  final Ref _ref;
  final http.Client _http;

  Uri _uri(String path) => Uri.parse('${AppConfig.gatewayBaseUrl}/v1$path');

  Future<Map<String, String>> _headers() async {
    final token = await _ref.read(authControllerProvider.notifier).accessToken();
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> getJson(String path) async {
    final resp = await _http.get(_uri(path), headers: await _headers());
    return _decode(resp);
  }

  Future<Map<String, dynamic>> patchJson(String path, Map<String, dynamic> body) async {
    final resp = await _http.patch(
      _uri(path),
      headers: await _headers(),
      body: jsonEncode(body),
    );
    return _decode(resp);
  }

  Future<Map<String, dynamic>> postJson(String path, Map<String, dynamic> body) async {
    final resp = await _http.post(
      _uri(path),
      headers: await _headers(),
      body: jsonEncode(body),
    );
    return _decode(resp);
  }

  /// For endpoints with no request body and a `204 No Content` success
  /// response (e.g. revoking an invitation, #27) — `_decode` already treats
  /// an empty response body as `{}` on a 2xx, so no separate no-content
  /// handling is needed here.
  Future<void> deleteJson(String path) async {
    final resp = await _http.delete(_uri(path), headers: await _headers());
    _decode(resp);
  }

  Map<String, dynamic> _decode(http.Response resp) {
    final isJson = resp.body.isNotEmpty;
    final decoded = isJson ? jsonDecode(resp.body) as Map<String, dynamic> : <String, dynamic>{};
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
final apiClientProvider = Provider<ApiClient>((ref) => ApiClient(ref));
