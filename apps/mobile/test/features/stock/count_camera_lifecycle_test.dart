// Exercise the real ScanSource and mobile_scanner controller; only the device
// platform is fake. Keeping one ProviderScope reproduces normal app navigation.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/features/codes/mobile_scanner_source.dart';
import 'package:letflow/features/codes/scan_screen.dart';
import 'package:letflow/features/codes/scan_source.dart';
import 'package:letflow/features/stock/count_detail_screen.dart';
import 'package:letflow/features/stock/documents/scan_fill_sheet.dart';
import 'package:letflow/features/stock/stock_providers.dart';
import 'package:letflow/features/stock/stock_routes.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../support/fake_put_capable_http_gateway.dart';
import '../../support/load_test_catalogue.dart';

class _Camera extends MobileScannerPlatform {
  int starts = 0;
  int releases = 0;
  MobileScannerErrorCode? failure;
  final captures = StreamController<BarcodeCapture?>.broadcast();

  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox(key: Key('device-preview'));
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    if (failure case final code?) {
      throw MobileScannerException(errorCode: code);
    }
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.unavailable,
      size: Size(640, 480),
    );
  }

  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async => releases++;
}

// Exercise Safari's tap-first path on the VM with the real adapter/controller.
class _TapCameraSource extends MobileScannerSource {
  @override
  bool get needsUserTap => true;
}

void main() {
  setUpAll(loadTestMessageCatalogue);
  late _Camera camera;
  late MobileScannerPlatform original;
  setUp(() {
    original = MobileScannerPlatform.instance;
    camera = _Camera();
    MobileScannerPlatform.instance = camera;
    MobileScannerController.resetPlatformSessionOwner();
  });
  tearDown(() async {
    await camera.captures.close();
    MobileScannerPlatform.instance = original;
    MobileScannerController.resetPlatformSessionOwner();
  });

  Future<void> openCounts(WidgetTester tester) async {
    final gateway = FakePutCapableHttpGateway((c) {
      if (c.path.endsWith('/codes/resolve')) {
        return {
          'status': 'assigned',
          'value': 'LOCATION',
          'target_type': 'location_node',
          'target_id': '11111111-1111-4111-8111-111111111111',
        };
      }
      if (c.path.endsWith('/lines')) {
        return {'rows': <Object>[], 'next_cursor': null};
      }
      return {'id': 'c1', 'status': 'counting', 'number': 'N-7'};
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stockGatewayProvider.overrideWithValue(gateway),
          codesGatewayProvider.overrideWithValue(gateway),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const CountDetailScreen(countId: 'c1'),
                    ),
                  ),
                  child: const Text('Open count'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const CodesScanScreen(),
                    ),
                  ),
                  child: const Text('Scan code'),
                ),
                TextButton(
                  onPressed: () => showScanFill(context),
                  child: const Text('Scan document'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open count'));
    await tester.pumpAndSettle();
    await startCamera(tester, 'stock-count');
  }

  Future<void> detectLocation(WidgetTester tester) async {
    camera.captures.add(
      const BarcodeCapture(barcodes: [Barcode(rawValue: 'LOCATION')]),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('11111111-1111-4111-8111-111111111111'),
      findsOneWidget,
    );
  }

  testWidgets('CC1: reopening a count acquires a fresh working camera', (
    tester,
  ) async {
    await openCounts(tester);
    expect(camera.starts, 1);
    expect(find.byKey(const Key('device-preview')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(camera.releases, 1);
    await tester.tap(find.text('Open count'));
    await tester.pumpAndSettle();
    await startCamera(tester, 'stock-count');
    expect(camera.starts, 2);
    expect(find.byKey(const Key('device-preview')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await detectLocation(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('CC3: codes scan then count uses a working camera', (
    tester,
  ) async {
    await openCounts(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Scan code'));
    await tester.pumpAndSettle();
    await startCamera(tester, 'codes');
    expect(camera.starts, 2);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open count'));
    await tester.pumpAndSettle();
    await startCamera(tester, 'stock-count');
    expect(camera.starts, 3);
    await detectLocation(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('CC4: document scan releases its camera on each dismissal', (
    tester,
  ) async {
    await openCounts(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Scan document'));
      await tester.pumpAndSettle();
      await startCamera(tester, 'stock-doc-scan');
      expect(camera.starts, i + 2);
      expect(find.byKey(const Key('device-preview')), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(camera.releases, i + 2);
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('CC5: phone count route starts only on tap and reopens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final gateway = FakePutCapableHttpGateway((c) {
      if (c.path.endsWith('/counts')) {
        return {
          'rows': [
            {'id': 'c1', 'status': 'counting', 'number': 'N-7'},
          ],
          'next_cursor': null,
        };
      }
      if (c.path.endsWith('/lines')) {
        return {'rows': <Object>[], 'next_cursor': null};
      }
      return {'id': 'c1', 'status': 'counting', 'number': 'N-7'};
    });
    final router = GoRouter(initialLocation: '/stock', routes: stockRoutes());
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          stockGatewayProvider.overrideWithValue(gateway),
          scanSourceProvider.overrideWithValue(_TapCameraSource.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.tap(find.byKey(const Key('stock-home-counts')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const Key('stock-count-c1')));
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        '/stock/counts/c1',
      );
      expect(camera.starts, i);
      expect(find.byKey(const Key('stock-count-camera-intro')), findsOneWidget);
      expect(find.byKey(const Key('device-preview')), findsNothing);
      await tester.tap(find.byKey(const Key('stock-count-camera-start')));
      await tester.pumpAndSettle();
      expect(camera.starts, i + 1);
      expect(find.byKey(const Key('device-preview')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(camera.releases, i + 1);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final entry in {
    MobileScannerErrorCode.permissionDenied: 'refused',
    MobileScannerErrorCode.unsupported: 'unavailable',
  }.entries) {
    testWidgets('CC2: ${entry.value} shows a message and typed fallback', (
      tester,
    ) async {
      camera.failure = entry.key;
      await openCounts(tester);
      expect(camera.starts, 1);
      final message = find.byKey(Key('stock-count-camera-${entry.value}'));
      expect(message, findsOneWidget);
      expect(
        tester.widget<Text>(message).data,
        startsWith(
          entry.value == 'refused'
              ? 'Camera access was refused.'
              : 'The camera cannot be used here:',
        ),
      );
      expect(find.byKey(const Key('stock-typed')), findsOneWidget);
      expect(find.byKey(const Key('device-preview')), findsNothing);
      await tester.enterText(find.byKey(const Key('stock-typed')), 'LOCATION');
      await tester.tap(find.byKey(const Key('stock-send')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('11111111-1111-4111-8111-111111111111'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}

// Web-like sources wait for the user's tap; native starts automatically.
Future<void> startCamera(WidgetTester tester, String prefix) async {
  final start = find.byKey(Key('$prefix-camera-start'));
  if (start.evaluate().isNotEmpty) {
    await tester.tap(start);
    await tester.pumpAndSettle();
  }
}
