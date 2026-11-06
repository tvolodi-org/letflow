// ARB catalogue completeness check (T-1460): every key present in app_en.arb
// must exist in app_ru.arb and app_kk.arb and must not be an empty string.
// A missing or empty key fails the test and names the ARB file and key.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, Map<String, dynamic>> catalogues;

  setUpAll(() {
    catalogues = {
      for (final l in ['en', 'ru', 'kk'])
        l:
            jsonDecode(File('lib/i18n/l10n/app_$l.arb').readAsStringSync())
                as Map<String, dynamic>,
    };
  });

  test('AC1: every en key is present and non-empty in ru and kk', () {
    final enKeys = catalogues['en']!.keys
        .where((k) => !k.startsWith('@'))
        .toList();
    expect(enKeys, isNotEmpty);

    for (final locale in ['ru', 'kk']) {
      final cat = catalogues[locale]!;
      for (final key in enKeys) {
        expect(
          cat.containsKey(key),
          isTrue,
          reason: 'app_$locale.arb: missing key "$key"',
        );
        final value = cat[key];
        expect(
          value is String && value.isNotEmpty,
          isTrue,
          reason: 'app_$locale.arb: empty value for key "$key"',
        );
      }
    }
  });
}
