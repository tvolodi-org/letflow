// REQ-747 criteria 1, 6 and 7: the package and platform files, nothing kept
// on the device, and every voice text present in the three languages.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

List<File> _dartFiles(String dir) => Directory(dir)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  test(
    'P2a: manifest, plist, pubspec, lock and README name the microphone',
    () {
      expect(
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
        contains('android.permission.RECORD_AUDIO'),
      );
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(
        RegExp(
          r'<key>NSMicrophoneUsageDescription</key>\s*<string>[^<]+</string>',
        ).hasMatch(plist),
        isTrue,
      );
      expect(File('pubspec.yaml').readAsStringSync(), contains('  record: '));
      expect(File('pubspec.lock').readAsStringSync(), contains('  record:'));
      final readme = File('README.md').readAsStringSync();
      expect(readme, contains('## Voice recording'));
      expect(readme, contains('`record`'));
    },
  );

  test('P2b: package:record is imported only by package_recorder_port', () {
    final hits = _dartFiles('lib')
        .where((f) => f.readAsStringSync().contains("package:record/"))
        .map((f) => f.path.split('/').last)
        .toList();
    expect(hits, ['package_recorder_port.dart']);
  });

  test('S2: voice code stores nothing and only one file touches dart:io', () {
    final files = [
      ..._dartFiles('lib/features/stock/voice'),
      File('lib/features/stock/count_detail_screen.dart'),
      File('lib/features/stock/documents/document_form_screen.dart'),
    ];
    for (final f in files) {
      final name = f.path.split('/').last;
      final text = f.readAsStringSync();
      expect(text, isNot(contains('sembast')), reason: name);
      expect(text, isNot(contains('flutter_secure_storage')), reason: name);
      expect(text, isNot(contains('print(')), reason: name);
      if (name != 'record_voice_source.dart') {
        expect(text, isNot(contains('dart:io')), reason: name);
        expect(text, isNot(contains('File(')), reason: name);
      }
    }
  });

  test('L1: every stock.voice text the code uses exists in en, ru and kk', () {
    final used = <String>{};
    final pattern = RegExp(r"'(stock\.voice\.[A-Za-z.]+)'");
    for (final f in [..._dartFiles('lib/features/stock')]) {
      for (final m in pattern.allMatches(f.readAsStringSync())) {
        used.add(m.group(1)!);
      }
    }
    expect(used, isNotEmpty);
    for (final loc in ['en', 'ru', 'kk']) {
      final arb =
          json.decode(File('lib/i18n/l10n/app_$loc.arb').readAsStringSync())
              as Map<String, dynamic>;
      for (final key in used) {
        expect(arb[key], isA<String>(), reason: '$loc $key');
        expect((arb[key] as String).trim(), isNotEmpty, reason: '$loc $key');
      }
    }
  });
}
