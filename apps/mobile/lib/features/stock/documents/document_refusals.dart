/// Maps a failed call to the text the form shows. The reason of a refusal
/// selects a catalogue key; an unknown reason, field or side is never echoed.
library;

import '../../../api/api_error.dart';
import '../../../i18n/i18n.dart';

const List<String> kRefusalReasons = [
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
  'unknown_kind',
  'event_time_invalid',
  'lines_count',
  'quantity_invalid',
  'reason_required',
  'reason_too_long',
];

const List<String> kFieldKeys = [
  'org_unit_id',
  'location_id',
  'responsible_id',
  'event_time',
  'counterparty_id',
  'note',
  'supplier_document_ref',
  'received_on',
  'reason_text',
  'reason_code',
  'from_org_unit_id',
  'from_location_id',
  'from_responsible_id',
  'to_org_unit_id',
  'to_location_id',
  'to_responsible_id',
  'catalog_item_id',
  'catalog_uom_id',
  'catalog_lot_id',
  'quantity',
  'unit_price',
  'line_value',
];

/// The message for [error], or null when the error is not a stock refusal
/// (the caller then uses the renderer states: 403, 429, network).
String? refusalMessage(ApiError error) {
  switch (error) {
    case NotFoundError() || ModuleNotAvailableError():
      return tr('stock.doc.error.notFound');
    case ValidationError(
      :final reason,
      :final field,
      :final lineNo,
      :final side,
    ):
      return _compose(reason, field, lineNo, side);
    case ConflictError(:final reason, :final field, :final lineNo, :final side):
      return _compose(reason, field, lineNo, side);
    default:
      return null;
  }
}

String _compose(String? reason, String? field, int? lineNo, String? side) {
  if (reason == null || !kRefusalReasons.contains(reason)) {
    return tr('stock.doc.error.generic');
  }
  var text = tr('stock.doc.error.$reason');
  final fieldLabel = field != null && kFieldKeys.contains(field)
      ? tr('stock.doc.field.$field')
      : '';
  final sideLabel = side == 'from' || side == 'to'
      ? tr('stock.doc.side.$side')
      : '';
  text = text
      .replaceAll('{field}', fieldLabel)
      .replaceAll('{side}', sideLabel)
      .replaceAll(' ()', '');
  final line = lineNo != null
      ? tr('stock.doc.error.line').replaceAll('{line}', '$lineNo')
      : '';
  return line.isEmpty ? text : '$line $text';
}
