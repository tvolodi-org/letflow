/// The answer of the stock voice routes (runbook `stock-voice.md`). The parser
/// is total: a wrong shape throws [MalformedStockAnswer]. The quantity stays a
/// string, never a number.
library;

import 'package:flutter/foundation.dart';

import '../count_models.dart';

@immutable
class VoiceItem {
  const VoiceItem({
    required this.id,
    required this.code,
    required this.name,
    required this.baseUnit,
  });

  final String id;
  final String code;
  final String name;
  final String baseUnit;

  String get label => code.isEmpty ? name : '$code - $name';
}

@immutable
class VoicePlace {
  const VoicePlace({required this.id, required this.code, required this.name});

  final String id;
  final String code;
  final String name;

  String get label => '$code $name'.trim();
}

@immutable
class VoiceDraft {
  const VoiceDraft({
    required this.kind,
    required this.items,
    this.location,
    this.toLocation,
    this.quantity,
    this.transcript = '',
    this.notice,
  });

  final String kind;
  final List<VoiceItem> items;
  final VoicePlace? location;
  final VoicePlace? toLocation;
  final String? quantity;
  final String transcript;
  final String? notice;

  bool get modelOff => notice == 'llm_off';

  factory VoiceDraft.fromJson(Object? body) {
    if (body is! Map) throw const MalformedStockAnswer();
    final kind = body['kind'];
    final items = body['items'];
    final quantity = body['quantity'];
    final notice = body['notice'];
    final transcript = body['transcript'];
    if (kind is! String || items is! List) throw const MalformedStockAnswer();
    if (quantity != null && quantity is! String) {
      throw const MalformedStockAnswer();
    }
    if (notice != null && notice is! String) {
      throw const MalformedStockAnswer();
    }
    if (transcript != null && transcript is! String) {
      throw const MalformedStockAnswer();
    }
    return VoiceDraft(
      kind: kind,
      items: [for (final raw in items) _item(raw)],
      location: _place(body['location']),
      toLocation: _place(body['to_location']),
      quantity: quantity as String?,
      transcript: (transcript as String?) ?? '',
      notice: notice as String?,
    );
  }

  static String _text(Object? v) => v is String ? v : '';

  static VoiceItem _item(Object? raw) {
    if (raw is! Map || raw['id'] is! String) {
      throw const MalformedStockAnswer();
    }
    return VoiceItem(
      id: raw['id'] as String,
      code: _text(raw['code']),
      name: _text(raw['name']),
      baseUnit: _text(raw['base_unit']),
    );
  }

  static VoicePlace? _place(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map || raw['id'] is! String) {
      throw const MalformedStockAnswer();
    }
    return VoicePlace(
      id: raw['id'] as String,
      code: _text(raw['code']),
      name: _text(raw['name']),
    );
  }
}
