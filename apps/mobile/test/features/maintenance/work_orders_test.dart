// REQ-900: My maintenance orders on the phone and the PWA.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/tenant_home_screen.dart';
import 'package:letflow/features/maintenance/maintenance.dart';
import 'package:letflow/features/maintenance/work_orders_screen.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

import '../../support/fake_http_gateway.dart' as plain;
import '../../support/fake_write_gateway.dart';
import '../../support/load_test_catalogue.dart';

const _inbox = '/api/v1/tasks/inbox';
const _maint = InstalledModule(moduleId: 'maintenance', version: '1.0.0');
const _stock = InstalledModule(moduleId: 'stock', version: '1.0.0');

late FakeWriteGateway gw;

Map<String, dynamic> _task(
  String id,
  String node, {
  String at = '2026-01-01T00:00:00Z',
  String status = 'PENDING',
}) => {
  'id': id,
  'instance_id': 'i-$id',
  'node_id': node,
  'node_name': node,
  'status': status,
  'created_at': at,
};

void _instance(String id, String number, String urgency, {String? name}) {
  gw.on('GET', '/api/v1/instances/i-$id', [
    {
      'variables': {
        'maintenance_order_number': number,
        'asset_inventory_number': 'INV-$number',
        'asset_name': name ?? 'Pump $number',
        'urgency': urgency,
        'description': 'desc $number',
      },
    },
  ]);
}

