// T-1346 (REQ-746): kind table pinned to kinds.ex, exact bodies per kind,
// save checks, decimal text.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/features/stock/documents/document_draft.dart';
import 'package:letflow/features/stock/documents/document_kinds.dart';

Set<String> _words(String literal) =>
    literal.trim().split(RegExp(r'\s+')).toSet();

void main() {
  test('T-K1: header and required key sets equal kinds.ex', () {
    final src = File(
      '../../lib/letflow/modules/stock/documents/kinds.ex',
    ).readAsStringSync();
    Set<String> attr(String name) {
      final m = RegExp('@$name ~w\\(([^)]*)\\)').firstMatch(src);
      expect(m, isNotNull, reason: name);
      return _words(m!.group(1)!);
    }

    final receipt = attr('receipt_keys');
    final issue = attr('issue_keys');
    final twoCommon = attr('two_side_common');
    // @write_off_keys = @issue_keys ++ ["reason_code"]; @transfer_keys =
    // @two_side_common ++ to_*; @return_keys = common ++ from_org_unit_id,
    // to_location_id, to_responsible_id (composition rules read from the file).
    expect(src, contains('@write_off_keys @issue_keys ++ ["reason_code"]'));
    expect(
      src,
      contains(
        r'@transfer_keys @two_side_common ++ ~w(to_org_unit_id to_location_id to_responsible_id)',
      ),
    );
    expect(
      src,
      contains(
        r'@return_keys @two_side_common ++ ~w(from_org_unit_id to_location_id to_responsible_id)',
      ),
    );
    expect(src, contains('required: List.delete(@transfer_keys, "note")'));
    expect(src, contains('required: List.delete(@return_keys, "note")'));
    final transfer = {
      ...twoCommon,
      'to_org_unit_id',
      'to_location_id',
      'to_responsible_id',
    };
    final ret = {
      ...twoCommon,
      'from_org_unit_id',
      'to_location_id',
      'to_responsible_id',
    };
    final expected = {
      DocKind.receipt: receipt,
      DocKind.issue: issue,
      DocKind.writeOff: {...issue, 'reason_code'},
      DocKind.transfer: transfer,
      DocKind.handOver: transfer,
      DocKind.returnDoc: ret,
    };
    for (final e in expected.entries) {
      expect(documentKindSpecs[e.key]!.headerKeys, e.value, reason: '${e.key}');
    }
    Set<String> required(String type) {
      final m = RegExp(
        'kind: "$type".*?required: ~w\\(([^)]*)\\)',
        dotAll: true,
      ).firstMatch(src);
      expect(m, isNotNull, reason: type);
      return _words(m!.group(1)!);
    }

    expect(
      documentKindSpecs[DocKind.receipt]!.requiredKeys,
      required('receipt'),
    );
    expect(documentKindSpecs[DocKind.issue]!.requiredKeys, required('issue'));
    expect(
      documentKindSpecs[DocKind.writeOff]!.requiredKeys,
      required('write_off'),
    );
    for (final k in [DocKind.transfer, DocKind.handOver, DocKind.returnDoc]) {
      final spec = documentKindSpecs[k]!;
      expect(spec.requiredKeys, spec.headerKeys.difference({'note'}));
    }
  });

  const t = '2026-11-05T10:00:00+05:00';
  DocDraft draft(DocKind kind, Map<String, String> header) => DocDraft(
    kind: kind,
    eventTime: t,
    header: header,
    lines: const [DocLine(item: 'i1', uom: 'u1', quantity: '12,5')],
  );

  Map<String, String> ids(Iterable<String> keys) => {
    for (final k in keys) k: 'id-$k',
  };

  test('T-M1: the body of each kind carries exactly its key set', () {
    for (final kind in DocKind.values) {
      final spec = documentKindSpecs[kind]!;
      final header = {
        ...ids(spec.fields.map((f) => f.key)),
        if (kind == DocKind.writeOff) 'reason_code': 'lost',
        if (kind == DocKind.receipt) 'received_on': '2026-11-04',
        'bogus_key': 'x',
      };
      final d = draft(kind, header);
      final body = d.toBody();
      // every optional key is filled above, so the body has the whole set
      expect(body.keys.toSet(), {'kind', 'lines', ...spec.headerKeys});
      expect(body['kind'], kind.wire);
      expect(body.containsKey('bogus_key'), isFalse);
      final line = (body['lines'] as List).single as Map;
      expect(line['quantity'], '12.5');
      expect(line['line_no'], 1);
      expect(line.containsKey('unit_price'), isFalse);
    }
  });

  test('T-M1b: return swaps the org unit keys; price only on receipt', () {
    final d = draft(DocKind.returnDoc, {
      'from_org_unit_id': 'A',
      'org_unit_id': 'B',
    });
    final body = d.toBody();
    expect(body['from_org_unit_id'], 'A');
    expect(body['org_unit_id'], 'B');
    final r = DocDraft(
      kind: DocKind.receipt,
      eventTime: t,
      lines: const [
        DocLine(
          item: 'i',
          uom: 'u',
          quantity: '1',
          unitPrice: '2,50',
          lineValue: '2.5',
        ),
      ],
    ).toBody();
    final line = (r['lines'] as List).single as Map;
    expect(line['unit_price'], '2.50');
    expect(line['line_value'], '2.5');
    final i = DocDraft(
      kind: DocKind.issue,
      eventTime: t,
      lines: const [
        DocLine(item: 'i', uom: 'u', quantity: '1', unitPrice: '9'),
      ],
    ).toBody();
    expect(
      ((i['lines'] as List).single as Map).containsKey('unit_price'),
      isFalse,
    );
  });

  test('T-M2: Save checks per kind', () {
    final one = {'org_unit_id': 'o', 'location_id': 'l', 'responsible_id': 'r'};
    expect(draft(DocKind.receipt, one).isSaveable, isTrue);
    expect(
      draft(DocKind.receipt, {...one}..remove('location_id')).isSaveable,
      isFalse,
    );
    expect(draft(DocKind.writeOff, one).isSaveable, isFalse);
    expect(
      draft(DocKind.writeOff, {...one, 'reason_code': 'lost'}).isSaveable,
      isTrue,
    );
    expect(
      draft(DocKind.writeOff, {...one, 'reason_code': 'other'}).problems(),
      contains('header.reason_text'),
    );
    expect(
      draft(DocKind.receipt, {...one, 'received_on': '4.11.2026'}).isSaveable,
      isFalse,
    );
    final two = {
      'org_unit_id': 'a',
      'from_location_id': 'b',
      'from_responsible_id': 'c',
      'to_org_unit_id': 'd',
      'to_location_id': 'e',
      'to_responsible_id': 'f',
    };
    for (final k in [DocKind.transfer, DocKind.handOver]) {
      expect(draft(k, two).isSaveable, isTrue);
      expect(draft(k, {...two}..remove('to_location_id')).isSaveable, isFalse);
      expect(
        draft(k, {
          ...two,
          'to_org_unit_id': 'a',
          'to_location_id': 'b',
          'to_responsible_id': 'c',
        }).problems(),
        contains('sides'),
      );
    }
    final ret = {
      'from_org_unit_id': 'a',
      'from_location_id': 'b',
      'from_responsible_id': 'c',
      'org_unit_id': 'd',
      'to_location_id': 'e',
      'to_responsible_id': 'f',
    };
    expect(draft(DocKind.returnDoc, ret).isSaveable, isTrue);
    expect(
      draft(
        DocKind.returnDoc,
        {...ret}..remove('to_responsible_id'),
      ).isSaveable,
      isFalse,
    );
  });

  test('T-M3: quantity and decimal text', () {
    expect(normalizeQuantity('12,5'), '12.5');
    expect(normalizeQuantity('7'), '7');
    for (final bad in [
      '0',
      '0.0',
      '-1',
      '1.1234567891',
      'abc',
      '',
      '1,000.5',
      '01',
      '1,2,3',
    ]) {
      expect(normalizeQuantity(bad), isNull, reason: bad);
    }
    expect(normalizeDecimal('0'), '0');
    expect(normalizeDecimal('-1'), isNull);
    expect(
      isoWithOffset(DateTime(2026, 11, 5, 9, 8, 7)),
      matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$')),
    );
  });

  test(
    'T-M4: fromServer keeps every header key and line; malformed throws',
    () {
      final d = DocDraft.fromServer({
        'id': 'd1',
        'kind': 'transfer',
        'state': 'draft',
        'event_time': t,
        'org_unit_id': 'a',
        'to_org_unit_id': 'b',
        'note': 'n',
        'lines': [
          {
            'line_no': 2,
            'catalog_item_id': 'i2',
            'catalog_uom_id': 'u',
            'quantity': '2',
          },
          {
            'line_no': 1,
            'catalog_item_id': 'i1',
            'catalog_uom_id': 'u',
            'quantity': '1.5',
          },
        ],
      });
      expect(d.lines.map((l) => l.item), ['i1', 'i2']);
      expect(d.toBody()['event_time'], t);
      expect(d.toBody()['note'], 'n');
      expect(
        () => DocDraft.fromServer('x'),
        throwsA(isA<MalformedDocumentAnswer>()),
      );
      expect(
        () => DocDraft.fromServer({'id': 'd', 'kind': 'opening', 'lines': []}),
        throwsA(isA<MalformedDocumentAnswer>()),
      );
    },
  );
}
