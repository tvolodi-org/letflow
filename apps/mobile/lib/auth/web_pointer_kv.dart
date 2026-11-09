/// Persistent (browser) store for the single non-secret last-active-tenant
/// pointer (PWA M2, D-112). It refuses every other key at runtime, so it
/// cannot hold credentials even by mistake; a source-scan guard
/// (`test/guards/`, storage boundary) keeps this file
/// free of anything credential-related.
library;

import 'kv_store.dart';

/// The one key this store accepts.
const String kWebPointerKey = 'letflow.last_active_tenant';

class WebPointerKv implements KvStore {
  WebPointerKv(this._storage);

  final StringStorage _storage;

  String _check(String key) {
    if (key != kWebPointerKey) {
      throw ArgumentError.value(
        key,
        'key',
        'only the tenant pointer is allowed',
      );
    }
    return key;
  }

  @override
  Future<String?> read(String key) async => _storage.getItem(_check(key));

  @override
  Future<void> write(String key, String value) async {
    _storage.setItem(_check(key), value);
  }

  @override
  Future<void> delete(String key) async {
    _storage.removeItem(_check(key));
  }
}
