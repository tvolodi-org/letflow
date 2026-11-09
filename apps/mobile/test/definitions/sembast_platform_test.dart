// PWA M1: on the VM the conditional import selects the io branch. The web
// branch (sembast_web) is covered by `flutter build web --release` only.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/definitions/sembast_platform.dart';
import 'package:sembast/sembast_io.dart';

void main() {
  test('io branch returns databaseFactoryIo', () async {
    expect(await productionDatabaseFactory(), same(databaseFactoryIo));
  });
}
