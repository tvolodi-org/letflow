// PWA M4 S2/S3: the scan screen and its controller on web (camera only after
// a tap) and the two failure texts (refused, unavailable). Fake camera source,
// scripted gateway; no camera, no network.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/features/codes/codes_resolve.dart';
import 'package:letflow/features/codes/scan_controller.dart';
import 'package:letflow/features/codes/scan_screen.dart';
import 'package:letflow/features/codes/scan_source.dart';

import '../../support/fake_post_capable_http_gateway.dart';
import '../../support/load_test_catalogue.dart';
import 'fakes.dart';

late FakeScanSource source;
late FakePostCapableHttpGateway gateway;

Widget _app() => ProviderScope(
  overrides: [
    scanSourceProvider.overrideWithValue(source),
    codesGatewayProvider.overrideWithValue(gateway),
  ],
  child: const MaterialApp(home: CodesScanScreen()),
);

void main() {
  setUpAll(loadTestMessageCatalogue);
  setUp(() {
    source = FakeScanSource();
    gateway = FakePostCapableHttpGateway();
  });

  group('screen', () {
    testWidgets('S2a: web shows the intro, starts nothing until the tap', (
      tester,
    ) async {
      source.needsUserTap = true;
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(source.starts, 0);
      expect(find.byKey(const Key('codes-camera-intro')), findsOneWidget);
      expect(find.text('Start camera'), findsOneWidget);
      expect(find.byKey(const Key('fake-preview')), findsNothing);
      expect(find.byKey(const Key('codes-scan-again')), findsNothing);
      expect(find.byKey(const Key('codes-typed')), findsOneWidget);
      await tester.tap(find.byKey(const Key('codes-camera-start')));
      await tester.pumpAndSettle();
      expect(source.starts, 1);
      expect(find.byKey(const Key('fake-preview')), findsOneWidget);
      expect(find.byKey(const Key('codes-camera-intro')), findsNothing);
    });

    testWidgets('S2b: a refusal shows how to allow the camera', (tester) async {
      source.needsUserTap = true;
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('codes-camera-start')));
      await tester.pumpAndSettle();
      source.refuse();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('codes-camera-refused')), findsOneWidget);
      expect(find.textContaining('Allow the camera'), findsOneWidget);
      expect(find.byKey(const Key('codes-camera-unavailable')), findsNothing);
      expect(find.byKey(const Key('codes-typed')), findsOneWidget);
      expect(find.byKey(const Key('codes-scan-again')), findsNothing);
    });

    testWidgets('S2c: no camera / insecure page has its own text', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(source.starts, 1); // native: at once, as before
      source.unavailable();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('codes-camera-unavailable')), findsOneWidget);
      expect(find.textContaining('HTTPS'), findsOneWidget);
      expect(find.byKey(const Key('codes-camera-refused')), findsNothing);
      expect(find.byKey(const Key('fake-preview')), findsNothing);
      expect(find.byKey(const Key('codes-typed')), findsOneWidget);
    });
  });

  group('controller', () {
    CodesScanController controller() =>
        CodesScanController(resolver: CodesResolver(gateway), source: source);

    test('S3a: prepare waits on web, starts at once on native', () async {
      source.needsUserTap = true;
      final web = controller();
      await web.prepare();
      expect(source.starts, 0);
      expect(web.cameraPhase, CameraPhase.awaitingTap);
      await web.startScanning();
      expect(web.cameraPhase, isNull);
      expect(source.starts, 1);
      web.dispose();

      source = FakeScanSource();
      final native = controller();
      await native.prepare();
      expect(source.starts, 1);
      expect(native.awaitingTap, isFalse);
      native.dispose();
    });

    test('S3b: a double tap starts the camera once', () async {
      source.needsUserTap = true;
      final c = controller();
      await c.prepare();
      await Future.wait([c.startScanning(), c.startScanning()]);
      expect(source.starts, 1);
      c.dispose();
    });

    test('S3c: unavailable is not a refusal; scan again retries it', () async {
      final c = controller();
      await c.startScanning();
      await c.onEvent(const ScanCameraUnavailable());
      expect(c.cameraUnavailable, isTrue);
      expect(c.cameraRefused, isFalse);
      expect(c.scanning, isFalse);
      expect(c.cameraPhase, CameraPhase.unavailable);
      await c.scanAgain();
      expect(c.cameraUnavailable, isFalse);
      expect(source.starts, 2);
      await c.onEvent(const ScanPermissionRefused());
      await c.scanAgain();
      expect(c.cameraPhase, CameraPhase.refused);
      expect(source.starts, 2);
      c.dispose();
    });
  });
}
