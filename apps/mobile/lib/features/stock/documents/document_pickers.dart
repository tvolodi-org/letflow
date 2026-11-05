/// Master-data pickers of the document form: `POST /api/v1/entities/query`
/// for active, not deleted records, the first 200 (the web limit).
library;

import '../../../api/api_client.dart';

class PickerOption {
  const PickerOption(this.id, this.label, this.fields);

  final String id;
  final String label;
  final Map<String, dynamic> fields;
}

const Map<String, String> _labelField = {
  'org_employee': 'full_name',
  'catalog_lot': 'code',
};

class PickerLoader {
  PickerLoader(this._client);

  final PostCapableHttpGateway _client;

  /// [itemId] narrows `catalog_lot` to one item. Throws `ApiError`.
  Future<List<PickerOption>> load(String entity, {String? itemId}) async {
    final response = await _client.post(
      '/api/v1/entities/query',
      data: {
        'entity_type': entity,
        'filters': [
          {'field': 'active', 'op': 'eq', 'value': true},
          {'field': 'deleted', 'op': 'eq', 'value': false},
          if (itemId != null) {'field': 'item_id', 'op': 'eq', 'value': itemId},
        ],
        'page_size': 200,
      },
    );
    return _parse(entity, response.data);
  }

  /// One record by id; null when the query finds none.
  Future<PickerOption?> loadOne(String entity, String id) async {
    final response = await _client.post(
      '/api/v1/entities/query',
      data: {
        'entity_type': entity,
        'filters': [
          {'field': 'record_id', 'op': 'eq', 'value': id},
        ],
        'page_size': 1,
      },
    );
    final found = _parse(entity, response.data);
    return found.isEmpty ? null : found.first;
  }

  List<PickerOption> _parse(String entity, Object? body) {
    final items = body is Map ? body['items'] : null;
    if (items is! List) return const [];
    final out = <PickerOption>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final id = raw['record_id'];
      if (id is! String) continue;
      final fv = raw['field_values'] is Map
          ? Map<String, dynamic>.from(raw['field_values'] as Map)
          : <String, dynamic>{};
      String? pick(String key) {
        final v = fv[key];
        return v is String && v.isNotEmpty ? v : null;
      }

      final label =
          pick(_labelField[entity] ?? 'name') ??
          pick('name') ??
          pick('code') ??
          id;
      out.add(PickerOption(id, label, fv));
    }
    return out;
  }
}
