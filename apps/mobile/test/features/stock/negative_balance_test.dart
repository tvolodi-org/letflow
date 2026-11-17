// REQ-840 (decision 0090, rule 6): the "balance will become negative"
// warning of the stock document form, against a hand-written fake gateway.
// No network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/features/codes/scan_source.dart';
import 'package:letflow/features/stock/documents/documents_providers.dart';
import 'package:letflow/features/stock/documents/negative_balance.dart';
import 'package:letflow/features/stock/stock.dart';
import 'package:letflow/features/stock/voice/voice_api.dart';
import 'package:letflow/features/stock/voice/voice_source.dart';
import 'package:letflow/i18n/i18n.dart';

import '../../support/fake_write_gateway.dart';
import '../../support/load_test_catalogue.dart';
import '../codes/fakes.dart';
import 'fakes_voice.dart';

const _docs = '/api/v1/modules/stock/documents';
const _query = '/api/v1/entities/query';

late FakeWriteGateway gw;

const _header = {
  'org_unit_id': 'org_unit-1',
  'location_id': 'location_node-1',
  'responsible_id': 'org_employee-1',
};

Map<String, dynamic> _row(String sku, String quantity) => {
  'sku': sku,
  'location': 'location_node-1',
  'org_unit': 'org_unit-1',
  'responsible': 'org_employee-1',
  'lot': null,
  'unit_ref': 'uom-1',
  'quantity': quantity,
};

Map<String, dynamic> _doc(
  String kind,
  List<(String, String)> lines, {
  Map<String, dynamic> header = _header,
}) => {
  'id': 'd1',
  'kind': kind,
  'state': 'draft',
  'number': null,
  'event_time': '2026-11-05T10:00:00+05:00',
  ...header,
  'lines': [
    for (var i = 0; i < lines.length; i++)
      {
        'line_no': i + 1,
        'catalog_item_id': lines[i].$1,
        'catalog_uom_id': 'uom-1',
        'quantity': lines[i].$2,
      },
  ],
};

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
          'field_values': {'name': '$entity $id', 'base_uom_id': 'uom-1'},
        },
      ],
    };
  }
  return {'items': const []};
}

/// Scripts the three reads of the warning. [rules] null means no answer
/// scripted for posting-rules at all.
void _script({
  Object access = const {
    'permissions': ['StockRead', 'StockPost'],
  },
  Object rules = const {'negative_balance': 'allowed'},
  Object? balances,
}) {
  gw.on('GET', kMeAccessPath, [access]);
  gw.on('GET', kStockPostingRulesPath, [rules]);
  gw.on('GET', kStockBalancesPath, [
    balances ??
        {
          'rows': [
            _row('item-1', '5.000000000'),
            _row('item-2', '5.000000000'),
          ],
          'next_cursor': null,
        },
  ]);
}

