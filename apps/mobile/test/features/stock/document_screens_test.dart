// T-1346 (REQ-746): the draft list and the draft form against a fake write
// gateway and a fake scan source. No camera, no network.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/features/codes/scan_source.dart';
import 'package:letflow/features/stock/documents/document_kinds.dart';
import 'package:letflow/features/stock/documents/documents_providers.dart';
import 'package:letflow/features/stock/stock.dart';
import 'package:letflow/i18n/i18n.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

import '../../support/fake_write_gateway.dart';
import '../../support/load_test_catalogue.dart';
import '../codes/fakes.dart';

const _docs = '/api/v1/modules/stock/documents';
const _query = '/api/v1/entities/query';
const _resolve = '/api/v1/modules/codes/resolve';

late FakeWriteGateway gw;
late FakeScanSource source;

/// Entity query: two options per type; `record_id` filter finds one record.
Object? _queryAnswer(Object? data) {
  final body = data as Map;
  final entity = body['entity_type'] as String;
  final filters = (body['filters'] as List).cast<Map>();
  final byId = filters.where((f) => f['field'] == 'record_id');
  if (byId.isNotEmpty) {
    final id = byId.first['value'] as String;
    return {
      'items': [
        {
          'record_id': id,
          'field_values': {
            'name': '$entity $id',
            'code': '$entity $id',
            'item_id': 'item-9',
            'base_uom_id': 'uom-9',
          },
        },
      ],
    };
  }
  return {
    'items': [
      for (final n in [1, 2])
        {
          'record_id': '$entity-$n',
          'field_values': {
            'name': '$entity $n',
            'full_name': '$entity $n',
            'code': '$entity $n',
            'base_uom_id': 'uom-1',
          },
        },
    ],
  };
}

Map<String, dynamic> _doc(
  String kind, {
  String id = 'd1',
  String state = 'draft',
  Map<String, dynamic> header = const {},
  List<Map<String, dynamic>>? lines,
}) => {
  'id': id,
  'kind': kind,
  'state': state,
  'number': state == 'draft' ? null : 'N-1',
  'event_time': '2026-11-05T10:00:00+05:00',
  ...header,
  'lines':
      lines ??
      [
        {
          'line_no': 1,
          'catalog_item_id': 'item-1',
          'catalog_uom_id': 'uom-1',
          'quantity': '2',
        },
        {
          'line_no': 2,
          'catalog_item_id': 'item-2',
          'catalog_uom_id': 'uom-1',
          'quantity': '3.5',
        },
      ],
};

const _issueHeader = {
  'org_unit_id': 'org_unit-1',
  'location_id': 'location_node-1',
  'responsible_id': 'org_employee-1',
  'note': 'keep me',
};

Map<String, dynamic> _scanAnswer(String status, {String? type, String? id}) => {
  'code_id': 'c1',
  'value': 'AB+12 ',
  'kind': 'barcode',
  'status': status,
  'target_type': type,
  'target_id': id,
};

Future<void> _pump(WidgetTester tester, String start) async {
  tester.view.physicalSize = const Size(900, 9000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  gw.on('POST', _query, [_queryAnswer]);
  final router = GoRouter(initialLocation: start, routes: stockRoutes());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stockGatewayProvider.overrideWithValue(gw),
        scanSourceProvider.overrideWithValue(source),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String field, String option) async {
  await _tap(tester, field);
  await _tap(tester, 'stock-doc-option-$option');
}

FilledButton _button(WidgetTester tester, String key) =>
    tester.widget<FilledButton>(find.byKey(Key(key)));

String _errorText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('stock-doc-error'))).data!;

Future<void> _openDraft(WidgetTester tester, Map<String, dynamic> doc) async {
  gw.on('GET', '$_docs/d1', [doc]);
  await _pump(tester, '$kStockDocumentsPath/d1');
}

