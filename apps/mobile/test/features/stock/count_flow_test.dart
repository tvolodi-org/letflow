// D3a: count list and detail controllers against a fake gateway and the fake
// scan source. No camera, no network.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/features/codes/codes.dart';
import 'package:letflow/features/stock/count_api.dart';
import 'package:letflow/features/stock/count_detail_controller.dart';
import 'package:letflow/features/stock/count_list_controller.dart';
import 'package:letflow/features/stock/count_models.dart';
import 'package:letflow/features/stock/count_refusal.dart';
import 'package:letflow/renderers/renderer_state.dart';

import '../../support/fake_put_capable_http_gateway.dart';
import '../codes/fakes.dart';

const _count = 'c1';
const _loc = '11111111-1111-4111-8111-111111111111';
const _item = '22222222-2222-4222-8222-222222222222';
const _unit = '33333333-3333-4333-8333-333333333333';
const _lot = '44444444-4444-4444-8444-444444444444';
const _base = '/api/v1/modules/stock/counts/$_count';

Map<String, dynamic> _order(String status) => {
  'id': _count,
  'status': status,
  'number': 'N-1',
};

Map<String, dynamic> _line(
  int no, {
  String item = _item,
  String? lot,
  String? counted,
  String unit = _unit,
}) => {
  'line_no': no,
  'location_id': _loc,
  'catalog_item_id': item,
  'catalog_lot_id': lot,
  'unit_ref': unit,
  'book_quantity': '5.000',
  'counted_quantity': counted,
};

Map<String, dynamic> _resolved(String status, [String? type, String? id]) => {
  'value': 'x',
  'status': status,
  'kind': 'barcode',
  'target_type': type,
  'target_id': id,
};

Object? _page(List<Map<String, dynamic>> rows, [String? next]) => {
  'rows': rows,
  'next_cursor': next,
};

ValidationError _refuse(String reason) =>
    ValidationError(fieldErrors: const [], reason: reason);

late FakeScanSource source;

CountDetailController _detail(FakePutCapableHttpGateway g) =>
    CountDetailController(
      id: _count,
      api: StockCountApi(g),
      resolver: CodesResolver(g),
      source: source,
    );

/// A gateway with a count, one page of lines, and per-test overrides.
FakePutCapableHttpGateway _gateway({
  StockHandler? scan,
  StockHandler? resolve,
  StockHandler? other,
}) {
  late FakePutCapableHttpGateway g;
  g = FakePutCapableHttpGateway((c) {
    if (c.path.endsWith('/codes/resolve')) {
      return (resolve ?? (_) => _resolved('not_assigned'))(c);
    }
    if (c.path == _base && c.method == 'GET') return _order('counting');
    if (c.path == '$_base/lines') return _page([_line(1)]);
    if (c.path == '$_base/entries') {
      return _page([
        {'entry_no': 1, 'line_no': 1, 'method': 'scan'},
      ]);
    }
    if (c.path == '$_base/scan') return (scan ?? (_) => _line(1))(c);
    final o = other?.call(c);
    return o;
  });
  return g;
}

Future<CountDetailController> _ready(FakePutCapableHttpGateway g) async {
  final c = _detail(g);
  await c.load();
  return c;
}