Future<void> _open(WidgetTester tester, Map<String, dynamic> doc) async {
  tester.view.physicalSize = const Size(900, 9000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  gw.on('GET', '$_docs/d1', [doc]);
  gw.on('POST', _query, [_queryAnswer]);
  final voice = FakeVoiceSource();
  final router = GoRouter(
    initialLocation: '$kStockDocumentsPath/d1',
    routes: stockRoutes(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        stockGatewayProvider.overrideWithValue(gw),
        scanSourceProvider.overrideWithValue(() => FakeScanSource()),
        voiceSourceProvider.overrideWithValue(voice),
        voiceUiLocaleProvider.overrideWithValue('ru'),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _banner(int line) => find.byKey(Key('stock-doc-line-$line-negative'));

int _balanceReads() => gw.callsTo('GET', kStockBalancesPath).length;

void main() {
  setUpAll(loadTestMessageCatalogue);
  setUp(() {
    gw = FakeWriteGateway();
  });
  tearDown(() => setUserUiLocale(null));

  group('texts', () {
    for (final (locale, text) in [
      ('ru', 'Остаток станет отрицательным'),
      ('kk', 'Қалдық теріс болады'),
      ('en', 'The balance will become negative'),
    ]) {
      testWidgets('N1/N4: line of 7 on a key holding 5, in $locale', (
        tester,
      ) async {
        setUserUiLocale(locale);
        _script();
        await _open(tester, _doc('issue', [('item-1', '7')]));
        expect(_banner(0), findsOneWidget);
        expect(find.text(text), findsOneWidget);
        expect(tr('stock.doc.negativeBalance', uiLocale: locale), text);
        final save = tester.widget<FilledButton>(
          find.byKey(const Key('stock-doc-save')),
        );
        expect(save.onPressed, isNotNull);
        final issue = tester.widget<FilledButton>(
          find.byKey(const Key('stock-doc-issue')),
        );
        expect(issue.onPressed, isNotNull);
      });
    }
  });

  group('rule', () {
    testWidgets('N1: a line of 5 on a key holding 5 shows none', (
      tester,
    ) async {
      _script();
      await _open(tester, _doc('issue', [('item-1', '5')]));
      expect(_banner(0), findsNothing);
      expect(_balanceReads(), 1);
    });

    testWidgets('N1: an absent key counts as zero', (tester) async {
      _script(balances: {'rows': <Object>[], 'next_cursor': null});
      await _open(tester, _doc('issue', [('item-1', '1')]));
      expect(_banner(0), findsOneWidget);
    });

    testWidgets('N1: two lines on one key are summed', (tester) async {
      _script();
      await _open(tester, _doc('issue', [('item-1', '3'), ('item-1', '3')]));
      expect(_banner(0), findsOneWidget);
      expect(_banner(1), findsOneWidget);
    });

    testWidgets('N1: a transfer judges the sending side', (tester) async {
      _script();
      await _open(
        tester,
        _doc(
          'transfer',
          [('item-1', '7')],
          header: {
            'org_unit_id': 'org_unit-1',
            'from_location_id': 'location_node-1',
            'from_responsible_id': 'org_employee-1',
            'to_org_unit_id': 'org_unit-2',
            'to_location_id': 'location_node-2',
            'to_responsible_id': 'org_employee-2',
          },
        ),
      );
      expect(_banner(0), findsOneWidget);
    });

    testWidgets('N1: editing the quantity evaluates again', (tester) async {
      _script();
      await _open(tester, _doc('issue', [('item-1', '5')]));
      expect(_banner(0), findsNothing);
      await tester.enterText(
        find.byKey(const Key('stock-doc-line-0-quantity')),
        '7',
      );
      await tester.pumpAndSettle();
      expect(_banner(0), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('stock-doc-line-0-quantity')),
        '2',
      );
      await tester.pumpAndSettle();
      expect(_banner(0), findsNothing);
    });

    test('N1: decimal scaling keeps nine places and the sign', () {
      expect(scaledDecimal('-2.000000000'), BigInt.from(-2000000000));
      expect(scaledDecimal('0.5'), BigInt.from(500000000));
      expect(scaledDecimal('abc'), isNull);
    });
  });

  group('no banner', () {
    testWidgets('N3: posting-rules refused', (tester) async {
      _script(rules: {'negative_balance': 'refused'});
      await _open(tester, _doc('issue', [('item-1', '7')]));
      expect(_banner(0), findsNothing);
      expect(_balanceReads(), 0);
    });

    testWidgets('N3: no StockRead, no balance request is sent', (tester) async {
      _script(
        access: {
          'permissions': ['StockPost'],
        },
      );
      await _open(tester, _doc('issue', [('item-1', '7')]));
      expect(_banner(0), findsNothing);
      expect(_balanceReads(), 0);
      expect(gw.callsTo('GET', kStockPostingRulesPath), isEmpty);
    });

    testWidgets('N3: offline', (tester) async {
      gw.on('GET', kMeAccessPath, [const NetworkUnavailableError()]);
      await _open(tester, _doc('issue', [('item-1', '7')]));
      expect(_banner(0), findsNothing);
      expect(find.byKey(const Key('stock-doc-save')), findsOneWidget);
    });

    testWidgets('N3: the balance read fails', (tester) async {
      _script();
      gw.on('GET', kStockBalancesPath, [
        const ServerError(lastStatusCode: 500),
      ]);
      await _open(tester, _doc('issue', [('item-1', '7')]));
      expect(_banner(0), findsNothing);
    });

    testWidgets('N3: a receipt is never judged', (tester) async {
      _script();
      await _open(tester, _doc('receipt', [('item-1', '70')]));
      expect(_banner(0), findsNothing);
      expect(gw.callsTo('GET', kMeAccessPath), isEmpty);
    });
  });

  group('voice', () {
    Map<String, dynamic> draft(String kind) => {
      'kind': kind,
      'items': [
        {'id': 'item-1', 'code': 'C-1', 'name': 'Bolt', 'base_unit': 'pcs'},
      ],
      'location': {'id': 'location_node-1', 'code': 'L1', 'name': 'Shelf'},
      'to_location': null,
      'quantity': '7',
      'transcript': 'x',
    };

    Future<void> speak(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('stock-voice-text')));
      await tester.enterText(
        find.byKey(const Key('stock-voice-text')),
        'issue seven bolts',
      );
      await tester.tap(find.byKey(const Key('stock-voice-text-send')));
      await tester.pumpAndSettle();
    }

    testWidgets('N2: a voice draft that fills an issue of 7 warns once', (
      tester,
    ) async {
      _script();
      gw.on('POST', kVoiceDraftTextPath, [draft('issue')]);
      await _open(tester, _doc('issue', [('item-2', '1')]));
      expect(_banner(0), findsNothing);
      await speak(tester);
      expect(find.byKey(const Key('stock-doc-line-1-item')), findsOneWidget);
      expect(_banner(1), findsOneWidget);
      expect(_banner(0), findsNothing);
      expect(find.text(tr('stock.doc.negativeBalance')), findsOneWidget);
    });

    testWidgets('N2: a draft that fills a receipt shows none', (tester) async {
      _script();
      gw.on('POST', kVoiceDraftTextPath, [draft('receipt')]);
      await _open(tester, _doc('receipt', [('item-2', '1')]));
      await speak(tester);
      expect(find.byKey(const Key('stock-doc-line-1-item')), findsOneWidget);
      expect(_banner(0), findsNothing);
      expect(_banner(1), findsNothing);
      expect(_balanceReads(), 0);
    });
  });
}
