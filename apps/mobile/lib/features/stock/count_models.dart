/// Wire models of the stock count routes (D3a). Parsers are total: a body of
/// the wrong shape throws [MalformedStockAnswer], shown as a fetch failure,
/// never a crash (INV-8). Quantities stay decimal strings end to end.
library;

import 'package:flutter/foundation.dart';

class MalformedStockAnswer implements Exception {
  const MalformedStockAnswer();
}

String _str(Map<dynamic, dynamic> m, String key) {
  final v = m[key];
  if (v is String) return v;
  throw const MalformedStockAnswer();
}

String? _optStr(Map<dynamic, dynamic> m, String key) {
  final v = m[key];
  return v is String ? v : null;
}

int _int(Map<dynamic, dynamic> m, String key) {
  final v = m[key];
  if (v is int) return v;
  throw const MalformedStockAnswer();
}

Map<dynamic, dynamic> _map(Object? v) {
  if (v is Map) return v;
  throw const MalformedStockAnswer();
}

@immutable
class CountOrder {
  const CountOrder({
    required this.id,
    required this.status,
    this.kind,
    this.plannedStart,
    this.plannedEnd,
    this.note,
    this.number,
    this.locationIds = const [],
  });

  factory CountOrder.fromJson(Object? json) {
    final m = _map(json);
    final locs = m['location_ids'];
    return CountOrder(
      id: _str(m, 'id'),
      status: _str(m, 'status'),
      kind: _optStr(m, 'kind'),
      plannedStart: _optStr(m, 'planned_start'),
      plannedEnd: _optStr(m, 'planned_end'),
      note: _optStr(m, 'note'),
      number: _optStr(m, 'number'),
      locationIds: locs is List ? locs.whereType<String>().toList() : const [],
    );
  }

  final String id;
  final String status;
  final String? kind;
  final String? plannedStart;
  final String? plannedEnd;
  final String? note;
  final String? number;
  final List<String> locationIds;
}

@immutable
class CountLine {
  const CountLine({
    required this.lineNo,
    required this.locationId,
    required this.catalogItemId,
    required this.unitRef,
    this.kind,
    this.catalogLotId,
    this.bookQuantity,
    this.countedQuantity,
  });

  factory CountLine.fromJson(Object? json) {
    final m = _map(json);
    return CountLine(
      lineNo: _int(m, 'line_no'),
      kind: _optStr(m, 'kind'),
      locationId: _str(m, 'location_id'),
      catalogItemId: _str(m, 'catalog_item_id'),
      catalogLotId: _optStr(m, 'catalog_lot_id'),
      unitRef: _str(m, 'unit_ref'),
      bookQuantity: _optStr(m, 'book_quantity'),
      countedQuantity: _optStr(m, 'counted_quantity'),
    );
  }

  final int lineNo;
  final String? kind;
  final String locationId;
  final String catalogItemId;
  final String? catalogLotId;
  final String unitRef;
  final String? bookQuantity;
  final String? countedQuantity;
}

@immutable
class CountEntry {
  const CountEntry({
    required this.entryNo,
    required this.lineNo,
    this.method,
    this.quantityBefore,
    this.quantityAfter,
    this.enteredAt,
  });

  factory CountEntry.fromJson(Object? json) {
    final m = _map(json);
    return CountEntry(
      entryNo: _int(m, 'entry_no'),
      lineNo: _int(m, 'line_no'),
      method: _optStr(m, 'method'),
      quantityBefore: _optStr(m, 'quantity_before'),
      quantityAfter: _optStr(m, 'quantity_after'),
      enteredAt: _optStr(m, 'entered_at'),
    );
  }

  final int entryNo;
  final int lineNo;
  final String? method;
  final String? quantityBefore;
  final String? quantityAfter;
  final String? enteredAt;
}

@immutable
class CountPage<T> {
  const CountPage({required this.rows, this.nextCursor});

  factory CountPage.fromJson(Object? json, T Function(Object?) parse) {
    final m = _map(json);
    final rows = m['rows'];
    if (rows is! List) throw const MalformedStockAnswer();
    final next = m['next_cursor'];
    return CountPage(
      rows: rows.map(parse).toList(),
      nextCursor: next is String ? next : null,
    );
  }

  final List<T> rows;
  final String? nextCursor;
}

/// The answer of `POST /counts/:id/scan`.
sealed class ScanAnswer {
  const ScanAnswer();

  factory ScanAnswer.fromJson(Object? json) {
    final m = _map(json);
    if (m['kind'] == 'location') {
      return ScanLocation(_str(m, 'location_id'));
    }
    return ScanLine(CountLine.fromJson(m), duplicate: m['duplicate'] == true);
  }
}

class ScanLine extends ScanAnswer {
  const ScanLine(this.line, {required this.duplicate});

  final CountLine line;
  final bool duplicate;
}

class ScanLocation extends ScanAnswer {
  const ScanLocation(this.locationId);

  final String locationId;
}
