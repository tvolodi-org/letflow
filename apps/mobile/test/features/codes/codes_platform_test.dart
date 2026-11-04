// REQ-732 criteria 2 and 6: one new package, documented; permissions
// declared; nothing written to the device.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('C2a: pubspec gains mobile_scanner as the only new runtime package', () {
    final lines = File('pubspec.yaml').readAsLinesSync();
    final start = lines.indexOf('dependencies:');
    final end = lines.indexOf('dev_dependencies:');
    final deps = lines
        .sublist(start + 1, end)
        .where((l) => RegExp(r'^  [a-z_]+:').hasMatch(l))
        .map((l) => l.trim().split(':').first)
        .toList();
    expect(deps, [
      'dio',
      'flutter',
      'flutter_appauth',
      'flutter_riverpod',
      'flutter_secure_storage',
      'go_router',
      'intl',
      'mobile_scanner',
      'path',
      'path_provider',
      'sembast',
    ]);
  });

  test('C2b: README names the package and the reason', () {
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('## Camera scanning'));
    expect(readme, contains('mobile_scanner'));
    expect(readme, contains('reads both barcodes and'));
  });

  test('C2c: Android manifest declares the camera permission', () {
    final xml = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    expect(xml, contains('android.permission.CAMERA'));
  });

  test('C2d: Info.plist carries NSCameraUsageDescription', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, contains('NSCameraUsageDescription'));
  });

  test('S6a: the codes module stores nothing on the device', () {
    final files = Directory(
      'lib/features/codes',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    for (final f in files) {
      final src = f.readAsStringSync();
      for (final banned in [
        'sembast',
        'flutter_secure_storage',
        'dart:io',
        'File(',
      ]) {
        expect(src.contains(banned), isFalse, reason: '${f.path}: $banned');
      }
    }
  });
}
