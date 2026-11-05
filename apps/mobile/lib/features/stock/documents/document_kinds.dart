/// The six movement kinds the phone drafts (D3b, REQ-746) and, per kind, the
/// header fields in the server's key names. The key sets are copied from
/// `lib/letflow/modules/stock/documents/kinds.ex` and pinned against it by
/// `document_model_test.dart`. Pure Dart: no Flutter import.
library;

enum DocKind {
  receipt('receipt'),
  issue('issue'),
  writeOff('write_off'),
  transfer('transfer'),
  handOver('hand_over'),
  returnDoc('return');

  const DocKind(this.wire);

  final String wire;

  static DocKind? fromWire(Object? value) {
    for (final kind in DocKind.values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }

  bool get isTwoSide =>
      this == transfer || this == handOver || this == returnDoc;
}

/// Which side of a two-side movement a field belongs to.
enum Side { single, from, to }

enum FieldInput { pick, text, date, reason }

class HeaderField {
  const HeaderField(
    this.key,
    this.input, {
    this.entity,
    this.side = Side.single,
    this.required = false,
  });

  final String key;
  final FieldInput input;

  /// The entity type a picker lists (`pick` only).
  final String? entity;
  final Side side;
  final bool required;

  bool get isLocation => entity == 'location_node';
}

const _unit = 'org_unit';
const _place = 'location_node';
const _person = 'org_employee';

List<HeaderField> _oneSide(List<HeaderField> extra) => [
  const HeaderField(
    'org_unit_id',
    FieldInput.pick,
    entity: _unit,
    required: true,
  ),
  const HeaderField(
    'location_id',
    FieldInput.pick,
    entity: _place,
    required: true,
  ),
  const HeaderField(
    'responsible_id',
    FieldInput.pick,
    entity: _person,
    required: true,
  ),
  ...extra,
];

List<HeaderField> _twoSide({required bool isReturn}) => [
  HeaderField(
    isReturn ? 'from_org_unit_id' : 'org_unit_id',
    FieldInput.pick,
    entity: _unit,
    side: Side.from,
    required: true,
  ),
  const HeaderField(
    'from_location_id',
    FieldInput.pick,
    entity: _place,
    side: Side.from,
    required: true,
  ),
  const HeaderField(
    'from_responsible_id',
    FieldInput.pick,
    entity: _person,
    side: Side.from,
    required: true,
  ),
  HeaderField(
    isReturn ? 'org_unit_id' : 'to_org_unit_id',
    FieldInput.pick,
    entity: _unit,
    side: Side.to,
    required: true,
  ),
  const HeaderField(
    'to_location_id',
    FieldInput.pick,
    entity: _place,
    side: Side.to,
    required: true,
  ),
  const HeaderField(
    'to_responsible_id',
    FieldInput.pick,
    entity: _person,
    side: Side.to,
    required: true,
  ),
  const HeaderField('note', FieldInput.text),
];

const _note = HeaderField('note', FieldInput.text);
const _reasonText = HeaderField('reason_text', FieldInput.text);

class DocumentKindSpec {
  const DocumentKindSpec(this.kind, this.fields);

  final DocKind kind;
  final List<HeaderField> fields;

  /// Every header key the body may carry, `event_time` included.
  Set<String> get headerKeys => {'event_time', ...fields.map((f) => f.key)};

  /// Keys the server requires (`required:` of `kinds.ex`).
  Set<String> get requiredKeys => {
    'event_time',
    ...fields.where((f) => f.required).map((f) => f.key),
  };

  bool get hasPrice => kind == DocKind.receipt;
  bool get isTwoSide => kind.isTwoSide;

  List<HeaderField> sideFields(Side side) =>
      fields.where((f) => f.side == side).toList();
}

final Map<DocKind, DocumentKindSpec> documentKindSpecs = {
  DocKind.receipt: DocumentKindSpec(
    DocKind.receipt,
    _oneSide([
      const HeaderField(
        'counterparty_id',
        FieldInput.pick,
        entity: 'catalog_counterparty',
      ),
      const HeaderField('supplier_document_ref', FieldInput.text),
      const HeaderField('received_on', FieldInput.date),
      _note,
    ]),
  ),
  DocKind.issue: DocumentKindSpec(
    DocKind.issue,
    _oneSide([_reasonText, _note]),
  ),
  DocKind.writeOff: DocumentKindSpec(
    DocKind.writeOff,
    _oneSide([
      const HeaderField('reason_code', FieldInput.reason, required: true),
      _reasonText,
      _note,
    ]),
  ),
  DocKind.transfer: DocumentKindSpec(
    DocKind.transfer,
    _twoSide(isReturn: false),
  ),
  DocKind.handOver: DocumentKindSpec(
    DocKind.handOver,
    _twoSide(isReturn: false),
  ),
  DocKind.returnDoc: DocumentKindSpec(
    DocKind.returnDoc,
    _twoSide(isReturn: true),
  ),
};

const List<String> kWriteOffReasons = ['lost', 'damaged', 'used_up', 'other'];
