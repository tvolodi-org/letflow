// REQ-732 criterion 7: every new key exists, non-empty, in en, ru and kk.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('L7a: every codes key is present and non-empty in en/ru/kk', () {
    final catalogues = {
      for (final l in ['en', 'ru', 'kk'])
        l:
            jsonDecode(File('lib/i18n/l10n/app_$l.arb').readAsStringSync())
                as Map<String, dynamic>,
    };
    final keys = catalogues['en']!.keys.where(
      (k) => k.startsWith('codes.') || k == 'home.codes.scan',
    );
    expect(keys.length, greaterThanOrEqualTo(21));
    for (final l in catalogues.keys) {
      for (final k in keys) {
        final v = catalogues[l]![k];
        expect(v is String && v.isNotEmpty, isTrue, reason: '$l:$k');
      }
    }
  });

  test('I1: the PWA M4 camera texts exist in en/ru/kk', () {
    for (final l in ['en', 'ru', 'kk']) {
      final arb =
          jsonDecode(File('lib/i18n/l10n/app_$l.arb').readAsStringSync())
              as Map<String, dynamic>;
      for (final k in [
        'codes.camera.intro',
        'codes.camera.start',
        'codes.camera.refused',
        'codes.camera.unavailable',
      ]) {
        final v = arb[k];
        expect(v is String && v.trim().isNotEmpty, isTrue, reason: '$l:$k');
      }
      expect(arb.containsKey('codes.cameraRefused'), isFalse, reason: l);
    }
  });
}
