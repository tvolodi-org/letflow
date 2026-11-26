import 'package:go_router/go_router.dart';

import 'work_orders_screen.dart';

const String kMaintenanceOrdersPath = '/maintenance/my-orders';

/// The routes of the `maintenance` module; registered only when the tenant
/// has the module installed (see `kFeatureRegistry` in
/// `navigation_bootstrap.dart`).
List<RouteBase> maintenanceRoutes() => [
  GoRoute(
    path: kMaintenanceOrdersPath,
    builder: (context, state) => const WorkOrdersScreen(),
  ),
];
