import 'package:sembast_web/sembast_web.dart';

/// The IndexedDB-backed sembast factory (web / PWA).
Future<DatabaseFactory> productionDatabaseFactory() async => databaseFactoryWeb;

/// On web the "path" is the IndexedDB database name: the bare [fileName].
Future<String> productionDbPath(String fileName) async => fileName;
