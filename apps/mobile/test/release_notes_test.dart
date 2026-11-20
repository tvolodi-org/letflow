import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('QA release: version 1.0.0+2 and notes in ru, kk and en', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(r'^version: 1\.0\.0\+2$', multiLine: true).hasMatch(pubspec),
      isTrue,
    );
    final lines = File('release-notes-qa.txt').readAsLinesSync();
    for (final k in ['ru', 'kk', 'en']) {
      final line = lines.firstWhere(
        (l) => l.startsWith('$k:'),
        orElse: () => '',
      );
      expect(line.substring(k.length + 1).trim(), isNotEmpty, reason: k);
    }
  });
}
