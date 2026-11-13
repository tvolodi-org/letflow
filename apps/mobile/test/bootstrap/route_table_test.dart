// AC3: a module absent from installed_modules is guarded by redirect to
// /home — the route exists in the table (all module routes are always
// registered) but the module is not available (REQ-421 design §5.4).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

void main() {
  final registry = <String, List<RouteBase>>{
    'installed-module': [
      GoRoute(
        path: '/installed',
        builder: (context, state) =>
            const Scaffold(body: Text('installed module content')),
      ),
    ],
    'not-installed-module': [
      GoRoute(
        path: '/not-installed',
        builder: (context, state) =>
            const Scaffold(body: Text('should never be reachable')),
      ),
    ],
  };

  test('buildRouteTable adds a route only for an installed module', () {
    final routes = buildRouteTable(const [
      InstalledModule(moduleId: 'installed-module', version: '1.0.0'),
    ], registry: registry);

    final paths = routes.whereType<GoRoute>().map((r) => r.path).toList();
    expect(paths, contains('/installed'));
    expect(paths, isNot(contains('/not-installed')));
  });

  test('buildRouteTable with no installed modules yields no routes', () {
    expect(buildRouteTable(const [], registry: registry), isEmpty);
  });

  group('moduleIdForLocation', () {
    test(
      'returns the module id for a path that matches a registered route',
      () {
        expect(moduleIdForLocation('/installed', registry), 'installed-module');
        expect(
          moduleIdForLocation('/installed/sub', registry),
          'installed-module',
        );
        expect(
          moduleIdForLocation('/not-installed', registry),
          'not-installed-module',
        );
        expect(
          moduleIdForLocation('/not-installed/sub/path', registry),
          'not-installed-module',
        );
      },
    );

    test('returns null for a path with no matching module', () {
      expect(moduleIdForLocation('/home', registry), isNull);
      expect(moduleIdForLocation('/other', registry), isNull);
      expect(moduleIdForLocation('/', registry), isNull);
    });
  });

  testWidgets(
    'navigating to a path whose module is absent from installed_modules'
    ' redirects to /home — never shows the module\'s own content or'
    ' the not-found screen',
    (tester) async {
      // Mirror _buildRouter's production behaviour: register ALL registry
      // routes, then guard uninstalled-module paths via redirect.
      final allRoutes = buildRouteTable(
        registry.keys
            .map((id) => InstalledModule(moduleId: id, version: ''))
            .toList(),
        registry: registry,
      );
      const installed = [
        InstalledModule(moduleId: 'installed-module', version: '1.0.0'),
      ];
      final router = GoRouter(
        initialLocation: '/not-installed',
        redirect: (context, state) {
          final moduleId = moduleIdForLocation(state.matchedLocation, registry);
          if (moduleId != null && !isModuleInstalled(installed, moduleId)) {
            return '/home';
          }
          return null;
        },
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(body: Text('entry')),
          ),
          GoRoute(
            path: '/home',
            builder: (context, state) =>
                const Scaffold(body: Text('home content')),
          ),
          ...allRoutes,
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(find.text('should never be reachable'), findsNothing);
      // The absent module's path is redirected to /home, never the
      // go_router default not-found page.
      expect(find.text('Page Not Found'), findsNothing);
      expect(find.text('home content'), findsOneWidget);
    },
  );

  testWidgets(
    'navigating to an installed module\'s path renders the module\'s content',
    (tester) async {
      final allRoutes = buildRouteTable(
        registry.keys
            .map((id) => InstalledModule(moduleId: id, version: ''))
            .toList(),
        registry: registry,
      );
      const installed = [
        InstalledModule(moduleId: 'installed-module', version: '1.0.0'),
      ];
      final router = GoRouter(
        initialLocation: '/installed',
        redirect: (context, state) {
          final moduleId = moduleIdForLocation(state.matchedLocation, registry);
          if (moduleId != null && !isModuleInstalled(installed, moduleId)) {
            return '/home';
          }
          return null;
        },
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const Scaffold(body: Text('entry')),
          ),
          GoRoute(
            path: '/home',
            builder: (context, state) =>
                const Scaffold(body: Text('home content')),
          ),
          ...allRoutes,
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      expect(find.text('installed module content'), findsOneWidget);
      expect(find.text('home content'), findsNothing);
    },
  );
}
