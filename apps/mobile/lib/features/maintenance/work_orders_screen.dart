import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/api_client.dart' show HttpGateway;
import '../../bootstrap/navigation_bootstrap.dart' show apiClientProvider;
import '../../i18n/i18n.dart';
import '../../renderers/renderer_state_view.dart';
import '../../renderers/task/task.dart' show TaskDetailScreen;
import 'work_orders_controller.dart';

/// The gateway the screen reads through: the app's one [ApiClient]. Tests
/// override it with a fake gateway.
final Provider<HttpGateway> maintenanceGatewayProvider = Provider<HttpGateway>(
  (ref) => ref.watch(apiClientProvider),
);

/// Opens the generic task screen for a task id. Overridable in tests.
typedef TaskScreenBuilder = Widget Function(String taskId);

Widget _genericTaskScreen(String taskId) => Scaffold(
  appBar: AppBar(title: Text(tr('maintenance.orders.task'))),
  body: SingleChildScrollView(child: TaskDetailScreen(taskId: taskId)),
);

class WorkOrdersScreen extends ConsumerStatefulWidget {
  const WorkOrdersScreen({super.key, this.taskScreenBuilder});

  final TaskScreenBuilder? taskScreenBuilder;

  @override
  ConsumerState<WorkOrdersScreen> createState() => _WorkOrdersScreenState();
}

class _WorkOrdersScreenState extends ConsumerState<WorkOrdersScreen> {
  late final WorkOrdersController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WorkOrdersController(ref.read(maintenanceGatewayProvider))
      ..addListener(_changed);
    _controller.load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }

  Future<void> _open(WorkOrderRow row) async {
    final build = widget.taskScreenBuilder ?? _genericTaskScreen;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => build(row.taskId)));
    if (mounted) await _controller.load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('maintenance-orders-screen'),
      appBar: AppBar(
        title: Text(tr('maintenance.orders.title')),
        actions: [
          IconButton(
            key: const Key('maintenance-orders-refresh'),
            tooltip: tr('maintenance.orders.refresh'),
            icon: const Icon(Icons.refresh),
            onPressed: _controller.load,
          ),
        ],
      ),
      body: RendererStateView<WorkOrderList>(
        state: _controller.state,
        onRetryBackpressure: _controller.load,
        contentBuilder: (context, list) => _body(list),
      ),
    );
  }

  Widget _body(WorkOrderList list) {
    if (list.rows.isEmpty && !list.cut) {
      return Center(
        key: const Key('maintenance-orders-empty'),
        child: Text(tr('maintenance.orders.empty')),
      );
    }
    return ListView(
      key: const Key('maintenance-orders-list'),
      children: [
        for (final row in list.rows)
          ListTile(
            key: Key('maintenance-order-${row.taskId}'),
            leading: row.isUrgent
                ? Icon(
                    Icons.priority_high,
                    semanticLabel: tr('maintenance.orders.urgent'),
                  )
                : null,
            title: Text(
              '${row.orderNumber} · ${row.inventoryNumber} ${row.assetName}'
                  .trim(),
            ),
            subtitle: row.description.isEmpty ? null : Text(row.description),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(row),
          ),
        if (list.cut)
          Padding(
            key: const Key('maintenance-orders-cut'),
            padding: const EdgeInsets.all(16),
            child: Text(tr('maintenance.orders.cut')),
          ),
      ],
    );
  }
}
