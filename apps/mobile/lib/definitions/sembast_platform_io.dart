import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';

/// The file-backed sembast factory (Android / iOS / VM).
Future<DatabaseFactory> productionDatabaseFactory() async => databaseFactoryIo;

/// Full path of [fileName] in the application-support directory.
Future<String> productionDbPath(String fileName) async {
  final dir = await getApplicationSupportDirectory();
  return p.join(dir.path, fileName);
}
