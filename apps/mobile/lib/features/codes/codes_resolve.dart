/// `POST /api/v1/modules/codes/resolve` (D1a, REQ-730) as the mobile client
/// sees it. The answer is a flat map: `code_id`, `value`, `kind`, `status`,
/// `target_type`, `target_id`, `assignment_id`; `retired` and
/// `assignment_conflict` answers are 200 with null keys.
library;

import '../../api/api_client.dart';

const String kCodesResolvePath = '/api/v1/modules/codes/resolve';

/// [notKnown] is client-side only: the server answered 404 (unknown code, or
/// an assigned code whose target type this caller may not see).
enum CodeStatus { assigned, notAssigned, retired, assignmentConflict, notKnown }

enum CodeObjectKind { location, item, lot, other }

class CodeResolution {
  const CodeResolution({
    required this.status,
    required this.value,
    this.kind,
    this.targetType,
  });

  final CodeStatus status;
  final String value;
  final String? kind;
  final String? targetType;

  CodeObjectKind get objectKind => switch (targetType) {
    'location_node' => CodeObjectKind.location,
    'catalog_item' => CodeObjectKind.item,
    'catalog_lot' => CodeObjectKind.lot,
    _ => CodeObjectKind.other,
  };
}

/// Thrown for a 200 whose body is not a resolve answer; the controller
/// shows it as a fetch failure, never a crash.
class MalformedResolveAnswer implements Exception {
  const MalformedResolveAnswer();
}

class CodesResolver {
  CodesResolver(this._client);

  final PostCapableHttpGateway _client;

  /// Sends [text] unchanged (no trimming). Throws `ApiError` on a transport
  /// or HTTP failure and [MalformedResolveAnswer] on an unreadable body.
  Future<CodeResolution> resolve(String text) async {
    final response = await _client.post(
      kCodesResolvePath,
      data: {'value': text},
    );
    final body = response.data;
    if (body is! Map) throw const MalformedResolveAnswer();
    final status = switch (body['status']) {
      'assigned' => CodeStatus.assigned,
      'not_assigned' => CodeStatus.notAssigned,
      'retired' => CodeStatus.retired,
      'assignment_conflict' => CodeStatus.assignmentConflict,
      _ => null,
    };
    if (status == null) throw const MalformedResolveAnswer();
    final value = body['value'];
    final kind = body['kind'];
    final targetType = body['target_type'];
    return CodeResolution(
      status: status,
      value: value is String ? value : text,
      kind: kind is String ? kind : null,
      targetType: targetType is String ? targetType : null,
    );
  }
}