void main() {
  setUpAll(loadTestMessageCatalogue);
  setUp(() {
    gw = FakeWriteGateway();
    source = FakeScanSource();
  });

  group('list', () {
    testWidgets('D1-D5: drafts, filter, load more, open, new kinds', (
      tester,
    ) async {
      gw.on('GET', _docs, [
        {
          'rows': [
            {'id': 'd1', 'kind': 'issue', 'state': 'draft', 'number': null},
          ],
          'next_cursor': 'c2',
        },
        {
          'rows': [
            {'id': 'd2', 'kind': 'receipt', 'state': 'draft'},
          ],
          'next_cursor': null,
        },
        {'rows': [], 'next_cursor': null},
      ]);
      gw.on('GET', '$_docs/d1', [_doc('issue', header: _issueHeader)]);
      await _pump(tester, kStockDocumentsPath);
      expect(gw.callsTo('GET', _docs).first.query, {'state': 'draft'});
      expect(find.byKey(const Key('stock-doc-row-d1')), findsOneWidget);
      await _tap(tester, 'stock-doc-load-more');
      expect(gw.callsTo('GET', _docs)[1].query, {
        'state': 'draft',
        'cursor': 'c2',
      });
      expect(find.byKey(const Key('stock-doc-row-d2')), findsOneWidget);
      expect(find.byKey(const Key('stock-doc-load-more')), findsNothing);
      await _tap(tester, 'stock-doc-filter-write_off');
      expect(gw.callsTo('GET', _docs)[2].query, {
        'state': 'draft',
        'kind': 'write_off',
      });
      expect(find.byKey(const Key('stock-doc-list-empty')), findsOneWidget);
      await _tap(tester, 'stock-doc-new');
      for (final k in DocKind.values) {
        expect(find.byKey(Key('stock-doc-new-${k.wire}')), findsOneWidget);
      }
      expect(find.byKey(const Key('stock-doc-new-opening')), findsNothing);
    });

    testWidgets('D4: a tapped row loads the document into the form', (
      tester,
    ) async {
      gw.on('GET', _docs, [
        {
          'rows': [
            {'id': 'd1', 'kind': 'issue', 'state': 'draft'},
          ],
        },
      ]);
      gw.on('GET', '$_docs/d1', [_doc('issue', header: _issueHeader)]);
      await _pump(tester, kStockDocumentsPath);
      await _tap(tester, 'stock-doc-row-d1');
      expect(gw.callsTo('GET', '$_docs/d1'), hasLength(1));
      expect(find.byKey(const Key('stock-doc-form-screen')), findsOneWidget);
      expect(find.text('keep me'), findsOneWidget);
      expect(find.byKey(const Key('stock-doc-line-1')), findsOneWidget);
    });

    testWidgets('S1g: the stock home links to the documents', (tester) async {
      gw.on('GET', _docs, [
        {'rows': []},
      ]);
      await _pump(tester, kStockHomePath);
      await _tap(tester, 'stock-home-documents-entry');
      expect(find.byKey(const Key('stock-doc-list-screen')), findsOneWidget);
    });
  });

  group('create per kind', () {
    for (final (n, kind) in DocKind.values.indexed) {
      testWidgets('D${6 + n}: ${kind.wire} saves its exact key set', (
        tester,
      ) async {
        final posted = <Map>[];
        gw.on('POST', _docs, [
          (Object? data) {
            posted.add(data as Map);
            return {...data, 'id': 'd1', 'state': 'draft'};
          },
        ]);
        await _pump(tester, '$kStockDocumentsPath/new/${kind.wire}');
        final spec = documentKindSpecs[kind]!;
        final expected = {'kind', 'event_time', 'lines'};
        expect(_button(tester, 'stock-doc-save').onPressed, isNull);
        for (final f in spec.fields) {
          if (f.input == FieldInput.pick) {
            await _pick(
              tester,
              'stock-doc-field-${f.key}',
              '${f.entity}-${f.side == Side.to ? 2 : 1}',
            );
            expected.add(f.key);
          } else if (f.input == FieldInput.reason) {
            await _pick(tester, 'stock-doc-field-${f.key}', 'lost');
            expected.add(f.key);
          }
        }
        await _pick(tester, 'stock-doc-line-0-item', 'catalog_item-1');
        await tester.enterText(
          find.byKey(const Key('stock-doc-line-0-quantity')),
          '12,5',
        );
        await tester.pumpAndSettle();
        await _tap(tester, 'stock-doc-save');
        final body = posted.single;
        expect(body.keys.toSet(), expected);
        expect(body['kind'], kind.wire);
        expect(
          body['event_time'],
          matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$')),
        );
        final line = (body['lines'] as List).single as Map;
        expect(line, {
          'line_no': 1,
          'catalog_item_id': 'catalog_item-1',
          'catalog_uom_id': 'uom-1',
          'quantity': '12.5',
        });
        expect(gw.calls.where((c) => c.path.endsWith('/post')), isEmpty);
        // D18: the saved draft keeps its org unit
        await _tap(tester, 'stock-doc-field-org_unit_id');
        expect(
          find.byKey(const Key('stock-doc-option-org_unit-1')),
          findsNothing,
        );
      });
    }

    testWidgets(
      'D14/D15/D16/D17: other needs text; pickers; lot filter; unit preset',
      (tester) async {
        await _pump(tester, '$kStockDocumentsPath/new/write_off');
        await _pick(tester, 'stock-doc-field-org_unit_id', 'org_unit-1');
        await _pick(tester, 'stock-doc-field-location_id', 'location_node-1');
        await _pick(tester, 'stock-doc-field-responsible_id', 'org_employee-1');
        await _pick(tester, 'stock-doc-field-reason_code', 'other');
        await _pick(tester, 'stock-doc-line-0-item', 'catalog_item-2');
        await tester.enterText(
          find.byKey(const Key('stock-doc-line-0-quantity')),
          '1',
        );
        await tester.pumpAndSettle();
        expect(_button(tester, 'stock-doc-save').onPressed, isNull);
        await tester.enterText(
          find.byKey(const Key('stock-doc-field-reason_text')),
          'dropped',
        );
        await tester.pumpAndSettle();
        expect(_button(tester, 'stock-doc-save').onPressed, isNotNull);
        final org = gw.callsTo('POST', _query).first.data as Map;
        expect(org['entity_type'], 'org_unit');
        expect(org['page_size'], 200);
        expect(org['filters'], [
          {'field': 'active', 'op': 'eq', 'value': true},
          {'field': 'deleted', 'op': 'eq', 'value': false},
        ]);
        await _tap(tester, 'stock-doc-line-0-lot');
        final lot = gw.callsTo('POST', _query).map((c) => c.data as Map).last;
        expect(lot['entity_type'], 'catalog_lot');
        expect(
          lot['filters'],
          contains(
            equals({'field': 'item_id', 'op': 'eq', 'value': 'catalog_item-2'}),
          ),
        );
        await _tap(tester, 'stock-doc-option-catalog_lot-1');
        expect(find.text('catalog_lot 1'), findsOneWidget);
        expect(find.text('uom-1'), findsOneWidget); // preset from base_uom_id
      },
    );
  });

  group('scan', () {
    Future<void> scan(
      WidgetTester tester,
      String button,
      Map<String, dynamic> answer,
    ) async {
      gw.on('POST', _resolve, [answer]);
      await _tap(tester, button);
      await tester.enterText(
        find.byKey(const Key('stock-doc-scan-typed')),
        'AB+12 ',
      );
      await _tap(tester, 'stock-doc-scan-lookup');
    }

    testWidgets(
      'D19/D23: a location code fills the field, text sent unchanged',
      (tester) async {
        await _pump(tester, '$kStockDocumentsPath/new/transfer');
        await scan(
          tester,
          'stock-doc-scan-location-to',
          _scanAnswer('assigned', type: 'location_node', id: 'loc-7'),
        );
        expect(gw.callsTo('POST', _resolve).single.data, {'value': 'AB+12 '});
        expect(find.text('loc-7'), findsOneWidget);
        expect(find.byKey(const Key('stock-doc-error')), findsNothing);
        await scan(
          tester,
          'stock-doc-scan-location-from',
          _scanAnswer('assigned', type: 'location_node', id: 'loc-8'),
        );
        expect(find.text('loc-8'), findsOneWidget);
      },
    );

    testWidgets('D20: an item code fills the item and its unit', (
      tester,
    ) async {
      await _pump(tester, '$kStockDocumentsPath/new/issue');
      await scan(
        tester,
        'stock-doc-scan-line-0',
        _scanAnswer('assigned', type: 'catalog_item', id: 'item-9'),
      );
      expect(find.text('catalog_item item-9'), findsOneWidget);
      expect(find.text('uom-9'), findsOneWidget);
    });

    testWidgets('D21: a lot code fills the lot and the item from the lot', (
      tester,
    ) async {
      await _pump(tester, '$kStockDocumentsPath/new/issue');
      await scan(
        tester,
        'stock-doc-scan-line-0',
        _scanAnswer('assigned', type: 'catalog_lot', id: 'lot-9'),
      );
      expect(find.text('catalog_lot lot-9'), findsOneWidget);
      expect(find.text('catalog_item item-9'), findsOneWidget);
    });

    testWidgets(
      'D22: a wrong kind or a status other than assigned fills nothing',
      (tester) async {
        await _pump(tester, '$kStockDocumentsPath/new/issue');
        await scan(
          tester,
          'stock-doc-scan-location-single',
          _scanAnswer('assigned', type: 'catalog_item', id: 'item-9'),
        );
        expect(_errorText(tester), tr('stock.doc.scan.wrongKind'));
        expect(find.text('item-9'), findsNothing);
        await scan(
          tester,
          'stock-doc-scan-location-single',
          _scanAnswer('retired'),
        );
        expect(_errorText(tester), tr('codes.status.retired'));
        await scan(
          tester,
          'stock-doc-scan-location-single',
          _scanAnswer('not_assigned'),
        );
        expect(_errorText(tester), tr('codes.status.notAssigned'));
        expect(find.text('location_node'), findsNothing);
      },
    );
  });

  group('change, discard, issue', () {
    testWidgets('D24: one PUT with the whole header and both lines', (
      tester,
    ) async {
      gw.on('PUT', '$_docs/d1', [
        (Object? data) => {...(data as Map), 'id': 'd1', 'state': 'draft'},
      ]);
      await _openDraft(tester, _doc('issue', header: _issueHeader));
      await tester.enterText(
        find.byKey(const Key('stock-doc-line-1-quantity')),
        '4,25',
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'stock-doc-save');
      final puts = gw.callsTo('PUT', '$_docs/d1');
      expect(puts, hasLength(1));
      final body = puts.single.data as Map;
      expect(body['kind'], 'issue');
      expect(body['event_time'], '2026-11-05T10:00:00+05:00');
      expect({for (final k in _issueHeader.keys) k: body[k]}, _issueHeader);
      final lines = (body['lines'] as List).cast<Map>();
      expect(lines.map((l) => l['quantity']), ['2', '4.25']);
      expect(lines.map((l) => l['line_no']), [1, 2]);
      expect(gw.callsTo('POST', _docs), isEmpty);
    });

    testWidgets('D25: Discard asks first, then DELETE and back to the list', (
      tester,
    ) async {
      gw.on('DELETE', '$_docs/d1', [<String, dynamic>{}]);
      gw.on('GET', _docs, [
        {'rows': []},
      ]);
      await _openDraft(tester, _doc('issue', header: _issueHeader));
      await _tap(tester, 'stock-doc-discard');
      expect(gw.callsTo('DELETE', '$_docs/d1'), isEmpty);
      await _tap(tester, 'stock-doc-discard-no');
      expect(gw.callsTo('DELETE', '$_docs/d1'), isEmpty);
      await _tap(tester, 'stock-doc-discard');
      await _tap(tester, 'stock-doc-discard-yes');
      expect(gw.callsTo('DELETE', '$_docs/d1'), hasLength(1));
      expect(find.byKey(const Key('stock-doc-list-screen')), findsOneWidget);
    });

    testWidgets('D26: Issue saves a changed draft first, then posts /issue', (
      tester,
    ) async {
      gw.on('PUT', '$_docs/d1', [
        (Object? data) => {...(data as Map), 'id': 'd1', 'state': 'draft'},
      ]);
      gw.on('POST', '$_docs/d1/issue', [
        _doc('issue', state: 'issued', header: _issueHeader),
      ]);
      await _openDraft(tester, _doc('issue', header: _issueHeader));
      await tester.enterText(
        find.byKey(const Key('stock-doc-line-0-quantity')),
        '9',
      );
      await tester.pumpAndSettle();
      await _tap(tester, 'stock-doc-issue');
      expect(
        gw.calls
            .where((c) => c.method != 'GET' && c.path != _query)
            .map((c) => c.key),
        ['PUT $_docs/d1', 'POST $_docs/d1/issue'],
      );
      expect(find.byKey(const Key('stock-doc-readonly')), findsOneWidget);
      expect(find.byKey(const Key('stock-doc-save')), findsNothing);
      expect(gw.calls.where((c) => c.path.endsWith('/post')), isEmpty);
    });

    testWidgets('D26b: an unchanged saved draft goes straight to /issue', (
      tester,
    ) async {
      gw.on('POST', '$_docs/d1/issue', [
        _doc('issue', state: 'issued', header: _issueHeader),
      ]);
      await _openDraft(tester, _doc('issue', header: _issueHeader));
      await _tap(tester, 'stock-doc-issue');
      expect(
        gw.calls
            .where((c) => c.method != 'GET' && c.path != _query)
            .map((c) => c.key),
        ['POST $_docs/d1/issue'],
      );
    });

    testWidgets('a non-draft document opens read-only', (tester) async {
      await _openDraft(
        tester,
        _doc('issue', state: 'posted', header: _issueHeader),
      );
      expect(find.byKey(const Key('stock-doc-readonly')), findsOneWidget);
      expect(find.byKey(const Key('stock-doc-save')), findsNothing);
      expect(find.byKey(const Key('stock-doc-issue')), findsNothing);
      expect(find.byKey(const Key('stock-doc-discard')), findsNothing);
    });
  });

  group('refusals', () {
    Future<void> refuse(WidgetTester tester, ApiError error) async {
      gw.on('PUT', '$_docs/d1', [error]);
      await _openDraft(
        tester,
        _doc(
          'transfer',
          header: {
            'org_unit_id': 'a',
            'from_location_id': 'b',
            'from_responsible_id': 'c',
            'to_org_unit_id': 'd',
            'to_location_id': 'e',
            'to_responsible_id': 'f',
          },
        ),
      );
      await _tap(tester, 'stock-doc-save');
    }

    testWidgets(
      'D28-D30: every reason has its own message; field, line, side shown',
      (tester) async {
        final seen = <String>{};
        for (final reason in [
          'field_not_allowed',
          'field_required',
          'field_invalid',
          'price_invalid',
          'reason_invalid',
          'sides_equal',
          'document_not_draft',
          'not_linked',
          'employee_not_active',
          'counterparty_not_active',
          'unit_not_valid',
          'lot_not_valid',
        ]) {
          gw = FakeWriteGateway();
          await refuse(
            tester,
            reason == 'document_not_draft'
                ? ConflictError(reason: reason)
                : ValidationError(
                    fieldErrors: const [],
                    reason: reason,
                    field: 'location_id',
                    lineNo: 2,
                    side: 'to',
                  ),
          );
          final text = _errorText(tester);
          expect(text, isNot(tr('stock.doc.error.generic')), reason: reason);
          expect(text, isNot(contains('stock.doc.error')), reason: reason);
          expect(seen.add(text), isTrue, reason: '$reason repeats a message');
          expect(text, isNot(contains('{')), reason: reason);
          if (reason == 'field_required') {
            expect(text, contains(tr('stock.doc.field.location_id')));
            expect(text, contains('2'));
          }
          if (reason == 'not_linked') {
            expect(text, contains(tr('stock.doc.side.to')));
          }
        }
      },
    );

    testWidgets('D31: 404 gives the one not-found message', (tester) async {
      await refuse(tester, const ModuleNotAvailableError(moduleId: 'stock'));
      expect(_errorText(tester), tr('stock.doc.error.notFound'));
    });

    testWidgets('D32: an unknown reason and a hostile field are never echoed', (
      tester,
    ) async {
      await refuse(
        tester,
        const ValidationError(
          fieldErrors: [],
          reason: '<b>boom</b>',
          field: 'secret_col',
        ),
      );
      expect(_errorText(tester), tr('stock.doc.error.generic'));
      await refuse(
        tester,
        const ValidationError(
          fieldErrors: [],
          reason: 'field_required',
          field: 'secret_col',
        ),
      );
      expect(find.textContaining('secret_col'), findsNothing);
    });

    testWidgets('D33: 403 shows the permission-denied state', (tester) async {
      await refuse(tester, const ForbiddenError());
      expect(find.byKey(rendererPermissionDeniedKey), findsOneWidget);
    });

    testWidgets('D34: 429 shows the countdown', (tester) async {
      await refuse(tester, const BackpressureError(retryAfterSeconds: 30));
      expect(find.byKey(rendererBackpressureKey), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('D35: a network failure shows retry, and Retry calls again', (
      tester,
    ) async {
      gw.on('PUT', '$_docs/d1', [
        const NetworkUnavailableError(),
        _doc('transfer'),
      ]);
      await _openDraft(
        tester,
        _doc(
          'transfer',
          header: {
            'org_unit_id': 'a',
            'from_location_id': 'b',
            'from_responsible_id': 'c',
            'to_org_unit_id': 'd',
            'to_location_id': 'e',
            'to_responsible_id': 'f',
          },
        ),
      );
      await _tap(tester, 'stock-doc-save');
      expect(find.byKey(rendererFetchFailureKey), findsOneWidget);
      await _tap(tester, 'stock-doc-retry');
      expect(gw.callsTo('PUT', '$_docs/d1'), hasLength(2));
      expect(find.byKey(rendererFetchFailureKey), findsNothing);
    });

    testWidgets('a load that finds nothing shows the not-found text', (
      tester,
    ) async {
      gw.on('GET', '$_docs/d1', [
        const ModuleNotAvailableError(moduleId: 'stock'),
      ]);
      await _pump(tester, '$kStockDocumentsPath/d1');
      expect(find.byKey(const Key('stock-doc-not-found')), findsOneWidget);
    });

    testWidgets('a malformed answer is a fetch failure, not a crash', (
      tester,
    ) async {
      gw.on('GET', '$_docs/d1', ['not a document']);
      await _pump(tester, '$kStockDocumentsPath/d1');
      expect(find.byKey(rendererFetchFailureKey), findsOneWidget);
    });
  });

  for (final c in [('ru', 'Складские документы'), ('kk', 'Қойма құжаттары')]) {
    testWidgets('I2: ${c.$1} list title and a refusal', (tester) async {
      final saved = appMessageCatalogue;
      addTearDown(() => appMessageCatalogue = saved);
      final table =
          (jsonDecode(File('lib/i18n/l10n/app_${c.$1}.arb').readAsStringSync())
                as Map<String, dynamic>)
            ..removeWhere((k, v) => k.startsWith('@'));
      appMessageCatalogue = MessageCatalogue({
        'en': table.map((k, v) => MapEntry(k, v as String)),
      });
      gw.on('GET', _docs, [
        {'rows': []},
      ]);
      await _pump(tester, kStockDocumentsPath);
      expect(find.text(c.$2), findsWidgets);
      expect(tr('stock.doc.error.sides_equal'), isNot(contains('stock.doc')));
    });
  }
}
