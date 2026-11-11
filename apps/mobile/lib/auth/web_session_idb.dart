/// IndexedDB [SessionRecordStore] (REQ-810). Browser only. Its own database
/// (`letflow_session`), not the sembast stores, so clearing the definition
/// cache or the offline queue can never touch it. The value is the record's
/// JSON string, which holds ciphertext only.
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'session_record.dart';

const String _dbName = 'letflow_session';
const String _storeName = 'record';
const String _recordKey = 'session';

class WebSessionRecordStore implements SessionRecordStore {
  WebSessionRecordStore();

  Future<web.IDBDatabase> _open() {
    final done = Completer<web.IDBDatabase>();
    final req = web.window.indexedDB.open(_dbName, 1);
    req.onupgradeneeded = ((web.Event _) {
      (req.result! as web.IDBDatabase).createObjectStore(_storeName);
    }).toJS;
    req.onsuccess = ((web.Event _) {
      done.complete(req.result! as web.IDBDatabase);
    }).toJS;
    req.onerror = ((web.Event _) {
      done.completeError(StateError('session store unavailable'));
    }).toJS;
    return done.future;
  }

  Future<JSAny?> _run(
    String mode,
    web.IDBRequest Function(web.IDBObjectStore) op,
  ) async {
    final db = await _open();
    try {
      final tx = db.transaction(_storeName.toJS, mode);
      final done = Completer<JSAny?>();
      final req = op(tx.objectStore(_storeName));
      req.onsuccess = ((web.Event _) => done.complete(req.result)).toJS;
      req.onerror = ((web.Event _) {
        done.completeError(StateError('session store failed'));
      }).toJS;
      return await done.future;
    } finally {
      db.close();
    }
  }

  @override
  Future<String?> read() async {
    final v = await _run('readonly', (s) => s.get(_recordKey.toJS));
    return v.isA<JSString>() ? (v! as JSString).toDart : null;
  }

  @override
  Future<void> write(String json) async {
    await _run('readwrite', (s) => s.put(json.toJS, _recordKey.toJS));
  }

  /// Deletes the whole database: needs no open connection, creates nothing,
  /// and is safe to call when the feature was never used.
  @override
  Future<void> delete() {
    final done = Completer<void>();
    final req = web.window.indexedDB.deleteDatabase(_dbName);
    req.onsuccess = ((web.Event _) => done.complete()).toJS;
    req.onerror = ((web.Event _) {
      done.completeError(StateError('session store not deleted'));
    }).toJS;
    req.onblocked = ((web.Event _) => done.complete()).toJS;
    return done.future;
  }
}
