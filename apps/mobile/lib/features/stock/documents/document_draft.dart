/// A stock document draft as the phone holds it, its exact request body and
/// the checks that only gate the Save button (the server stays the
/// authority). Quantities and prices are strings end to end.
library;

import 'document_kinds.dart';

class MalformedDocumentAnswer implements Exception {
  const MalformedDocumentAnswer();
}

/// `^(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?$`, the server's decimal text.
final RegExp _decimal = RegExp(r'^(0|[1-9][0-9]{0,14})(\.[0-9]{1,9})?$');
final RegExp _dateOnly = RegExp(r'^\d{4}-\d{2}-\d{2}$');

/// One comma becomes a dot; the result must be a server decimal. Null when
/// it is not (`1,000.5` and `abc` are refused). Zero is valid here; the
/// quantity check adds "above zero".
String? normalizeDecimal(String input) {
  final text = input.trim();
  final dots = RegExp(r',').allMatches(text).length;
  if (dots > 1 || (dots == 1 && text.contains('.'))) return null;
  final value = text.replaceFirst(',', '.');
  return _decimal.hasMatch(value) ? value : null;
}

String? normalizeQuantity(String input) {
  final value = normalizeDecimal(input);
  if (value == null || !RegExp(r'[1-9]').hasMatch(value)) return null;
  return value;
}

/// `YYYY-MM-DDTHH:MM:SS+hh:mm` with the device offset (Dart's own
/// `toIso8601String` has no offset for a local time).
String isoWithOffset(DateTime time) {
  String two(int n) => n.abs().toString().padLeft(2, '0');
  final offset = time.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  return '${time.year.toString().padLeft(4, '0')}-${two(time.month)}-'
      '${two(time.day)}T${two(time.hour)}:${two(time.minute)}:'
      '${two(time.second)}$sign${two(minutes ~/ 60)}:${two(minutes % 60)}';
}

class DocLine {
  const DocLine({
    this.item = '',
    this.uom = '',
    this.lot = '',
    this.quantity = '',
    this.unitPrice = '',
    this.lineValue = '',
  });

  final String item;
  final String uom;
  final String lot;
  final String quantity;
  final String unitPrice;
  final String lineValue;

  DocLine copyWith({
    String? item,
    String? uom,
    String? lot,
    String? quantity,
    String? unitPrice,
    String? lineValue,
  }) => DocLine(
    item: item ?? this.item,
    uom: uom ?? this.uom,
    lot: lot ?? this.lot,
    quantity: quantity ?? this.quantity,
    unitPrice: unitPrice ?? this.unitPrice,
    lineValue: lineValue ?? this.lineValue,
  );
}

class DocDraft {
  const DocDraft({
    required this.kind,
    required this.eventTime,
    this.id,
    this.state = 'draft',
    this.number,
    this.header = const {},
    this.lines = const [DocLine()],
  });

  final DocKind kind;
  final String? id;
  final String state;
  final String? number;
  final String eventTime;
  final Map<String, String> header;
  final List<DocLine> lines;

  DocumentKindSpec get spec => documentKindSpecs[kind]!;
  bool get isDraft => state == 'draft';

  String value(String key) => header[key] ?? '';

  DocDraft copyWith({
    String? id,
    String? state,
    Map<String, String>? header,
    List<DocLine>? lines,
  }) => DocDraft(
    kind: kind,
    eventTime: eventTime,
    id: id ?? this.id,
    state: state ?? this.state,
    number: number,
    header: header ?? this.header,
    lines: lines ?? this.lines,
  );

  DocDraft withField(String key, String value) =>
      copyWith(header: {...header, key: value});

  /// Reads the answer of `GET /documents/:id` (its keys are the body keys).
  /// Every header key of the kind and every line is kept, because a PUT
  /// replaces the whole draft.
  factory DocDraft.fromServer(Object? body) {
    if (body is! Map) throw const MalformedDocumentAnswer();
    final kind = DocKind.fromWire(body['kind']);
    final id = body['id'];
    final rawLines = body['lines'];
    if (kind == null || id is! String || rawLines is! List) {
      throw const MalformedDocumentAnswer();
    }
    String text(Object? v) => v is String ? v : '';
    final spec = documentKindSpecs[kind]!;
    final header = <String, String>{
      for (final f in spec.fields)
        if (body[f.key] is String && (body[f.key] as String).isNotEmpty)
          f.key: body[f.key] as String,
    };
    final parsed = <Map>[];
    for (final raw in rawLines) {
      if (raw is! Map) throw const MalformedDocumentAnswer();
      parsed.add(raw);
    }
    parsed.sort(
      (a, b) =>
          ((a['line_no'] as num?) ?? 0).compareTo((b['line_no'] as num?) ?? 0),
    );
    final number = body['number'];
    return DocDraft(
      kind: kind,
      id: id,
      state: text(body['state']).isEmpty ? 'draft' : text(body['state']),
      number: number is String ? number : null,
      eventTime: text(body['event_time']),
      header: header,
      lines: [
        for (final l in parsed)
          DocLine(
            item: text(l['catalog_item_id']),
            uom: text(l['catalog_uom_id']),
            lot: text(l['catalog_lot_id']),
            quantity: text(l['quantity']),
            unitPrice: text(l['unit_price']),
            lineValue: text(l['line_value']),
          ),
      ],
    );
  }

