/// Drives the My maintenance orders list (REQ-900): the caller's task inbox,
/// page by page, narrowed to pending `maintenance_work` tasks, each with the
/// order facts read from its instance. Online only: nothing is cached or
/// queued (REQ-893 open point O3).
library;

import 'package:flutter/foundation.dart';

import '../../api/api_client.dart' show HttpGateway;
import '../../api/api_error.dart';
import '../../renderers/renderer_state.dart';

const String kMaintenanceWorkNodeId = 'maintenance_work';
const int kInboxPageSize = 200;
const int kInboxMaxPages = 5;

@immutable
class WorkOrderRow {
  const WorkOrderRow({
    required this.taskId,
    required this.instanceId,
    required this.createdAt,
    this.orderNumber = '',
    this.inventoryNumber = '',
    this.assetName = '',
    this.urgency = '',
    this.description = '',
  });

  final String taskId;
  final String instanceId;
  final DateTime createdAt;
  final String orderNumber;
  final String inventoryNumber;
  final String assetName;
  final String urgency;
  final String description;

  bool get isUrgent => urgency == 'urgent';
}

@immutable
class WorkOrderList {
  const WorkOrderList({required this.rows, required this.cut});
  final List<WorkOrderRow> rows;

  /// More inbox pages exist than the five read.
  final bool cut;
}

String _text(Object? v) => v is String ? v : (v == null ? '' : '$v');

/// Urgent first, then oldest first.
int compareWorkOrders(WorkOrderRow a, WorkOrderRow b) {
  if (a.isUrgent != b.isUrgent) return a.isUrgent ? -1 : 1;
  return a.createdAt.compareTo(b.createdAt);
}

class WorkOrdersController extends ChangeNotifier {
  WorkOrdersController(this.client);

  final HttpGateway client;

  RendererState<WorkOrderList> state = const RendererLoading();
  bool _disposed = false;
  int _generation = 0;

  Future<void> load() async {
    final generation = ++_generation;
    state = const RendererLoading();
    _notify();
    RendererState<WorkOrderList> next;
    try {
      next = RendererContent(data: await _read());
    } on ApiError catch (e) {
      next = rendererStateForError(e);
    } on FormatException {
      next = const RendererFetchFailure();
    } on TypeError {
      next = const RendererFetchFailure();
    }
    if (_disposed || generation != _generation) return;
    state = next;
    _notify();
  }

  Future<WorkOrderList> _read() async {
    final tasks = <Map<String, dynamic>>[];
    String? cursor;
    var cut = false;
    for (var page = 1; page <= kInboxMaxPages; page++) {
      final r = await client.get(
        '/api/v1/tasks/inbox',
        queryParameters: {'page_size': kInboxPageSize, 'cursor': ?cursor},
      );
      final body = r.data as Map<String, dynamic>;
      for (final raw in (body['items'] as List? ?? const [])) {
        final t = raw as Map<String, dynamic>;
        if (t['node_id'] == kMaintenanceWorkNodeId &&
            t['status'] == 'PENDING' &&
            t['id'] is String &&
            t['instance_id'] is String) {
          tasks.add(t);
        }
      }
      cursor = body['next_cursor'] as String?;
      if (cursor == null) break;
      if (page == kInboxMaxPages) cut = true;
    }
    final rows = <WorkOrderRow>[];
    for (final t in tasks) {
      final instanceId = t['instance_id'] as String;
      final r = await client.get(
        '/api/v1/instances/${Uri.encodeComponent(instanceId)}',
      );
      final vars =
          ((r.data as Map<String, dynamic>)['variables'] as Map?) ?? const {};
      rows.add(
        WorkOrderRow(
          taskId: t['id'] as String,
          instanceId: instanceId,
          createdAt:
              DateTime.tryParse(_text(t['created_at'])) ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          orderNumber: _text(vars['maintenance_order_number']),
          inventoryNumber: _text(vars['asset_inventory_number']),
          assetName: _text(vars['asset_name']),
          urgency: _text(vars['urgency']),
          description: _text(vars['description']),
        ),
      );
    }
    rows.sort(compareWorkOrders);
    return WorkOrderList(rows: rows, cut: cut);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
