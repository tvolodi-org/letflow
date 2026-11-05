/// Calls of the stock document routes the phone uses. There is deliberately
/// no method for `/post`, `/check`, `/reverse` or `/cancel`: the phone never
/// posts.
library;

import '../../../api/api_client.dart';
import 'document_draft.dart';
import 'document_kinds.dart';

const String kStockDocumentsApi = '/api/v1/modules/stock/documents';

class DocSummary {
  const DocSummary({
    required this.id,
    required this.kind,
    required this.state,
    this.number,
    this.eventTime,
  });

  final String id;
  final String kind;
  final String state;
  final String? number;
  final String? eventTime;
}

class DocPage {
  const DocPage({required this.rows, this.nextCursor});

  final List<DocSummary> rows;
  final String? nextCursor;
}

class StockDocumentsApi {
  StockDocumentsApi(this._client);

  final WriteCapableHttpGateway _client;

  Future<DocPage> list({DocKind? kind, String? cursor}) async {
    final response = await _client.get(
      kStockDocumentsApi,
      queryParameters: {
        'state': 'draft',
        'kind': ?kind?.wire,
        'cursor': ?cursor,
      },
    );
    final body = response.data;
    if (body is! Map || body['rows'] is! List) {
      throw const MalformedDocumentAnswer();
    }
    final rows = <DocSummary>[];
    for (final raw in body['rows'] as List) {
      if (raw is! Map || raw['id'] is! String) {
        throw const MalformedDocumentAnswer();
      }
      String? text(Object? v) => v is String ? v : null;
      rows.add(
        DocSummary(
          id: raw['id'] as String,
          kind: text(raw['kind']) ?? '',
          state: text(raw['state']) ?? '',
          number: text(raw['number']),
          eventTime: text(raw['event_time']),
        ),
      );
    }
    final next = body['next_cursor'];
    return DocPage(rows: rows, nextCursor: next is String ? next : null);
  }

  Future<DocDraft> fetch(String id) async =>
      DocDraft.fromServer((await _client.get(_path(id))).data);

  Future<DocDraft> save(DocDraft draft) async => DocDraft.fromServer(
    (await _client.post(kStockDocumentsApi, data: draft.toBody())).data,
  );

  Future<DocDraft> replace(String id, DocDraft draft) async =>
      DocDraft.fromServer(
        (await _client.put(_path(id), data: draft.toBody())).data,
      );

  Future<void> discard(String id) async {
    await _client.delete(_path(id));
  }

  Future<DocDraft> issue(String id) async =>
      DocDraft.fromServer((await _client.post('${_path(id)}/issue')).data);

  String _path(String id) => '$kStockDocumentsApi/${Uri.encodeComponent(id)}';
}
