import 'package:go_router/go_router.dart';

import 'documents/document_form_screen.dart';
import 'documents/document_kinds.dart';
import 'documents/documents_list_screen.dart';
import 'count_detail_screen.dart';
import 'count_list_screen.dart';
import 'stock_home_screen.dart';

const String kStockHomePath = '/stock';

/// The routes of the `stock` module; registered only when the tenant has the
/// module installed (see `kFeatureRegistry` in `navigation_bootstrap.dart`).
/// `new/:kind` is declared before `:id` so `new` is never read as an id.
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
  GoRoute(
    path: kStockDocumentsPath,
    builder: (context, state) => const DocumentsListScreen(),
  ),
  GoRoute(
    path: '$kStockDocumentsPath/new/:kind',
    builder: (context, state) => DocumentFormScreen(
      kind: DocKind.fromWire(state.pathParameters['kind']),
    ),
  ),
  GoRoute(
    path: '$kStockDocumentsPath/queued/:localId',
    builder: (context, state) =>
        DocumentFormScreen(queuedId: state.pathParameters['localId']),
  ),
  GoRoute(
    path: '$kStockDocumentsPath/:id',
    builder: (context, state) =>
        DocumentFormScreen(id: state.pathParameters['id']),
  ),
];
