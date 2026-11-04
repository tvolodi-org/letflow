// REQ-732 criterion 1: the codes module is declared, routed only when
// installed, and reachable from the tenant home only then.
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

import '../../support/fake_http_gateway.dart';
import '../../support/load_test_catalogue.dart';

const _codes = InstalledModule(moduleId: 'codes', version: '1.0.0');

void main() {
  setUpAll(loadTestMessageCatalogue);

  test('C1a: manifest declares codes with no dependencies', () {
    final manifest =
        jsonDecode(File('lib/features/module_manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    final codes = (manifest['features'] as Map)['codes'] as Map;
    expect(codes['depends_on'], isEmpty);
  });

  test('C1b: buildRouteTable with codes installed returns the scan route', () {
    final paths = buildRouteTable(const [
      _codes,
    ]).whereType<GoRoute>().map((r) => r.path).toList();
    expect(paths, [kCodesScanPath]);
    expect(kCodesScanRoutePath, kCodesScanPath);
  });

  test('C1c: without codes installed there is no route', () {
    expect(buildRouteTable(const []), isEmpty);
    expect(
      buildRouteTable(const [InstalledModule(moduleId: 'x', version: '1')]),
      isEmpty,
    );
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

  testWidgets('C1d: home shows the scan entry when codes is installed', (
    tester,
  ) async {
    await pumpHome(tester, const [_codes]);
    expect(find.byKey(const Key('tenant-home-codes-entry')), findsOneWidget);
    expect(find.byKey(const Key('tenant-home-empty')), findsOneWidget);
  });

  testWidgets('C1e: home hides the scan entry when codes is not installed', (
    tester,
  ) async {
    await pumpHome(tester, const []);
    expect(find.byKey(const Key('tenant-home-codes-entry')), findsNothing);
  });
}
