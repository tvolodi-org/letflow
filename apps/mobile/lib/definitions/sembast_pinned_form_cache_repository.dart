/// The real, persistent [PinnedFormCacheRepository] implementation (design
/// §4.2) — `package:sembast`, the same store choice REQ-423 already made
/// (`apps/mobile/README.md`), reused here with **no new `pubspec.yaml`
/// dependency**. A second, independent `.db` file per tenant, not a second
/// store inside REQ-423's existing per-tenant Sembast file — see design §4.2
/// "Why a separate `.db` file" for the full reasoning.
library;

import 'package:sembast/sembast.dart';

import 'pinned_form_cache.dart';
import 'sembast_platform.dart';

class SembastPinnedFormCacheRepository implements PinnedFormCacheRepository {
  SembastPinnedFormCacheRepository._(this._db);

  final Database _db;

  static final StoreRef<String, Map<String, dynamic>> _entriesStore =
      stringMapStoreFactory.store('pinned_forms');

  /// Opens (creating if absent) the on-disk store at [path] using [factory]
  /// — production: `databaseFactoryIo` from `package:sembast/sembast_io.dart`;
  /// the storage-level test: `databaseFactoryIo` pointed at a `dart:io
  /// Directory.systemTemp` temp dir, no platform channel involved.
  static Future<SembastPinnedFormCacheRepository> open(
    String path, {
    required DatabaseFactory factory,
  }) async {
    final db = await factory.openDatabase(path);
    return SembastPinnedFormCacheRepository._(db);
  }

  @override
  Future<PinnedFormCacheEntry?> getByKey(
    String formId,
    String formVersion,
  ) async {
    final value = await _entriesStore.record('$formId::$formVersion').get(_db);
    if (value == null) return null;
    return PinnedFormCacheEntry.fromStoredJson(value);
  }

  @override
  Future<void> putEntry(PinnedFormCacheEntry entry) async {
    await _entriesStore
        .record(entry.compositeKey)
        .put(_db, entry.toStoredJson());
  }

  @override
  Future<void> close() async {
    await _db.close();
  }
}

/// The production [PinnedFormCacheOpener] — the one production code path
/// this requirement adds that touches a real platform channel
/// (`path_provider`'s `getApplicationSupportDirectory()`). Not exercised by
/// any test in this requirement's own acceptance criteria; the storage-level
/// test (`test/definitions/sembast_pinned_form_cache_repository_test.dart`)
/// bypasses it entirely via a `dart:io` temp directory, mirroring
/// `openProductionDefinitionCache`'s own precedent.
Future<PinnedFormCacheRepository> openProductionPinnedFormCache(
  String realmUrl,
) async {
  final path = await productionDbPath(pinnedFormCacheFileNameFor(realmUrl));
  final dbFactory = await productionDatabaseFactory();
  return SembastPinnedFormCacheRepository.open(path, factory: dbFactory);
}
