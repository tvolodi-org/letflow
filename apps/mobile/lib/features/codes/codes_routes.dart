import 'package:go_router/go_router.dart';

import 'scan_screen.dart';

const String kCodesScanPath = '/codes/scan';

/// The routes of the `codes` module; registered only when the tenant has the
/// module installed (see `kFeatureRegistry` in `navigation_bootstrap.dart`).
List<RouteBase> codesRoutes() => [
  GoRoute(
    path: kCodesScanPath,
    builder: (context, state) => const CodesScanScreen(),
  ),
];