Future<void> _pump(WidgetTester tester, {TaskScreenBuilder? builder}) async {
  tester.view.physicalSize = const Size(900, 9000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [maintenanceGatewayProvider.overrideWithValue(gw)],
      child: MaterialApp(home: WorkOrdersScreen(taskScreenBuilder: builder)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadTestMessageCatalogue);
  setUp(() => gw = FakeWriteGateway());

  testWidgets('M1: lists the two maintenance tasks, urgent first', (
    tester,
  ) async {
    gw.on('GET', _inbox, [
      {
        'items': [
          _task('t1', 'maintenance_work', at: '2026-01-01T00:00:00Z'),
          _task('t2', 'other_node'),
          _task('t3', 'maintenance_work', at: '2026-01-02T00:00:00Z'),
        ],
        'next_cursor': null,
      },
    ]);
    _instance('t1', 'MO-1', 'normal');
    _instance('t3', 'MO-3', 'urgent');
    await _pump(tester);
    final tiles = tester.widgetList<ListTile>(find.byType(ListTile)).toList();
    expect(tiles.length, 2);
    expect(tiles[0].key, const Key('maintenance-order-t3'));
    expect(tiles[1].key, const Key('maintenance-order-t1'));
    expect(find.textContaining('MO-3 · INV-MO-3 Pump MO-3'), findsOneWidget);
    expect(find.text('desc MO-1'), findsOneWidget);
    expect(find.byKey(const Key('maintenance-orders-cut')), findsNothing);
    expect(gw.callsTo('GET', '/api/v1/instances/i-t2'), isEmpty);
    expect(gw.callsTo('GET', _inbox).single.query!['page_size'], 200);
  });

  testWidgets('M2: older first inside the same urgency', (tester) async {
    gw.on('GET', _inbox, [
      {
        'items': [
          _task('a', 'maintenance_work', at: '2026-03-01T00:00:00Z'),
          _task('b', 'maintenance_work', at: '2026-02-01T00:00:00Z'),
        ],
      },
    ]);
    _instance('a', 'A', 'low');
    _instance('b', 'B', 'low');
    await _pump(tester);
    final keys = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((t) => t.key)
        .toList();
    expect(keys, [
      const Key('maintenance-order-b'),
      const Key('maintenance-order-a'),
    ]);
  });

  testWidgets('M3: six full pages show the cut note after five', (
    tester,
  ) async {
    gw.on('GET', _inbox, [
      for (var p = 1; p <= 6; p++)
        {
          'items': [_task('p$p', 'maintenance_work')],
          'next_cursor': 'c$p',
        },
    ]);
    for (var p = 1; p <= 6; p++) {
      _instance('p$p', 'P$p', 'normal');
    }
    await _pump(tester);
    expect(gw.callsTo('GET', _inbox).length, 5);
    expect(find.byKey(const Key('maintenance-orders-cut')), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(5));
  });

  testWidgets('M4: tap opens the task screen; the row is gone after refresh', (
    tester,
  ) async {
    gw.on('GET', _inbox, [
      {
        'items': [_task('t1', 'maintenance_work')],
      },
      {'items': <Object>[]},
    ]);
    _instance('t1', 'MO-1', 'normal');
    String? opened;
    await _pump(
      tester,
      builder: (id) {
        opened = id;
        return Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const Key('done'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('done'),
            ),
          ),
        );
      },
    );
    await tester.tap(find.byKey(const Key('maintenance-order-t1')));
    await tester.pumpAndSettle();
    expect(opened, 't1');
    await tester.tap(find.byKey(const Key('done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('maintenance-order-t1')), findsNothing);
    expect(find.byKey(const Key('maintenance-orders-empty')), findsOneWidget);
  });

  testWidgets('M5: no network shows the existing failure state', (
    tester,
  ) async {
    gw.on('GET', _inbox, [const NetworkUnavailableError()]);
    await _pump(tester);
    expect(find.byKey(rendererFetchFailureKey), findsOneWidget);
  });

  test('M6: manifest declares maintenance with no dependency', () {
    final manifest =
        jsonDecode(File('lib/features/module_manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(
      ((manifest['features'] as Map)['maintenance'] as Map)['depends_on'],
      [],
    );
  });

  test('M7: routes only when installed', () {
    expect(
      buildRouteTable(const [
        _maint,
      ]).whereType<GoRoute>().map((r) => r.path).toList(),
      [kMaintenanceOrdersPath],
    );
    expect(
      buildRouteTable(const [_stock]).whereType<GoRoute>().map((r) => r.path),
      isNot(contains(kMaintenanceOrdersPath)),
    );
    expect(kMaintenanceOrdersRoutePath, kMaintenanceOrdersPath);
  });

  Future<void> pumpHome(WidgetTester tester, List<InstalledModule> mods) async {
    final repo = InMemoryDefinitionCacheRepository();
    final controller = DefinitionHomeController(
      repository: repo,
      syncService: DefinitionSyncService(
        repository: repo,
        client: plain.FakeHttpGateway(),
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

  testWidgets('M8: home entry present when installed, absent otherwise', (
    tester,
  ) async {
    await pumpHome(tester, const [_maint]);
    expect(
      find.byKey(const Key('tenant-home-maintenance-entry')),
      findsOneWidget,
    );
    await pumpHome(tester, const [_stock]);
    await tester.pump();
    expect(
      find.byKey(const Key('tenant-home-maintenance-entry')),
      findsNothing,
    );
  });

  test('M9: no platform branch, no offline queue, no definition cache', () {
    final files = Directory(
      'lib/features/maintenance',
    ).listSync(recursive: true).whereType<File>();
    expect(files, isNotEmpty);
    for (final f in files) {
      final s = f.readAsStringSync();
      expect(s.contains('kIsWeb'), isFalse, reason: f.path);
      expect(s.contains('dart.library'), isFalse, reason: f.path);
      expect(s.contains('offline'), isFalse, reason: f.path);
      expect(s.contains('definitions/'), isFalse, reason: f.path);
    }
  });

  test('M10: every label exists in en, ru and kk', () {
    for (final lg in ['en', 'ru', 'kk']) {
      final arb =
          jsonDecode(File('lib/i18n/l10n/app_$lg.arb').readAsStringSync())
              as Map<String, dynamic>;
      for (final k in [
        'home.maintenance.entry',
        'maintenance.orders.title',
        'maintenance.orders.refresh',
        'maintenance.orders.task',
        'maintenance.orders.urgent',
        'maintenance.orders.empty',
        'maintenance.orders.cut',
      ]) {
        expect(arb[k], isA<String>(), reason: '$lg $k');
      }
    }
  });
}
