// REQ-732 criteria 3-7: the scan screen against a fake camera source and a
// scripted gateway. No camera, no network.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/features/codes/scan_screen.dart';
import 'package:letflow/i18n/i18n.dart';
import 'package:letflow/features/codes/scan_source.dart';
import 'package:letflow/renderers/renderer_state_view.dart';

import '../../support/fake_post_capable_http_gateway.dart';
import '../../support/load_test_catalogue.dart';
import 'fakes.dart';

Map<String, dynamic> _answer(
  String status, {
  String value = 'AB+12 ',
  String? kind = 'barcode',
  String? targetType,
}) => {
  'code_id': status == 'assigned' || status == 'not_assigned' ? 'c1' : null,
  'value': value,
  'kind': kind,
  'status': status,
  'target_type': targetType,
  'target_id': targetType == null ? null : 't1',
  'assignment_id': targetType == null ? null : 'a1',
};

late FakeScanSource source;
late FakePostCapableHttpGateway gateway;

Widget _app() => ProviderScope(
  overrides: [
    scanSourceProvider.overrideWithValue(() => source),
    codesGatewayProvider.overrideWithValue(gateway),
  ],
  child: const MaterialApp(home: CodesScanScreen()),
);

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(_app());
  await tester.pump();
}

void main() {
  setUpAll(loadTestMessageCatalogue);
  setUp(() {
    source = FakeScanSource();
    gateway = FakePostCapableHttpGateway();
  });

  testWidgets('S3a: one detection sends one POST with the exact text', (
    tester,
  ) async {
    gateway.postResponseQueue.add(
      ScriptedResponse(data: _answer('not_assigned')),
    );
    await _pump(tester);
    source.detect('AB+12 ');
    await tester.pumpAndSettle();
    expect(gateway.postCalls, hasLength(1));
    expect(gateway.postCalls.single.path, '/api/v1/modules/codes/resolve');
    expect(gateway.postCalls.single.data, {'value': 'AB+12 '});
    expect(source.stops, 1);
  });

  testWidgets('S3b-d: extra and empty detections send nothing; scan again '
      'allows one more request', (tester) async {
    gateway.postResponseQueue
      ..add(ScriptedResponse(data: _answer('not_assigned')))
      ..add(ScriptedResponse(data: _answer('not_assigned', value: 'Z9')));
    await _pump(tester);
    source.detect(null);
    source.detect('');
    await tester.pump();
    expect(gateway.postCalls, isEmpty); // S3c: null/empty text ignored
    source.detect('AB+12 ');
    source.detect('AB+12 ');
    source.detect('OTHER');
    source.detect('OTHER');
    await tester.pumpAndSettle();
    expect(gateway.postCalls, hasLength(1)); // S3b
    await tester.tap(find.byKey(const Key('codes-scan-again')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('codes-result')), findsNothing);
    source.detect('Z9');
    await tester.pumpAndSettle();
    expect(gateway.postCalls, hasLength(2)); // S3d
    expect(gateway.postCalls.last.data, {'value': 'Z9'});
  });

  testWidgets('S4a: a typed code sends the same request, text unchanged', (
    tester,
  ) async {
    gateway.postResponseQueue.add(
      ScriptedResponse(data: _answer('not_assigned')),
    );
    await _pump(tester);
    await tester.enterText(find.byKey(const Key('codes-typed')), ' x1 ');
    await tester.tap(find.byKey(const Key('codes-lookup')));
    await tester.pumpAndSettle();
    expect(gateway.postCalls.single.data, {'value': ' x1 '});
  });

  testWidgets('S4b: refused camera shows the message and typing still works', (
    tester,
  ) async {
    gateway.postResponseQueue.add(ScriptedResponse(data: _answer('retired')));
    await _pump(tester);
    source.controller.add(const ScanPermissionRefused());
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('codes-camera-refused')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('codes-typed')), 'Q1');
    await tester.tap(find.byKey(const Key('codes-lookup')));
    await tester.pumpAndSettle();
    expect(gateway.postCalls, hasLength(1));
    expect(find.text('This code is retired'), findsOneWidget);
  });

  for (final c in [
    ('S5a', 'location_node', 'A location'),
    ('S5b', 'catalog_item', 'An item'),
    ('S5c', 'catalog_lot', 'A lot'),
    ('S5d', 'something_else', 'Another object'),
  ]) {
    testWidgets('${c.$1}: assigned ${c.$2} shows value, kind, object kind', (
      tester,
    ) async {
      gateway.postResponseQueue.add(
        ScriptedResponse(data: _answer('assigned', targetType: c.$2)),
      );
      await _pump(tester);
      source.detect('AB+12 ');
      await tester.pumpAndSettle();
      expect(find.text('Code: AB+12 '), findsOneWidget);
      expect(find.text('Kind: Barcode'), findsOneWidget);
      expect(find.text('Names: ${c.$3}'), findsOneWidget);
    });
  }

  for (final c in [
    ('S5e', 'not_assigned', 'This code is not assigned to anything'),
    ('S5f', 'retired', 'This code is retired'),
    (
      'S5g',
      'assignment_conflict',
      'This code has an assignment problem; ask the administrator',
    ),
  ]) {
    testWidgets('${c.$1}: ${c.$2} shows its message', (tester) async {
      gateway.postResponseQueue.add(
        ScriptedResponse(data: _answer(c.$2, kind: null)),
      );
      await _pump(tester);
      source.detect('AB+12 ');
      await tester.pumpAndSettle();
      expect(find.text(c.$3), findsOneWidget);
    });
  }

  testWidgets('S5h: 404 shows "not known", not a module-missing screen', (
    tester,
  ) async {
    gateway.postResponseQueue.add(
      ScriptedResponse(error: const ModuleNotAvailableError(moduleId: 'codes')),
    );
    await _pump(tester);
    source.detect('AB+12 ');
    await tester.pumpAndSettle();
    expect(find.text('This code is not known'), findsOneWidget);
    expect(find.byKey(rendererFetchFailureKey), findsNothing);
  });

  testWidgets('S5i: 403 shows permission denied', (tester) async {
    gateway.postResponseQueue.add(
      ScriptedResponse(error: const ForbiddenError()),
    );
    await _pump(tester);
    source.detect('AB+12 ');
    await tester.pumpAndSettle();
    expect(find.byKey(rendererPermissionDeniedKey), findsOneWidget);
  });

  testWidgets('S5j: network failure, then Retry sends the request again', (
    tester,
  ) async {
    gateway.postResponseQueue
      ..add(ScriptedResponse(error: const NetworkUnavailableError()))
      ..add(ScriptedResponse(data: _answer('retired')));
    await _pump(tester);
    source.detect('AB+12 ');
    await tester.pumpAndSettle();
    expect(find.byKey(rendererFetchFailureKey), findsOneWidget);
    await tester.tap(find.byKey(const Key('codes-retry')));
    await tester.pumpAndSettle();
    expect(gateway.postCalls, hasLength(2));
    expect(gateway.postCalls.last.data, {'value': 'AB+12 '});
    expect(find.text('This code is retired'), findsOneWidget);
  });

  testWidgets('S5k: 429 shows the countdown and resends once at zero', (
    tester,
  ) async {
    gateway.postResponseQueue
      ..add(
        ScriptedResponse(error: const BackpressureError(retryAfterSeconds: 2)),
      )
      ..add(ScriptedResponse(data: _answer('retired')));
    await _pump(tester);
    source.detect('AB+12 ');
    await tester.pump();
    await tester.pump();
    expect(find.byKey(rendererBackpressureKey), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(gateway.postCalls, hasLength(2));
    expect(find.text('This code is retired'), findsOneWidget);
  });

  testWidgets('S5l: a malformed answer is a fetch failure; result is in a '
      'RendererStateView', (tester) async {
    gateway.postResponseQueue.add(ScriptedResponse(data: {'status': 'weird'}));
    await _pump(tester);
    source.detect('AB+12 ');
    await tester.pumpAndSettle();
    expect(find.byKey(rendererFetchFailureKey), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString().startsWith('RendererStateView'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('S6b: leaving and reopening shows no earlier result', (
    tester,
  ) async {
    gateway.postResponseQueue.add(ScriptedResponse(data: _answer('retired')));
    await _pump(tester);
    source.detect('AB+12 ');
    await tester.pumpAndSettle();
    expect(find.text('This code is retired'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(source.disposed, isTrue);
    source = FakeScanSource();
    await _pump(tester);
    expect(find.text('This code is retired'), findsNothing);
    expect(find.byKey(const Key('codes-result')), findsNothing);
  });

  for (final c in [
    ('L7c', 'ru', 'Этот код выведен из использования'),
    ('L7d', 'kk', 'Бұл код қолданыстан шығарылған'),
  ]) {
    testWidgets('${c.$1}: ${c.$2} text for a retired code', (tester) async {
      // The device locale cannot be faked for `ui.PlatformDispatcher.instance`,
      // so the catalogue is rebuilt with the target locale's table under the
      // fallback key `en`.
      final saved = appMessageCatalogue;
      addTearDown(() => appMessageCatalogue = saved);
      final table =
          (jsonDecode(File('lib/i18n/l10n/app_${c.$2}.arb').readAsStringSync())
                as Map<String, dynamic>)
            ..removeWhere((k, v) => k.startsWith('@'));
      appMessageCatalogue = MessageCatalogue({
        'en': table.map((k, v) => MapEntry(k, v as String)),
      });
      gateway.postResponseQueue.add(ScriptedResponse(data: _answer('retired')));
      await _pump(tester);
      source.detect('AB+12 ');
      await tester.pumpAndSettle();
      expect(find.text(c.$3), findsOneWidget);
    });
  }
}