  /// The inverse of [toBody] for a queued body: a new draft (no id) that the
  /// person edits in the normal form. Null when the body is unreadable.
  static DocDraft? fromBody(Map<String, dynamic> body) {
    final kind = DocKind.fromWire(body['kind']);
    final rawLines = body['lines'];
    if (kind == null || rawLines is! List) return null;
    String text(Object? v) => v is String ? v : '';
    final spec = documentKindSpecs[kind]!;
    return DocDraft(
      kind: kind,
      eventTime: text(body['event_time']),
      header: {
        for (final f in spec.fields)
          if (body[f.key] is String && (body[f.key] as String).isNotEmpty)
            f.key: body[f.key] as String,
      },
      lines: [
        for (final l in rawLines.whereType<Map>())
          DocLine(
            item: text(l['catalog_item_id']),
            uom: text(l['catalog_uom_id']),
            lot: text(l['catalog_lot_id']),
            quantity: text(l['quantity']),
            unitPrice: text(l['unit_price']),
            lineValue: text(l['line_value']),
          ),
      ],
    );
  }

  /// The exact body of a create and of a replace: `kind`, `event_time`, the
  /// kind's non-empty header keys and every line. No key outside the kind's
  /// set is ever sent.
  Map<String, dynamic> toBody() {
    final body = <String, dynamic>{'kind': kind.wire, 'event_time': eventTime};
    for (final f in spec.fields) {
      final v = value(f.key);
      if (v.trim().isNotEmpty) body[f.key] = v;
    }
    var n = 0;
    body['lines'] = [
      for (final l in lines)
        {
          'line_no': ++n,
          'catalog_item_id': l.item,
          'catalog_uom_id': l.uom,
          'quantity': normalizeQuantity(l.quantity) ?? l.quantity,
          if (l.lot.isNotEmpty) 'catalog_lot_id': l.lot,
          if (spec.hasPrice && l.unitPrice.isNotEmpty)
            'unit_price': normalizeDecimal(l.unitPrice) ?? l.unitPrice,
          if (spec.hasPrice && l.lineValue.isNotEmpty)
            'line_value': normalizeDecimal(l.lineValue) ?? l.lineValue,
        },
    ];
    return body;
  }

  /// Problems that keep Save disabled: header keys (`header.<key>`,
  /// `sides`), `lines` and `lines.<i>.<field>`.
  Set<String> problems() {
    final out = <String>{};
    for (final key in spec.requiredKeys) {
      if (key == 'event_time') {
        if (eventTime.isEmpty) out.add('header.event_time');
      } else if (value(key).trim().isEmpty) {
        out.add('header.$key');
      }
    }
    if (kind == DocKind.writeOff) {
      final code = value('reason_code');
      if (code.isNotEmpty && !kWriteOffReasons.contains(code)) {
        out.add('header.reason_code');
      }
      if (code == 'other' && value('reason_text').trim().isEmpty) {
        out.add('header.reason_text');
      }
    }
    final received = value('received_on');
    if (received.isNotEmpty && !_dateOnly.hasMatch(received)) {
      out.add('header.received_on');
    }
    if (isTwoSide && _sidesEqual()) out.add('sides');
    if (lines.isEmpty) out.add('lines');
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (l.item.isEmpty || l.uom.isEmpty) out.add('lines.$i.item');
      if (normalizeQuantity(l.quantity) == null) out.add('lines.$i.quantity');
      if (spec.hasPrice) {
        if (l.unitPrice.isNotEmpty && normalizeDecimal(l.unitPrice) == null) {
          out.add('lines.$i.unit_price');
        }
        if (l.lineValue.isNotEmpty && normalizeDecimal(l.lineValue) == null) {
          out.add('lines.$i.line_value');
        }
      }
    }
    return out;
  }

  bool get isSaveable => problems().isEmpty;

  bool get isTwoSide => kind.isTwoSide;

  bool _sidesEqual() {
    List<String> side(Side s) => [
      for (final f
          in spec.sideFields(s).where((f) => f.input == FieldInput.pick))
        value(f.key),
    ];
    final from = side(Side.from);
    final to = side(Side.to);
    return from.every((v) => v.isNotEmpty) &&
        List.generate(from.length, (i) => from[i] == to[i]).every((e) => e);
  }
}
