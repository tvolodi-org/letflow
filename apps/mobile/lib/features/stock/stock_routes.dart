import 'package:go_router/go_router.dart';

import 'count_detail_screen.dart';
import 'count_list_screen.dart';
import 'stock_home_screen.dart';

const String kStockHomePath = '/stock';

/// The routes of the `stock` module; registered only when the tenant has the
/// module installed (see `kFeatureRegistry` in `navigation_bootstrap.dart`).
List<RouteBase> stockRoutes() => [
  GoRoute(
    path: kStockHomePath,
    builder: (context, state) => const StockHomeScreen(),
    routes: [
      GoRoute(
        path: 'counts',
        builder: (context, state) => const CountListScreen(),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) =>
                CountDetailScreen(countId: state.pathParameters['id']!),
          ),
        ],
      ),
    ],
  ),
];
