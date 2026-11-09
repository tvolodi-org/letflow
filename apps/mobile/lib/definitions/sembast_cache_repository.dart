/// The real, persistent [DefinitionCacheRepository] implementation
/// (design §5.2) — `package:sembast`, chosen over Isar per
/// `apps/mobile/README.md`'s "Local definition cache" section. Pure Dart:
/// no generated code (`build_runner`), no per-platform native binary
/// fetched at build time.
library;

import 'package:sembast/sembast.dart';

import 'definitions.dart';
import 'sembast_platform.dart';

class SembastDefinitionCacheRepository implements DefinitionCacheRepository {
  SembastDefinitionCacheRepository._(this._db);

  final Database _db;

  static final StoreRef<String, Map<String, dynamic>> _entriesStore =
      stringMapStoreFactory.store('definitions');
  static final StoreRef<String, dynamic> _metaStore =
      StoreRef<String, dynamic>.main();
  static const String _cursorKey = 'cursor';

  /// Opens (creating if absent) the on-disk store at [path] using
  /// [factory] — production: `databaseFactoryIo` from
  /// `package:sembast/sembast_io.dart`; the storage-level test:
  /// `databaseFactoryIo` pointed at a `dart:io Directory.systemTemp` temp
  /// dir, no platform channel involved.
  static Future<SembastDefinitionCacheRepository> open(
    String path, {
    required DatabaseFactory factory,
  }) async {
    final db = await factory.openDatabase(path);
    return SembastDefinitionCacheRepository._(db);
  }

  @override
  Future<void> putAll(Iterable<DefinitionCacheEntry> entries) async {
    await _db.transaction((txn) async {
      for (final entry in entries) {
        await _entriesStore
            .record(entry.compositeKey)
            .put(txn, entry.toStoredJson());
      }
    });
  }

  @override
  Future<void> removeByKey(String type, String id, int version) async {
    await _entriesStore.record('$type::$id::$version').delete(_db);
  }

  @override
  Future<List<DefinitionCacheEntry>> listAvailable() async {
    final records = await _entriesStore.find(_db);
    return records
        .map((r) => DefinitionCacheEntry.fromStoredJson(r.value))
        .toList();
  }

  @override
  Future<DefinitionCacheEntry?> getByKey(
    String type,
    String id,
    int version,
  ) async {
    final value = await _entriesStore.record('$type::$id::$version').get(_db);
    if (value == null) return null;
    return DefinitionCacheEntry.fromStoredJson(value);
  }

  @override
  Future<int?> readCursor() async {
    final value = await _metaStore.record(_cursorKey).get(_db);
    return value is int ? value : null;
  }

  @override
  Future<void> writeCursor(int cursor) async {
    await _metaStore.record(_cursorKey).put(_db, cursor);
  }

  @override
  Future<void> resetCursor() async {
    await _metaStore.record(_cursorKey).delete(_db);
  }

  @override
  Future<void> close() async {
    await _db.close();
  }
}

/// The production [DefinitionCacheOpener] (design §5.2 "Storage location
/// (production)") — the one production code path this requirement adds
/// that touches a real platform channel (`path_provider`'s
/// `getApplicationSupportDirectory()`). Not exercised by any test in this
/// requirement's own acceptance criteria; the storage-level test
/// (`test/definitions/sembast_cache_repository_test.dart`) bypasses it
/// entirely via a `dart:io` temp directory, mirroring
/// `TenantTokenStore.production()`'s own hardened-but-untested-in-`flutter
/// test` precedent.
Future<DefinitionCacheRepository> openProductionDefinitionCache(
  String realmUrl,
) async {
  final path = await productionDbPath(cacheFileNameFor(realmUrl));
  final dbFactory = await productionDatabaseFactory();
  return SembastDefinitionCacheRepository.open(path, factory: dbFactory);
}
