/// Remembers that the "add to home screen" hint was shown and dismissed
/// (PWA M3 follow-up). Own database file, NOT the queue file: the queue is
/// cleared on logout and the hint must not come back after every login.
library;

import 'package:sembast/sembast.dart';

import '../definitions/sembast_platform.dart';

abstract class InstallHintStore {
  Future<bool> seen();
  Future<void> markSeen();
}

class MemoryInstallHintStore implements InstallHintStore {
  bool _seen = false;

  @override
  Future<bool> seen() async => _seen;

  @override
  Future<void> markSeen() async => _seen = true;
}

class SembastInstallHintStore implements InstallHintStore {
  SembastInstallHintStore(this._open);

  final Future<Database> Function() _open;
  static final RecordRef<String, bool> _ref = StoreRef<String, bool>(
    'install_hint',
  ).record('seen');

  /// Any store failure (private mode) counts as "seen": never nag.
  @override
  Future<bool> seen() async {
    try {
      final db = await _open();
      try {
        return await _ref.get(db) ?? false;
      } finally {
        await db.close();
      }
    } on Object {
      return true;
    }
  }

  @override
  Future<void> markSeen() async {
    try {
      final db = await _open();
      try {
        await _ref.put(db, true);
      } finally {
        await db.close();
      }
    } on Object {
      // Not stored: the hint may show again; nothing else breaks.
    }
  }
}

InstallHintStore productionInstallHintStore() =>
    SembastInstallHintStore(() async {
      final path = await productionDbPath('letflow_install_hint');
      return (await productionDatabaseFactory()).openDatabase(path);
    });