void main() {
  setUp(() => source = FakeScanSource());

  group('list', () {
    test('L1: status query, tab switch, load more, empty', () async {
      late FakePutCapableHttpGateway g;
      g = FakePutCapableHttpGateway((c) {
        if (c.query?['cursor'] == 'n1') return _page([_order('counting')]);
        if (c.query?['status'] == 'ordered') return _page([]);
        return _page([_order('counting')], 'n1');
      });
      final c = CountListController(StockCountApi(g));
      await c.load();
      expect(g.calls.single.path, '/api/v1/modules/stock/counts');
      expect(g.calls.single.query?['status'], 'counting');
      await c.loadMore();
      expect(g.calls.last.query?['cursor'], 'n1');
      expect(
        ((c.state as RendererContent<CountPage<CountOrder>>).data).rows.length,
        2,
      );
      await c.selectStatus('ordered');
      expect(g.calls.last.query?['status'], 'ordered');
      expect(
        ((c.state as RendererContent<CountPage<CountOrder>>).data).rows,
        isEmpty,
      );
    });

    test('L2: 403, 404, 429 and network states, retry works', () async {
      Object? failWith = const ForbiddenError();
      final g = FakePutCapableHttpGateway((_) {
        if (failWith != null) throw failWith as ApiError;
        return _page([_order('counting')]);
      });
      final c = CountListController(StockCountApi(g));
      await c.load();
      expect(c.state, isA<RendererPermissionDenied<CountPage<CountOrder>>>());
      failWith = const ModuleNotAvailableError(moduleId: 'stock');
      await c.load();
      expect(c.notAvailable, isTrue);
      failWith = const BackpressureError(retryAfterSeconds: 3);
      await c.load();
      expect(c.state, isA<RendererBackpressure<CountPage<CountOrder>>>());
      failWith = const NetworkUnavailableError();
      await c.load();
      expect(c.state, isA<RendererFetchFailure<CountPage<CountOrder>>>());
      failWith = null;
      await c.load();
      expect(c.state, isA<RendererContent<CountPage<CountOrder>>>());
      expect(c.notAvailable, isFalse);
    });
  });

  group('detail', () {
    test('D1: open and close post, not_chair is a message', () async {
      var refuse = false;
      final g = _gateway(
        other: (c) {
          if (refuse) throw _refuse('not_chair');
          return _order(c.path.endsWith('/open') ? 'counting' : 'closed');
        },
      );
      final c = await _ready(g);
      await c.open();
      expect(g.where('POST', '$_base/open'), hasLength(1));
      await c.close();
      expect(g.where('POST', '$_base/close'), hasLength(1));
      expect(((c.order as RendererContent<CountOrder>).data).status, 'closed');
      refuse = true;
      await c.close();
      expect(c.refusal, CountRefusal.notChair);
    });

    test('D2: place by resolve, then scan with the exact body', () async {
      final g = _gateway(
        resolve: (_) => _resolved('assigned', 'location_node', _loc),
      );
      final c = await _ready(g);
      await c.submitScan('LOC ');
      expect(g.where('POST', '/codes/resolve').single.data, {'value': 'LOC '});
      expect(g.where('POST', '/scan'), isEmpty);
      expect(c.placeId, _loc);
      await c.submitScan('AB+12 ');
      final body = g.where('POST', '/scan').single.data as Map;
      expect(body.keys.toSet(), {'scanned_text', 'location_id', 'scan_id'});
      expect(body['scanned_text'], 'AB+12 ');
      expect(body['location_id'], _loc);
    });

    test('D3: place problems are messages and set no place', () async {
      Object? answer = _resolved('assigned', 'catalog_item', _item);
      final g = _gateway(
        resolve: (_) {
          if (answer is ApiError) throw answer;
          return answer;
        },
      );
      final c = await _ready(g);
      await c.submitScan('a');
      expect(c.noticeKey, 'stock.place.notLocation');
      answer = _resolved('retired');
      await c.submitScan('a');
      expect(c.noticeKey, 'stock.place.retired');
      answer = _resolved('assignment_conflict');
      await c.submitScan('a');
      expect(c.noticeKey, 'stock.place.conflict');
      answer = _resolved('not_assigned');
      await c.submitScan('a');
      expect(c.noticeKey, 'stock.place.notAssigned');
      answer = const ModuleNotAvailableError(moduleId: 'codes');
      await c.submitScan('a');
      expect(c.noticeKey, 'stock.place.notKnown');
      expect(c.placeId, isNull);
      expect(g.where('POST', '/scan'), isEmpty);
    });

    test('D4: one detection, one request; empty ignored', () async {
      final gate = Completer<void>();
      final g = _gateway(
        resolve: (_) => _resolved('assigned', 'location_node', _loc),
      );
      final c = await _ready(g);
      await c.startScanning();
      source
        ..detect('')
        ..detect(null)
        ..detect('LOC')
        ..detect('LOC')
        ..detect('LOC');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(g.where('POST', '/codes/resolve'), hasLength(1));
      expect(c.scanning, isFalse);
      gate.complete();
    });

    test(
      'D5: retry after a network failure resends the same scan_id',
      () async {
        var fail = true;
        final g = _gateway(
          resolve: (_) => _resolved('assigned', 'location_node', _loc),
          scan: (_) {
            if (fail) throw const NetworkUnavailableError();
            return {..._line(1, counted: '1'), 'duplicate': true};
          },
        );
        final c = await _ready(g);
        await c.submitScan('LOC');
        await c.submitScan('ITEM');
        expect(c.failure, isA<RendererFetchFailure<Object?>>());
        fail = false;
        await c.retry();
        final ids = g
            .where('POST', '/scan')
            .map((x) => (x.data as Map)['scan_id'])
            .toList();
        expect(ids, hasLength(2));
        expect(ids[0], ids[1]);
        expect(c.lastDuplicate, isTrue);
        expect(c.lines.single.countedQuantity, '1');
        expect(c.failure, isNull);
        // A new detection gets a new id.
        await c.submitScan('ITEM');
        final ids3 = g
            .where('POST', '/scan')
            .map((x) => (x.data as Map)['scan_id']);
        expect(ids3.toSet(), hasLength(2));
      },
    );

    test('D6: every scan refusal shows its own reason', () async {
      const reasons = [
        'code_retired',
        'code_assignment_conflict',
        'code_not_assigned',
        'code_not_countable',
        'scan_no_line',
        'scan_ambiguous',
        'location_not_in_count',
        'not_commission_member',
        'count_state_invalid',
        'scan_id_conflict',
      ];
      String? current;
      final g = _gateway(
        resolve: (_) => _resolved('assigned', 'location_node', _loc),
        scan: (_) => throw _refuse(current!),
      );
      final c = await _ready(g);
      await c.submitScan('LOC');
      final seen = <CountRefusal?>[];
      for (final r in reasons) {
        current = r;
        await c.submitScan('X');
        seen.add(c.refusal);
        expect(c.refusal!.reason, r);
        expect(c.canSurplus, r == 'scan_no_line');
      }
      expect(seen.toSet(), hasLength(reasons.length));
      current = 'something_new';
      await c.submitScan('X');
      expect(c.refusal, CountRefusal.unknown);
    });

    test('D7: a scan 404 is the single not-available message', () async {
      final g = _gateway(
        resolve: (_) => _resolved('assigned', 'location_node', _loc),
        scan: (_) => throw const ModuleNotAvailableError(moduleId: 'stock'),
      );
      final c = await _ready(g);
      await c.submitScan('LOC');
      await c.submitScan('X');
      expect(c.noticeKey, 'stock.state.notAvailable');
      expect(c.refusal, isNull);
    });

    test('D8: typed quantity PUT body; bad text is not sent', () async {
      final g = _gateway(other: (_) => _line(1, counted: '12.5'));
      final c = await _ready(g);
      expect(await c.setCount(1, '12.5'), isTrue);
      final put = g.where('PUT', '$_base/lines/1/count').single;
      expect(put.data, {'counted_quantity': '12.5'});
      expect(c.lines.single.countedQuantity, '12.5');
      for (final bad in ['abc', '-1', '1,5', '', ' 1']) {
        expect(await c.setCount(1, bad), isFalse, reason: bad);
      }
      expect(g.where('PUT', '/count'), hasLength(1));
    });

    test('D9: surplus body keys; count_line_exists is a message', () async {
      var refuse = false;
      final g = _gateway(
        other: (c) {
          if (refuse) throw _refuse('count_line_exists');
          return _line(2, counted: '3');
        },
      );
      final c = await _ready(g);
      expect(
        await c.addSurplus(
          locationId: _loc,
          catalogItemId: _item,
          unitRef: _unit,
          quantity: '3',
        ),
        isTrue,
      );
      final body = g.where('POST', '/surplus-lines').single.data as Map;
      expect(body.keys.toSet(), {
        'location_id',
        'catalog_item_id',
        'unit_ref',
        'counted_quantity',
      });
      expect(body['counted_quantity'], '3');
      expect(body.containsKey('responsible_employee_id'), isFalse);
      expect(c.lines.map((l) => l.lineNo), [1, 2]);
      refuse = true;
      await c.addSurplus(
        locationId: _loc,
        catalogItemId: _item,
        unitRef: _unit,
        catalogLotId: _lot,
        quantity: '1.5',
      );
      expect(c.refusal, CountRefusal.countLineExists);
      expect(
        (g.where('POST', '/surplus-lines').last.data as Map)['catalog_lot_id'],
        _lot,
      );
      // Invalid ids or quantity are not sent.
      expect(
        await c.addSurplus(
          locationId: _loc,
          catalogItemId: 'nope',
          unitRef: _unit,
          quantity: '1',
        ),
        isFalse,
      );
      expect(g.where('POST', '/surplus-lines'), hasLength(2));
    });

    group('D9b: surplus prefill', () {
      Future<CountDetailController> refused(StockHandler resolve) async {
        var step = 0;
        final g = _gateway(
          resolve: (c) {
            step++;
            if (step == 1) return _resolved('assigned', 'location_node', _loc);
            return resolve(c);
          },
          scan: (_) => throw _refuse('scan_no_line'),
        );
        final c = await _ready(g);
        await c.submitScan('LOC');
        await c.submitScan('CODE ');
        expect(c.canSurplus, isTrue);
        return c;
      }

      test(
        'item code gives the item id and the unit of a loaded line',
        () async {
          final c = await refused(
            (_) => _resolved('assigned', 'catalog_item', _item),
          );
          final d = await c.prepareSurplus();
          expect(d.locationId, _loc);
          expect(d.catalogItemId, _item);
          expect(d.unitRef, _unit);
          expect(d.codeNotUsable, isFalse);
        },
      );

      test(
        'lot code gives the lot id; item and unit from a lot line',
        () async {
          final g = _gateway();
          g.handler = (c) {
            if (c.path.endsWith('/codes/resolve')) {
              return g.where('POST', '/codes/resolve').length == 1
                  ? _resolved('assigned', 'location_node', _loc)
                  : _resolved('assigned', 'catalog_lot', _lot);
            }
            if (c.path == _base) return _order('counting');
            if (c.path == '$_base/lines') {
              return c.query?['cursor'] == 'p2'
                  ? _page([_line(2, lot: _lot, item: _item)])
                  : _page([_line(1, item: 'other')], 'p2');
            }
            throw _refuse('scan_no_line');
          };
          final c = await _ready(g);
          await c.submitScan('LOC');
          await c.submitScan('LOTCODE');
          final d = await c.prepareSurplus();
          expect(d.catalogLotId, _lot);
          expect(d.catalogItemId, _item);
          expect(d.unitRef, _unit);
        },
      );

      test(
        'unknown or place codes leave the ids empty with a message',
        () async {
          final c1 = await refused(
            (_) => throw const ModuleNotAvailableError(moduleId: 'codes'),
          );
          var d = await c1.prepareSurplus();
          expect(d.codeNotUsable, isTrue);
          expect(d.catalogItemId, isEmpty);
          final c2 = await refused(
            (_) => _resolved('assigned', 'location_node', _loc),
          );
          d = await c2.prepareSurplus();
          expect(d.codeNotUsable, isTrue);
          expect(d.unitRef, isEmpty);
        },
      );
    });

    test('D10: lines follow next_cursor; entries in server order', () async {
      final g = FakePutCapableHttpGateway((c) {
        if (c.path == _base) return _order('counting');
        if (c.path.endsWith('/lines')) {
          return c.query?['cursor'] == 'p2'
              ? _page([_line(2)])
              : _page([_line(1, counted: '1.250')], 'p2');
        }
        return _page([
          {'entry_no': 1, 'line_no': 1, 'quantity_after': '1.250'},
          {'entry_no': 2, 'line_no': 1, 'quantity_after': '2'},
        ]);
      });
      final c = await _ready(g);
      expect(c.lines.single.countedQuantity, '1.250');
      await c.loadMoreLines();
      expect(c.lines.map((l) => l.lineNo), [1, 2]);
      await c.loadEntries();
      expect(c.entries.map((e) => e.entryNo), [1, 2]);
    });

    test('D11: camera refused leaves typing working', () async {
      final g = _gateway(
        resolve: (_) => _resolved('assigned', 'location_node', _loc),
      );
      final c = await _ready(g);
      await c.startScanning();
      source.controller.add(const ScanPermissionRefused());
      await Future<void>.delayed(Duration.zero);
      expect(c.cameraRefused, isTrue);
      await c.submitScan('LOC');
      expect(c.placeId, _loc);
    });

    test('403 and 429 of an action use the renderer states', () async {
      Object? err = const ForbiddenError();
      final g = _gateway(
        resolve: (_) => _resolved('assigned', 'location_node', _loc),
        scan: (_) => throw err! as ApiError,
      );
      final c = await _ready(g);
      await c.submitScan('LOC');
      await c.submitScan('X');
      expect(c.failure, isA<RendererPermissionDenied<Object?>>());
      err = const BackpressureError(retryAfterSeconds: 2);
      await c.submitScan('X');
      expect(c.failure, isA<RendererBackpressure<Object?>>());
    });
  });

  // PWA M4 S6: the camera states of the count controller.
  group('camera', () {
    test('S6a: unavailable sets its own flag, not the refusal', () async {
      final c = await _ready(_gateway());
      await c.startScanning();
      expect(c.scanning, isTrue);
      await c.onEvent(const ScanCameraUnavailable());
      expect(c.cameraUnavailable, isTrue);
      expect(c.cameraRefused, isFalse);
      expect(c.scanning, isFalse);
      expect(c.cameraPhase, CameraPhase.unavailable);
      await c.onEvent(const ScanPermissionRefused());
      expect(c.cameraPhase, CameraPhase.refused);
    });

    test(
      'S6b: prepare waits for a tap on web, starts at once on native',
      () async {
        source.needsUserTap = true;
        final web = await _ready(_gateway());
        await web.prepare();
        expect(source.starts, 0);
        expect(web.awaitingTap, isTrue);
        expect(web.cameraPhase, CameraPhase.awaitingTap);
        await web.startScanning();
        await web.startScanning(); // a double tap starts once
        expect(source.starts, 1);
        expect(web.cameraPhase, isNull);
        expect(web.scanning, isTrue);

        source = FakeScanSource();
        final native = await _ready(_gateway());
        await native.prepare();
        expect(source.starts, 1);
        expect(native.awaitingTap, isFalse);
      },
    );

    test('S6c: scan again clears unavailable, never a refusal', () async {
      final c = await _ready(_gateway());
      await c.startScanning();
      await c.onEvent(const ScanCameraUnavailable());
      await c.scanAgain();
      expect(c.cameraUnavailable, isFalse);
      expect(c.scanning, isTrue);
      expect(source.starts, 2);
      await c.onEvent(const ScanPermissionRefused());
      await c.scanAgain();
      expect(c.cameraPhase, CameraPhase.refused);
      expect(source.starts, 2);
    });
  });
}
