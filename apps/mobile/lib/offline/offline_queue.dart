/// A small offline queue of NEW stock-document drafts (PWA M3, D-112).
///
/// Only "create a draft" is queued: it is the one call that is safe to defer
/// (nothing is posted; the phone never posts). The queue is persisted in the
/// sembast store (IndexedDB on web), so it survives a reload, and it has hard
/// size limits so it cannot fill the browser's storage.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sembast/sembast.dart';

import '../definitions/pinned_form_cache.dart' show pinnedFormCacheFileNameFor;
import '../definitions/sembast_platform.dart';

const int kMaxQueuedDrafts = 20;
const int kMaxQueuedBytes = 256 * 1024;
const int kMaxQueuedEntryBytes = 64 * 1024;

enum EnqueueResult { stored, full, tooLarge }

class QueuedDraft {
  const QueuedDraft({
    required this.localId,
    required this.body,
    required this.label,
    required this.createdAtMs,
    this.rejection,
    this.rejectionDetail,
    this.summary = '',
  });

  final String localId;

  /// The `DocDraft.toBody()` output: no token, no tenant id.
  final Map<String, dynamic> body;
  final String label;
  final int createdAtMs;

  /// Set when the server refused the entry; it is then kept for the user.
  final String? rejection;

  /// The server's refusal (reason, field, line_no, side), each optional.
  final Map<String, dynamic>? rejectionDetail;

  /// Short text of the draft's lines, set at enqueue.
  final String summary;

  Map<String, dynamic> toJson() => {
    'local_id': localId,
    'body': body,
    'label': label,
    'created_at_ms': createdAtMs,
    'rejection': ?rejection,
    'rejection_detail': ?rejectionDetail,
    if (summary.isNotEmpty) 'summary': summary,
  };

  static QueuedDraft fromJson(Map<String, dynamic> json) => QueuedDraft(
    localId: json['local_id'] as String,
    body: Map<String, dynamic>.from(json['body'] as Map),
    label: json['label'] as String? ?? '',
    createdAtMs: json['created_at_ms'] as int? ?? 0,
    rejection: json['rejection'] as String?,
    rejectionDetail: json['rejection_detail'] is Map
        ? Map<String, dynamic>.from(json['rejection_detail'] as Map)
        : null,
    summary: json['summary'] as String? ?? '',
  );
}

abstract class OfflineDraftQueue {
  Future<EnqueueResult> enqueue(
    Map<String, dynamic> body, {
    String label = '',
    String summary = '',
  });

  /// Oldest first.
  Future<List<QueuedDraft>> all();
  Future<int> count();
  Future<void> remove(String localId);
  Future<void> markRejected(
    String localId,
    String code, {
    Map<String, dynamic>? detail,
  });

  /// Makes a refused entry sendable again (the person chose "Send again").
  Future<void> clearRejection(String localId);

  /// Deletes every entry and releases the handle (logout, tenant switch).
  Future<void> closeAndClear();
}

int _size(Map<String, dynamic> body) => jsonEncode(body).length;

/// File / IndexedDB name for the queue of one tenant realm.
String offlineQueueFileNameFor(String realmUrl) => pinnedFormCacheFileNameFor(
  realmUrl,
).replaceFirst('pinned_form_cache_', 'letflow_offline_');

class SembastOfflineDraftQueue implements OfflineDraftQueue {
  SembastOfflineDraftQueue._(this._db);

  final Database _db;
  int _seq = 0;

  static final StoreRef<String, Map<String, dynamic>> _store =
      stringMapStoreFactory.store('offline_drafts');

  static Future<SembastOfflineDraftQueue> open(
    String path, {
    required DatabaseFactory factory,
  }) async => SembastOfflineDraftQueue._(await factory.openDatabase(path));

