import 'package:go_router/go_router.dart';

import 'stock_home_screen.dart';

const String kStockHomePath = '/stock';

/// The routes of the `stock` module; registered only when the tenant has the
/// module installed (see `kFeatureRegistry` in `navigation_bootstrap.dart`).
List<RouteBase> stockRoutes() => [
  GoRoute(
    path: kStockHomePath,
    builder: (context, state) => const StockHomeScreen(),
  ),
];
