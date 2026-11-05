/// The sealed [ApiError] type — every failure `lib/api/` produces, normalized
/// away from raw `DioException`/`SocketException`/status-code inspection
/// (REQ-425 design §1, MOB-6). Every public [ApiClient] method (`api_client.dart`)
/// throws one of these variants, never a raw transport exception.
///
/// `ApiError` is a Dart 3 `sealed class` — every `switch` over it is
/// exhaustiveness-checked by the analyzer, which is the mechanism that keeps
/// every one of MOB-4's six renderer states honest against this type.
library;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

@immutable
sealed class ApiError implements Exception {
  const ApiError();
}

@immutable
class NetworkUnavailableError extends ApiError {
  const NetworkUnavailableError({this.cause});

  /// The underlying `DioException`/`SocketException`, for logging only.
  final Object? cause;

  @override
  String toString() => 'NetworkUnavailableError(cause: $cause)';
}

@immutable
class UnauthorizedError extends ApiError {
  const UnauthorizedError();

  @override
  String toString() => 'UnauthorizedError()';
}

@immutable
class ForbiddenError extends ApiError {
  const ForbiddenError();

  @override
  String toString() => 'ForbiddenError()';
}

@immutable
class NotFoundError extends ApiError {
  const NotFoundError();

  @override
  String toString() => 'NotFoundError()';
}

@immutable
class ModuleNotAvailableError extends ApiError {
  const ModuleNotAvailableError({required this.moduleId});

  /// The `<id>` segment of `/api/v1/modules/<id>/...`.
  final String moduleId;

  @override
  String toString() => 'ModuleNotAvailableError(moduleId: $moduleId)';
}

@immutable
class BackpressureError extends ApiError {
  const BackpressureError({required this.retryAfterSeconds});

  /// Parsed from the `Retry-After` response header.
  final int retryAfterSeconds;

  @override
  String toString() =>
      'BackpressureError(retryAfterSeconds: $retryAfterSeconds)';
}

@immutable
class ApiFieldError {
  const ApiFieldError({
    required this.field,
    required this.constraint,
    required this.message,
    this.received,
  });

  final String field;
  final String constraint;
  final String message;
  final Object? received;

  @override
  String toString() =>
      'ApiFieldError(field: $field, constraint: $constraint, message: $message)';
}

@immutable
class ValidationError extends ApiError {
  const ValidationError({required this.fieldErrors, this.reason});

  /// RFC 9457 "errors" array — see [_parseFieldErrors].
  final List<ApiFieldError> fieldErrors;

  /// The top-level `reason` member some module routes add to the problem
  /// body (stock count refusals); null when absent or not a string.
  final String? reason;

  @override
  String toString() => 'ValidationError(fieldErrors: $fieldErrors)';
}

@immutable
class ConflictError extends ApiError {
  const ConflictError({this.reason});

  /// Same top-level `reason` member as [ValidationError.reason].
  final String? reason;

  @override
  String toString() => 'ConflictError()';
}

@immutable
class ServerError extends ApiError {
  const ServerError({this.lastStatusCode});

  /// The final 5xx (or other unclassified) status after retries were
  /// exhausted, when known.
  final int? lastStatusCode;

  @override
  String toString() => 'ServerError(lastStatusCode: $lastStatusCode)';
}

/// Matches a module-scoped API path — `docs/mobile/architecture.md` §6's
/// `/api/v1/modules/<id>/…` base path. A bare `/api/v1/modules/<id>` with no
/// trailing segment does NOT match (every real module route has at least one
/// path segment after the id).
final RegExp _modulePathPattern = RegExp(r'^/api/v1/modules/([^/]+)/');

bool _isModulePath(String path) => _modulePathPattern.hasMatch(path);

/// Only called when [_isModulePath] is already `true`.
String _extractModuleId(String path) {
  return _modulePathPattern.firstMatch(path)!.group(1)!;
}

/// Parses the raw `Retry-After` header value (design §1.4). The backend only
/// ever emits the delta-seconds form (a plain decimal integer string), never
/// an HTTP-date — so this implements only that branch of RFC 7231 §7.1.3.
/// Defaults to `1` (matching `Letflow.Admission`'s own documented default) on
/// any parse failure (absent, non-numeric, or negative).
int _parseRetryAfter(String? headerValue) {
  final parsed = int.tryParse(headerValue ?? '');
  if (parsed == null || parsed < 0) return 1;
  return parsed;
}

/// Parses a 422 RFC 9457 problem-details body's `"errors"` array
/// (`Letflow.Api.Validation.FieldError`'s wire shape, design §1.5). Returns
/// an empty list — never throws — on any malformed shape (missing/non-map
/// body, missing/non-list `errors` key, or a non-map element).
List<ApiFieldError> _parseFieldErrors(Object? responseBody) {
  if (responseBody is! Map<String, dynamic>) return [];
  final errors = responseBody['errors'];
  if (errors is! List) return [];
  final result = <ApiFieldError>[];
  for (final element in errors) {
    if (element is! Map<String, dynamic>) continue;
    final field = element['field'];
    final constraint = element['constraint'];
    final message = element['message'];
    if (field is! String || constraint is! String || message is! String) {
      continue;
    }
    result.add(
      ApiFieldError(
        field: field,
        constraint: constraint,
        message: message,
        received: element['received'],
      ),
    );
  }
  return result;
}

String? _parseReason(Object? responseBody) {
  if (responseBody is! Map) return null;
  final reason = responseBody['reason'];
  return reason is String ? reason : null;
}

/// The single status-code/exception → [ApiError] classification function
/// (design §1.2, exact evaluation order — first match wins).
ApiError classifyError(
  RequestOptions requestOptions, {
  int? statusCode,
  Object? transportException,
  String? retryAfterHeader,
  Object? responseBody,
}) {
  if (statusCode == null) {
    return NetworkUnavailableError(cause: transportException);
  }
  if (statusCode == 401) return const UnauthorizedError();
  if (statusCode == 403) return const ForbiddenError();
  if (statusCode == 404) {
    final path = requestOptions.path;
    if (_isModulePath(path)) {
      return ModuleNotAvailableError(moduleId: _extractModuleId(path));
    }
    return const NotFoundError();
  }
  if (statusCode == 429) {
    return BackpressureError(
      retryAfterSeconds: _parseRetryAfter(retryAfterHeader),
    );
  }
  if (statusCode == 422) {
    return ValidationError(
      fieldErrors: _parseFieldErrors(responseBody),
      reason: _parseReason(responseBody),
    );
  }
  if (statusCode == 409) {
    return ConflictError(reason: _parseReason(responseBody));
  }
  if (statusCode >= 500 && statusCode <= 599) {
    return ServerError(lastStatusCode: statusCode);
  }
  // Catch-all (design §1.2 item 10): any other status reaching this function
  // (an unmapped 3xx/4xx not covered above, e.g. a bare 400) folds into
  // ServerError as "something failed and none of our named categories fit" —
  // OQ-1, flagged for REVIEWER; not decided as a separate variant here.
  return ServerError(lastStatusCode: statusCode);
}
