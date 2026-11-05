// D3s: every stock key exists, non-empty, in en, ru and kk.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('S2a: stock keys are present and non-empty in en/ru/kk', () {
    final catalogues = {
      for (final l in ['en', 'ru', 'kk'])
        l:
            jsonDecode(File('lib/i18n/l10n/app_$l.arb').readAsStringSync())
                as Map<String, dynamic>,
    };
    bool isStock(String k) =>
        k.startsWith('stock.') || k.startsWith('home.stock.');
    final keys = catalogues['en']!.keys.where(isStock).toSet();
    expect(keys.length, greaterThanOrEqualTo(3));
    for (final l in catalogues.keys) {
      expect(catalogues[l]!.keys.where(isStock).toSet(), keys, reason: l);
      for (final k in keys) {
        final v = catalogues[l]![k];
        expect(v is String && v.isNotEmpty, isTrue, reason: '$l:$k');
      }
    }
  });
}