  @override
  Future<EnqueueResult> enqueue(
    Map<String, dynamic> body, {
    String label = '',
    String summary = '',
  }) async {
    final size = _size(body);
    if (size > kMaxQueuedEntryBytes) return EnqueueResult.tooLarge;
    try {
      final existing = await all();
      if (existing.length >= kMaxQueuedDrafts) return EnqueueResult.full;
      final total = existing.fold<int>(0, (sum, e) => sum + _size(e.body));
      if (total + size > kMaxQueuedBytes) return EnqueueResult.full;
      final now = DateTime.now().millisecondsSinceEpoch;
      final id = '$now-${_seq++}';
      await _store
          .record(id)
          .put(
            _db,
            QueuedDraft(
              localId: id,
              body: body,
              label: label,
              summary: summary,
              createdAtMs: now,
            ).toJson(),
          );
      return EnqueueResult.stored;
    } on Object {
      // Quota / private mode / closed db: the draft is not stored.
      return EnqueueResult.full;
    }
  }

  @override
  Future<List<QueuedDraft>> all() async {
    final rows = await _store.find(_db);
    final list = [for (final r in rows) QueuedDraft.fromJson(r.value)]
      ..sort((a, b) {
        final byTime = a.createdAtMs.compareTo(b.createdAtMs);
        return byTime != 0 ? byTime : a.localId.compareTo(b.localId);
      });
    return list;
  }

  @override
  Future<int> count() => _store.count(_db);

  @override
  Future<void> remove(String localId) async {
    await _store.record(localId).delete(_db);
  }

  @override
  Future<void> markRejected(
    String localId,
    String code, {
    Map<String, dynamic>? detail,
  }) async {
    await _store.record(localId).update(_db, {
      'rejection': code,
      'rejection_detail': ?detail,
    });
  }

  @override
  Future<void> clearRejection(String localId) async {
    await _store.record(localId).update(_db, {
      'rejection': null,
      'rejection_detail': null,
    });
  }

  /// Closes the handle and keeps the data (a reload, in tests).
  @visibleForTesting
  Future<void> closeOnly() => _db.close();

  @override
  Future<void> closeAndClear() async {
    try {
      await _store.delete(_db);
    } finally {
      await _db.close();
    }
  }
}

/// The queue of the active tenant, opened on first use. [realmUrl] is read at
/// call time; with no active realm the queue is empty and writes are refused.
class ActiveOfflineQueue implements OfflineDraftQueue {
  ActiveOfflineQueue({
    required String? Function() realmUrl,
    Future<OfflineDraftQueue> Function(String realmUrl)? opener,
  }) : _realmUrl = realmUrl,
       _opener = opener ?? openProductionOfflineQueue;

  final String? Function() _realmUrl;
  final Future<OfflineDraftQueue> Function(String realmUrl) _opener;
  OfflineDraftQueue? _current;
  String? _currentRealm;

  Future<OfflineDraftQueue?> _queue() async {
    final realm = _realmUrl();
    if (realm == null) return null;
    if (_current != null && _currentRealm != realm) {
      await _current!.closeAndClear();
      _current = null;
    }
    if (_current == null) {
      _current = await _opener(realm);
      _currentRealm = realm;
    }
    return _current;
  }

  @override
  Future<EnqueueResult> enqueue(
    Map<String, dynamic> body, {
    String label = '',
    String summary = '',
  }) async {
    final q = await _queue();
    return q == null
        ? EnqueueResult.full
        : q.enqueue(body, label: label, summary: summary);
  }

  @override
  Future<List<QueuedDraft>> all() async => (await _queue())?.all() ?? const [];

  @override
  Future<int> count() async => (await _queue())?.count() ?? 0;

  @override
  Future<void> remove(String localId) async =>
      (await _queue())?.remove(localId);

  @override
  Future<void> markRejected(
    String localId,
    String code, {
    Map<String, dynamic>? detail,
  }) async => (await _queue())?.markRejected(localId, code, detail: detail);

  @override
  Future<void> clearRejection(String localId) async =>
      (await _queue())?.clearRejection(localId);

  @override
  Future<void> closeAndClear() async {
    // Clear the queue of the realm that is still active (or already open).
    final q = _current ?? await _queue();
    _current = null;
    _currentRealm = null;
    await q?.closeAndClear();
  }
}

Future<OfflineDraftQueue> openProductionOfflineQueue(String realmUrl) async {
  final path = await productionDbPath(offlineQueueFileNameFor(realmUrl));
  return SembastOfflineDraftQueue.open(
    path,
    factory: await productionDatabaseFactory(),
  );
}
