/// The stock count routes as the phone uses them (phone-flows.md section 2).
/// Throws `ApiError` on a transport or HTTP failure and
/// `MalformedStockAnswer` on an unreadable 2xx body.
library;

import '../../api/api_client.dart';
import 'count_models.dart';

const String kStockBase = '/api/v1/modules/stock';

class StockCountApi {
  StockCountApi(this._client);

  final PutCapableHttpGateway _client;

  String _count(String id) => '$kStockBase/counts/${Uri.encodeComponent(id)}';

  Future<CountPage<CountOrder>> listCounts({
    required String status,
    String? cursor,
    int limit = 50,
  }) async {
    final r = await _client.get(
      '$kStockBase/counts',
      queryParameters: {'status': status, 'limit': limit, 'cursor': ?cursor},
    );
    return CountPage.fromJson(r.data, CountOrder.fromJson);
  }

  Future<CountOrder> getCount(String id) async =>
      CountOrder.fromJson((await _client.get(_count(id))).data);

  Future<CountOrder> open(String id) async =>
      CountOrder.fromJson((await _client.post('${_count(id)}/open')).data);

  Future<CountOrder> close(String id) async =>
      CountOrder.fromJson((await _client.post('${_count(id)}/close')).data);

  Future<CountPage<CountLine>> lines(String id, {String? cursor}) async {
    final r = await _client.get(
      '${_count(id)}/lines',
      queryParameters: {'limit': 100, 'cursor': ?cursor},
    );
    return CountPage.fromJson(r.data, CountLine.fromJson);
  }

  Future<CountPage<CountEntry>> entries(String id, {String? cursor}) async {
    final r = await _client.get(
      '${_count(id)}/entries',
      queryParameters: {'limit': 100, 'cursor': ?cursor},
    );
    return CountPage.fromJson(r.data, CountEntry.fromJson);
  }

  /// Body is exactly the three keys; [scannedText] goes unchanged.
  Future<ScanAnswer> scan(
    String id, {
    required String scannedText,
    required String locationId,
    required String scanId,
  }) async {
    final r = await _client.post(
      '${_count(id)}/scan',
      data: {
        'scanned_text': scannedText,
        'location_id': locationId,
        'scan_id': scanId,
      },
    );
    return ScanAnswer.fromJson(r.data);
  }

  Future<CountLine> setCount(String id, int lineNo, String quantity) async {
    final r = await _client.put(
      '${_count(id)}/lines/$lineNo/count',
      data: {'counted_quantity': quantity},
    );
    return CountLine.fromJson(r.data);
  }

  /// Keys are sent only when set. `responsible_employee_id` is never sent.
  Future<CountLine> addSurplus(
    String id, {
    required String locationId,
    required String catalogItemId,
    required String unitRef,
    required String countedQuantity,
    String? catalogLotId,
  }) async {
    final r = await _client.post(
      '${_count(id)}/surplus-lines',
      data: {
        'location_id': locationId,
        'catalog_item_id': catalogItemId,
        'unit_ref': unitRef,
        'counted_quantity': countedQuantity,
        if (catalogLotId != null && catalogLotId.isNotEmpty)
          'catalog_lot_id': catalogLotId,
      },
    );
    return CountLine.fromJson(r.data);
  }
}
