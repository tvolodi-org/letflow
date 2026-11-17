/// REQ-840 (decision 0090, rule 6): the advisory "The balance will become
/// negative" warning of the stock document form. Reads only: the posting rule
/// (`GET /posting-rules`), the caller's permissions (`GET /me/access`) and the
/// on-hand of the keys the document lowers (`GET /balances`). The server stays
/// the authority; a warning never blocks Save or Issue. Any failure (offline,
/// refusal, malformed answer) means no warning.
library;

import '../../../api/api_client.dart';
import 'document_draft.dart';
import 'document_kinds.dart';

const String kStockPostingRulesPath = '/api/v1/modules/stock/posting-rules';
const String kStockBalancesPath = '/api/v1/modules/stock/balances';
const String kMeAccessPath = '/api/v1/me/access';

/// One balance row as the warning needs it.
class BalanceRow {
  const BalanceRow({
    required this.sku,
    required this.location,
    required this.orgUnit,
    required this.responsible,
    required this.lot,
    required this.quantity,
  });

  final String sku;
  final String location;
  final String orgUnit;
  final String responsible;
  final String lot;

  /// Scaled by 10^9 (the server's nine decimals).
  final BigInt quantity;

  String get key => balanceKey(sku, location, orgUnit, responsible, lot);
}

String balanceKey(
  String sku,
  String location,
  String orgUnit,
  String responsible,
  String lot,
) => [sku, location, orgUnit, responsible, lot].join('\u0000');

/// A decimal text (`-2.000000000`, `7`, `0.5`) as an integer of 10^-9 units.
/// Null when it is not a plain decimal.
BigInt? scaledDecimal(String text) {
  final m = RegExp(r'^(-)?(\d+)(?:\.(\d{1,9}))?$').firstMatch(text.trim());
  if (m == null) return null;
  final fraction = (m.group(3) ?? '').padRight(9, '0');
  final value = BigInt.parse('${m.group(2)}$fraction');
  return m.group(1) == null ? value : -value;
}

/// The balance key fields of the side a document takes stock from, as header
/// keys: `location`, `org_unit`, `responsible`. Null for a receipt.
Map<String, String>? fromSideKeys(DocKind kind) {
  if (kind == DocKind.receipt) return null;
  final spec = documentKindSpecs[kind]!;
  final fields = spec.isTwoSide
      ? spec.sideFields(Side.from)
      : spec.sideFields(Side.single);
  String? find(String suffix) {
    for (final f in fields) {
      if (f.key.endsWith(suffix)) return f.key;
    }
    return null;
  }

  final location = find('location_id');
  final orgUnit = find('org_unit_id');
  final responsible = find('responsible_id');
  if (location == null || orgUnit == null || responsible == null) return null;
  return {
    'location': location,
    'org_unit': orgUnit,
    'responsible': responsible,
  };
}

/// One lowered key of a draft: the key text, its sku and location (the read
/// filters) and the indexes of the lines that lower it.
class LoweredKey {
  LoweredKey(this.key, this.sku, this.location);

  final String key;
  final String sku;
  final String location;
  final List<int> lines = [];
  BigInt total = BigInt.zero;
}

/// The keys the draft's lines lower. Lines with no item, no valid quantity or
/// no sending location are left out (nothing to judge yet).
List<LoweredKey> loweredKeys(DocDraft draft) {
  final keys = fromSideKeys(draft.kind);
  if (keys == null) return const [];
  final location = draft.value(keys['location']!);
  if (location.isEmpty) return const [];
  final orgUnit = draft.value(keys['org_unit']!);
  final responsible = draft.value(keys['responsible']!);
  final byKey = <String, LoweredKey>{};
  for (var i = 0; i < draft.lines.length; i++) {
    final line = draft.lines[i];
    final normalized = normalizeQuantity(line.quantity);
    final quantity = normalized == null ? null : scaledDecimal(normalized);
    if (line.item.isEmpty || quantity == null) continue;
    final key = balanceKey(line.item, location, orgUnit, responsible, line.lot);
    final entry = byKey.putIfAbsent(
      key,
      () => LoweredKey(key, line.item, location),
    );
    entry.lines.add(i);
    entry.total += quantity;
  }
  return byKey.values.toList();
}

/// The line indexes that would take a balance below zero: the sum of the
/// document's quantities on a key is greater than its on-hand (absent = 0).
Set<int> negativeLines(List<LoweredKey> keys, Map<String, BigInt> onHand) {
  final out = <int>{};
  for (final k in keys) {
    if (k.total > (onHand[k.key] ?? BigInt.zero)) out.addAll(k.lines);
  }
  return out;
}

/// The three reads. Throws on any failure; the caller turns that into "no
/// warning".
class NegativeBalanceApi {
  NegativeBalanceApi(this._client);

  final HttpGateway _client;

  Future<bool> holdsStockRead() async {
    final body = (await _client.get(kMeAccessPath)).data;
    if (body is! Map || body['permissions'] is! List) return false;
    return (body['permissions'] as List).contains('StockRead');
  }

  Future<bool> negativeAllowed() async {
    final body = (await _client.get(kStockPostingRulesPath)).data;
    return body is Map && body['negative_balance'] == 'allowed';
  }

  /// The rows of one item at one place (every unit, lot, responsible), all
  /// pages up to a bound.
  Future<List<BalanceRow>> balances(String sku, String location) async {
    final rows = <BalanceRow>[];
    String? cursor;
    for (var page = 0; page < 20; page++) {
      final body = (await _client.get(
        kStockBalancesPath,
        queryParameters: {'sku': sku, 'location': location, 'cursor': ?cursor},
      )).data;
      if (body is! Map || body['rows'] is! List) {
        throw const MalformedDocumentAnswer();
      }
      for (final raw in body['rows'] as List) {
        if (raw is! Map) throw const MalformedDocumentAnswer();
        String text(Object? v) => v is String ? v : '';
        final q = raw['quantity'];
        final quantity = q is String ? scaledDecimal(q) : null;
        if (quantity == null) throw const MalformedDocumentAnswer();
        rows.add(
          BalanceRow(
            sku: text(raw['sku']),
            location: text(raw['location']),
            orgUnit: text(raw['org_unit']),
            responsible: text(raw['responsible']),
            lot: text(raw['lot']),
            quantity: quantity,
          ),
        );
      }
      final next = body['next_cursor'];
      if (next is! String) return rows;
      cursor = next;
    }
    throw const MalformedDocumentAnswer();
  }
}

/// Decides, for a draft, which lines get the warning. Keeps the gate answer
/// (permission and posting rule) once it is known and the balance rows of an
/// item and place for the life of the form.
class NegativeBalanceCheck {
  NegativeBalanceCheck(this.api);

  final NegativeBalanceApi api;
  bool? _gate;
  final Map<String, List<BalanceRow>> _rows = {};

  /// Empty on any failure. Never throws.
  Future<Set<int>> evaluate(DocDraft draft) async {
    try {
      final keys = loweredKeys(draft);
      if (keys.isEmpty) return const {};
      _gate ??= await api.holdsStockRead() && await api.negativeAllowed();
      if (_gate != true) return const {};
      final onHand = <String, BigInt>{};
      for (final k in keys) {
        final rows = _rows['${k.sku}\u0000${k.location}'] ??= await api
            .balances(k.sku, k.location);
        var sum = BigInt.zero;
        for (final r in rows) {
          if (r.key == k.key) sum += r.quantity;
        }
        onHand[k.key] = sum;
      }
      return negativeLines(keys, onHand);
    } on Object {
      return const {};
    }
  }
}
