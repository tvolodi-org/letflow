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
  const ValidationError({
    required this.fieldErrors,
    this.reason,
    this.field,
    this.lineNo,
    this.side,
  });

  /// RFC 9457 "errors" array — see [_parseFieldErrors].
  final List<ApiFieldError> fieldErrors;

  /// Top-level refusal extension keys (`reason`, `field`, `line_no`, `side`)
  /// of the stock routes; null when absent or of the wrong type.
  final String? reason;
  final String? field;
  final int? lineNo;
  final String? side;

  @override
  String toString() => 'ValidationError(fieldErrors: $fieldErrors)';
}

@immutable
class ConflictError extends ApiError {
  const ConflictError({this.reason, this.field, this.lineNo, this.side});

  /// See [ValidationError.reason].
  final String? reason;
  final String? field;
  final int? lineNo;
  final String? side;

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

class _RefusalExtensions {
  _RefusalExtensions({this.reason, this.field, this.lineNo, this.side});

  final String? reason;
  final String? field;
  final int? lineNo;
  final String? side;

  /// Only values of the right type are kept; anything else is null.
  factory _RefusalExtensions.of(Object? body) {
    if (body is! Map) return _RefusalExtensions();
    final reason = body['reason'];
    final field = body['field'];
    final lineNo = body['line_no'];
    final side = body['side'];
    return _RefusalExtensions(
      reason: reason is String ? reason : null,
      field: field is String ? field : null,
      lineNo: lineNo is int ? lineNo : null,
      side: side is String ? side : null,
    );
  }
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
    final ext = _RefusalExtensions.of(responseBody);
    return ValidationError(
      fieldErrors: _parseFieldErrors(responseBody),
      reason: ext.reason,
      field: ext.field,
      lineNo: ext.lineNo,
      side: ext.side,
    );
  }
  if (statusCode == 409) {
    final ext = _RefusalExtensions.of(responseBody);
    return ConflictError(
      reason: ext.reason,
      field: ext.field,
      lineNo: ext.lineNo,
      side: ext.side,
    );
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
