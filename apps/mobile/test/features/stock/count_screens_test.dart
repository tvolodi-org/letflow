// D3a: the count screens against a fake gateway and the fake scan source.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/features/codes/codes.dart';
import 'package:letflow/features/stock/count_detail_screen.dart';
import 'package:letflow/features/stock/count_list_screen.dart';
import 'package:letflow/features/stock/stock_providers.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

import '../../support/fake_put_capable_http_gateway.dart';
import '../../support/load_test_catalogue.dart';
import '../codes/fakes.dart';

const _loc = '11111111-1111-4111-8111-111111111111';
const _item = '22222222-2222-4222-8222-222222222222';
const _unit = '33333333-3333-4333-8333-333333333333';

late FakeScanSource source;

Widget _app(FakePutCapableHttpGateway g, Widget home) => ProviderScope(
  overrides: [
    scanSourceProvider.overrideWithValue(() => source),
    stockGatewayProvider.overrideWithValue(g),
  ],
  child: MaterialApp(home: home),
);

Map<String, dynamic> _line() => {
  'line_no': 1,
  'location_id': _loc,
  'catalog_item_id': _item,
  'unit_ref': _unit,
  'book_quantity': '5.000',
  'counted_quantity': '2.500',
};

void main() {
  setUpAll(loadTestMessageCatalogue);
  setUp(() => source = FakeScanSource());

  testWidgets('list: rows, empty and permission denied', (tester) async {
    var denied = false;
    final g = FakePutCapableHttpGateway((c) {
      if (denied) throw const ForbiddenError();
      return {
        'rows': [
          {'id': 'c1', 'status': 'counting', 'number': 'N-7'},
        ],
        'next_cursor': null,
      };
    });
    await tester.pumpWidget(_app(g, const CountListScreen()));
    await tester.pumpAndSettle();
    expect(find.text('N-7'), findsOneWidget);
    denied = true;
    await tester.tap(find.byKey(const Key('stock-counts-tab-ordered')));
    await tester.pumpAndSettle();
    expect(find.byKey(rendererPermissionDeniedKey), findsOneWidget);
  });

  testWidgets(
    'detail: typed place, scan_no_line, surplus form, camera refused',
    (tester) async {
      var resolves = 0;
      final g = FakePutCapableHttpGateway((c) {
        if (c.path.endsWith('/codes/resolve')) {
          resolves++;
          return resolves == 1
              ? {
                  'status': 'assigned',
                  'value': 'L',
                  'target_type': 'location_node',
                  'target_id': _loc,
                }
              : {
                  'status': 'assigned',
                  'value': 'I',
                  'target_type': 'catalog_item',
                  'target_id': _item,
                };
        }
        if (c.path.endsWith('/scan')) {
          throw ValidationError(fieldErrors: const [], reason: 'scan_no_line');
        }
        if (c.path.endsWith('/surplus-lines')) {
          return {..._line(), 'line_no': 2, 'counted_quantity': '4'};
        }
        if (c.path.endsWith('/lines')) {
          return {
            'rows': [_line()],
            'next_cursor': null,
          };
        }
        return {'id': 'c1', 'status': 'counting', 'number': 'N-7'};
      });
      await tester.pumpWidget(_app(g, const CountDetailScreen(countId: 'c1')));
      await tester.pumpAndSettle();
      source.controller.add(const ScanPermissionRefused());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('stock-count-camera-refused')),
        findsOneWidget,
      );

      await tester.enterText(find.byKey(const Key('stock-typed')), 'L');
      await tester.tap(find.byKey(const Key('stock-send')));
      await tester.pumpAndSettle();
      expect(find.textContaining(_loc), findsOneWidget);

      await tester.enterText(find.byKey(const Key('stock-typed')), 'I ');
      await tester.tap(find.byKey(const Key('stock-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stock-refusal')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('stock-surplus-open')));
      await tester.tap(find.byKey(const Key('stock-surplus-open')));
      await tester.pumpAndSettle();
      // Item and unit are pre-filled from the resolve answer and the line.
      expect(find.text(_item), findsWidgets);
      TextButton save() => tester.widget<TextButton>(
        find.byKey(const Key('stock-surplus-save')),
      );
      expect(save().onPressed, isNull);
      await tester.enterText(find.byKey(const Key('stock-surplus-qty')), '4');
      await tester.pump();
      expect(save().onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('stock-surplus-save')));
      await tester.pumpAndSettle();
      final body = g.where('POST', '/surplus-lines').single.data as Map;
      expect(body['catalog_item_id'], _item);
      expect(body['unit_ref'], _unit);
      expect(find.byKey(const Key('stock-line-2')), findsOneWidget);
    },
  );

  // PWA M4 S5: on web the count screen starts the camera only after a tap;
  // a refusal and an unavailable camera have their own texts.
  FakePutCapableHttpGateway countGateway() => FakePutCapableHttpGateway((c) {
    if (c.path.endsWith('/lines')) {
      return {
        'rows': [_line()],
        'next_cursor': null,
      };
    }
    return {'id': 'c1', 'status': 'counting', 'number': 'N-7'};
  });

  testWidgets('S5a: web waits for the tap, then starts the camera once', (
    tester,
  ) async {
    source.needsUserTap = true;
    await tester.pumpWidget(
      _app(countGateway(), const CountDetailScreen(countId: 'c1')),
    );
    await tester.pumpAndSettle();
    expect(source.starts, 0);
    expect(find.byKey(const Key('stock-count-camera-intro')), findsOneWidget);
    expect(find.byKey(const Key('fake-preview')), findsNothing);
    expect(find.byKey(const Key('stock-scan-again')), findsNothing);
    expect(find.byKey(const Key('stock-typed')), findsOneWidget);
    await tester.tap(find.byKey(const Key('stock-count-camera-start')));
    await tester.pumpAndSettle();
    expect(source.starts, 1);
    expect(find.byKey(const Key('fake-preview')), findsOneWidget);
    expect(find.byKey(const Key('stock-count-camera-intro')), findsNothing);
  });

  testWidgets('S5b: refused and unavailable texts, typed field stays', (
    tester,
  ) async {
    source.needsUserTap = true;
    await tester.pumpWidget(
      _app(countGateway(), const CountDetailScreen(countId: 'c1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('stock-count-camera-start')));
    await tester.pumpAndSettle();
    source.unavailable();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('stock-count-camera-unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('stock-count-camera-refused')), findsNothing);
    expect(find.byKey(const Key('fake-preview')), findsNothing);
    expect(find.byKey(const Key('stock-typed')), findsOneWidget);
    source.refuse();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('stock-count-camera-refused')), findsOneWidget);
    expect(find.byKey(const Key('stock-typed')), findsOneWidget);
  });

  testWidgets('S5c: native starts the camera at once (no tap)', (tester) async {
    await tester.pumpWidget(
      _app(countGateway(), const CountDetailScreen(countId: 'c1')),
    );
    await tester.pumpAndSettle();
    expect(source.starts, 1);
    expect(find.byKey(const Key('stock-count-camera-intro')), findsNothing);
    expect(find.byKey(const Key('fake-preview')), findsOneWidget);
  });
}
