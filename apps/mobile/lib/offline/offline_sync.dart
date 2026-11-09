/// Sends the queued drafts when the app opens or the user taps "Send now"
/// (PWA M3, D-112). No background sync (not on iOS), no retry loop: one pass,
/// oldest first, one request at a time.
library;

import '../api/api_error.dart';
import 'offline_queue.dart';

class SyncReport {
  const SyncReport({this.sent = 0, this.rejected = 0, this.remaining = 0});

  final int sent;
  final int rejected;
  final int remaining;
}

class OfflineSyncService {
  OfflineSyncService(this.queue, this.send);

  final OfflineDraftQueue queue;

  /// Creates one draft on the server from a queued body.
  final Future<void> Function(Map<String, dynamic> body) send;
  Future<SyncReport>? _running;

  /// A second call while a pass runs returns that pass (nothing is sent twice).
  Future<SyncReport> drain() =>
      _running ??= _drain().whenComplete(() => _running = null);

  Future<SyncReport> _drain() async {
    var sent = 0;
    var rejected = 0;
    try {
      for (final entry in await queue.all()) {
        if (entry.rejection != null) continue;
        try {
          await send(entry.body);
          await queue.remove(entry.localId);
          sent++;
        } on NetworkUnavailableError {
          break;
        } on UnauthorizedError {
          break;
        } on BackpressureError {
          break;
        } on ServerError {
          break;
        } on ApiError catch (error) {
          // The server refused this draft: keep it for the user to see.
          await queue.markRejected(
            entry.localId,
            _codeOf(error),
            detail: _detailOf(error),
          );
          rejected++;
        }
      }
      return SyncReport(
        sent: sent,
        rejected: rejected,
        remaining: await queue.count(),
      );
    } on Object {
      // A closed queue or a failing store never crashes the shell.
      return SyncReport(sent: sent, rejected: rejected);
    }
  }
}

/// Stable short word for a refusal (never `runtimeType`: minified on web).
String _codeOf(ApiError error) => switch (error) {
  ValidationError() => 'validation',
  ConflictError() => 'conflict',
  ForbiddenError() => 'forbidden',
  NotFoundError() => 'not_found',
  ModuleNotAvailableError() => 'module_not_available',
  _ => 'refused',
};

/// The parts of a refusal worth keeping; only plain strings and a line number.
Map<String, dynamic>? _detailOf(ApiError error) => switch (error) {
  ValidationError(:final reason, :final field, :final lineNo, :final side) ||
  ConflictError(
    :final reason,
    :final field,
    :final lineNo,
    :final side,
  ) => {'reason': ?reason, 'field': ?field, 'line_no': ?lineNo, 'side': ?side},
  _ => null,
};
