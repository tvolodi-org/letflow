// I1 (T-1346): every stock.doc key exists, non-empty, in en/ru/kk, with the
// same placeholders; every key the code names is present.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/features/stock/documents/document_kinds.dart';
import 'package:letflow/features/stock/documents/document_refusals.dart';

void main() {
  test('I1: stock.doc keys are complete in en/ru/kk', () {
    final cat = {
      for (final l in ['en', 'ru', 'kk'])
        l:
            jsonDecode(File('lib/i18n/l10n/app_$l.arb').readAsStringSync())
                as Map<String, dynamic>,
    };
    final keys = cat['en']!.keys
        .where((k) => k.startsWith('stock.doc.'))
        .toSet();
    final needed = <String>{
      for (final k in DocKind.values) 'stock.doc.kind.${k.wire}',
      for (final r in kRefusalReasons) 'stock.doc.error.$r',
      for (final f in kFieldKeys) 'stock.doc.field.$f',
      for (final r in kWriteOffReasons) 'stock.doc.reason.$r',
      'stock.doc.side.from',
      'stock.doc.side.to',
      'stock.doc.error.notFound',
      'stock.doc.error.generic',
      'stock.doc.error.line',
      'stock.doc.scan.wrongKind',
      'stock.home.documents',
    };
    expect(
      keys.containsAll(needed.where((k) => k.startsWith('stock.doc.'))),
      isTrue,
      reason: '${needed.difference(keys)}',
    );
    final placeholder = RegExp(r'\{\w+\}');
    for (final l in cat.keys) {
      for (final k in [...keys, 'stock.home.documents']) {
        final v = cat[l]![k];
        expect(v is String && v.isNotEmpty, isTrue, reason: '$l:$k');
        expect(
          placeholder.allMatches(v as String).map((m) => m.group(0)).toSet(),
          placeholder
              .allMatches(cat['en']![k] as String)
              .map((m) => m.group(0))
              .toSet(),
          reason: '$l:$k placeholders',
        );
      }
    }
  });
}
