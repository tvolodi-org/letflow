// D3a: refusal reason plumbing (A1), PUT on the real client (A2), models
// (M1), refusals in three languages (R1), resolve target id (D3b).
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/features/codes/codes.dart';
import 'package:letflow/features/stock/count_models.dart';
import 'package:letflow/features/stock/count_refusal.dart';
import 'package:letflow/features/stock/scan_id.dart';

import '../../support/fake_app_auth_adapter.dart';
import '../../support/fake_dio_http_client_adapter.dart';
import '../../support/fake_put_capable_http_gateway.dart';
import '../../support/fake_secure_storage_platform.dart';

final _opts = RequestOptions(path: '/api/v1/modules/stock/counts/x/scan');

void main() {
  test('A1: reason is read from the top-level member', () {
    final v = classifyError(
      _opts,
      statusCode: 422,
      responseBody: {'reason': 'scan_no_line', 'errors': []},
    );
    expect((v as ValidationError).reason, 'scan_no_line');
    final c = classifyError(
      _opts,
      statusCode: 409,
      responseBody: {'reason': 'count_state_invalid'},
    );
    expect((c as ConflictError).reason, 'count_state_invalid');
    expect(
      (classifyError(_opts, statusCode: 422, responseBody: {'reason': 5})
              as ValidationError)
          .reason,
      isNull,
    );
    expect(
      (classifyError(_opts, statusCode: 422, responseBody: 'x')
              as ValidationError)
          .fieldErrors,
      isEmpty,
    );
    expect(
      (classifyError(_opts, statusCode: 409) as ConflictError).reason,
      isNull,
    );
  });

  group('A2: PUT on the real client', () {
    Future<(ApiClient, FakeDioHttpClientAdapter, List<RequestOptions>)>
    build() async {
      FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
      final adapter = FakeDioHttpClientAdapter();
      final seen = <RequestOptions>[];
      adapter.handler = (o) {
        seen.add(o);
        return switch (o.path) {
          '/ok' => (200, {'ok': true}),
          '/forbidden' => (403, {}),
          '/api/v1/modules/stock/gone' => (404, {}),
          '/busy' => (429, {}),
          _ => (503, {}),
        };
      };
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter;
      final realm = ActiveRealmHolder()
        ..currentRealmUrl = 'https://idp.example/realms/acme'
        ..clientId = 'c';
      final client = ApiClient.forTesting(
        dio,
        tokenStore: const TenantTokenStore(FlutterSecureStorage()),
        activeRealm: realm,
        appAuthAdapter: FakeAppAuthAdapter(),
        routeToLogin: () {},
        delayFn: (_) async {},
      );
      return (client, adapter, seen);
    }

    test(
      'sends the body, classifies 403/404/429, does not retry a 5xx',
      () async {
        final (client, _, seen) = await build();
        final r = await client.put('/ok', data: {'counted_quantity': '12.5'});
        expect(r.statusCode, 200);
        expect(seen.single.method, 'PUT');
        expect(seen.single.data, {'counted_quantity': '12.5'});
        await expectLater(
          client.put('/forbidden'),
          throwsA(isA<ForbiddenError>()),
        );
        await expectLater(
          client.put('/api/v1/modules/stock/gone'),
          throwsA(isA<ModuleNotAvailableError>()),
        );
        await expectLater(
          client.put('/busy'),
          throwsA(isA<BackpressureError>()),
        );
        seen.clear();
        await expectLater(client.put('/boom'), throwsA(isA<ServerError>()));
        expect(seen.length, 1);
      },
    );
  });

  test('M1: models keep quantity strings; malformed answers throw', () {
    final line = CountLine.fromJson({
      'line_no': 3,
      'location_id': 'l',
      'catalog_item_id': 'i',
      'unit_ref': 'u',
      'book_quantity': '10.500',
      'counted_quantity': null,
    });
    expect(line.bookQuantity, '10.500');
    expect(line.countedQuantity, isNull);
    final a = ScanAnswer.fromJson({
      'line_no': 1,
      'location_id': 'l',
      'catalog_item_id': 'i',
      'unit_ref': 'u',
      'duplicate': true,
    });
    expect((a as ScanLine).duplicate, isTrue);
    expect(
      (ScanAnswer.fromJson({'kind': 'location', 'location_id': 'p'})
              as ScanLocation)
          .locationId,
      'p',
    );
    expect(() => CountLine.fromJson('x'), throwsA(isA<MalformedStockAnswer>()));
    expect(
      () => CountPage.fromJson({'rows': 5}, CountLine.fromJson),
      throwsA(isA<MalformedStockAnswer>()),
    );
    expect(
      () => CountOrder.fromJson({'status': 'x'}),
      throwsA(isA<MalformedStockAnswer>()),
    );
  });

  test('R1: every refusal has its own key in en, ru and kk', () {
    final keys = CountRefusal.values.map((r) => r.messageKey).toSet();
    expect(keys.length, CountRefusal.values.length);
    for (final l in ['en', 'ru', 'kk']) {
      final cat =
          jsonDecode(File('lib/i18n/l10n/app_$l.arb').readAsStringSync())
              as Map<String, dynamic>;
      for (final k in keys) {
        expect(
          cat[k] is String && (cat[k] as String).isNotEmpty,
          isTrue,
          reason: '$l:$k',
        );
      }
    }
    expect(CountRefusal.fromReason('scan_no_line'), CountRefusal.scanNoLine);
    expect(CountRefusal.fromReason('nonsense'), CountRefusal.unknown);
    expect(CountRefusal.fromReason(null), CountRefusal.unknown);
  });

  test('scan ids are v4 uuids and differ', () {
    final re = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    final a = newScanId();
    expect(re.hasMatch(a), isTrue);
    expect(newScanId(), isNot(a));
  });

  test('D3b: target id is parsed from target_id, null otherwise', () async {
    Future<CodeResolution> resolve(Map<String, dynamic> body) =>
        CodesResolver(FakePutCapableHttpGateway((_) => body)).resolve('x');
    final ok = await resolve({
      'status': 'assigned',
      'target_type': 'location_node',
      'target_id': 'loc-1',
    });
    expect(ok.targetId, 'loc-1');
    expect(ok.objectKind, CodeObjectKind.location);
    expect((await resolve({'status': 'not_assigned'})).targetId, isNull);
    expect(
      (await resolve({'status': 'assigned', 'target_id': 7})).targetId,
      isNull,
    );
  });
}
