// D3s: the stock module is declared, routed only when installed, and
// reachable from the tenant home only then.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/tenant_home_screen.dart';
import 'package:letflow/features/codes/codes.dart';
import 'package:letflow/features/stock/stock.dart';
import 'package:letflow/features/stock/stock_home_screen.dart';

import '../../support/fake_http_gateway.dart';
import '../../support/load_test_catalogue.dart';

const _stock = InstalledModule(moduleId: 'stock', version: '1.0.0');
const _codes = InstalledModule(moduleId: 'codes', version: '1.0.0');

void main() {
  setUpAll(loadTestMessageCatalogue);

  test('S1a: manifest declares stock depending on codes', () {
    final manifest =
        jsonDecode(File('lib/features/module_manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    final stock = (manifest['features'] as Map)['stock'] as Map;
    expect(stock['depends_on'], ['codes']);
  });

  test('S1b: stock installed gives the stock routes', () {
    final paths = buildRouteTable(const [
      _stock,
    ]).whereType<GoRoute>().map((r) => r.path).toList();
    expect(paths, [
      kStockHomePath,
      kStockDocumentsPath,
      '$kStockDocumentsPath/new/:kind',
      '$kStockDocumentsPath/:id',
    ]);
    expect(kStockHomeRoutePath, kStockHomePath);
  });

  test('S1c: stock not installed gives no stock route', () {
    expect(buildRouteTable(const []), isEmpty);
    final paths = buildRouteTable(const [
      _codes,
    ]).whereType<GoRoute>().map((r) => r.path).toList();
    expect(paths, [kCodesScanPath]);
  });

  Future<void> pumpHome(WidgetTester tester, List<InstalledModule> mods) async {
    final repo = InMemoryDefinitionCacheRepository();
    final controller = DefinitionHomeController(
      repository: repo,
      syncService: DefinitionSyncService(
        repository: repo,
        client: FakeHttpGateway(),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          definitionHomeControllerProvider.overrideWith((ref) => controller),
          installedModulesProvider.overrideWithValue(mods),
        ],
        child: const MaterialApp(home: TenantHomeScreen()),
      ),
    );
  }

  testWidgets('S1d: home shows the stock entry when installed', (tester) async {
    await pumpHome(tester, const [_stock]);
    expect(find.byKey(const Key('tenant-home-stock-entry')), findsOneWidget);
  });

  testWidgets('S1e: home hides the stock entry when not installed', (
    tester,
  ) async {
    await pumpHome(tester, const [_codes]);
    expect(find.byKey(const Key('tenant-home-stock-entry')), findsNothing);
  });

  testWidgets('S1f: stock screen shows the empty state', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: StockHomeScreen()));
    expect(find.byKey(const Key('stock-home-empty')), findsOneWidget);
    expect(
      find.text('Nothing here yet. Counts and movements will appear here.'),
      findsOneWidget,
    );
  });
}
