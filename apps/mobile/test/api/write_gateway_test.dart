// W1 (T-1346): ApiClient.put / delete send PUT / DELETE once, with no 5xx
// retry, like post().
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/api/api_error.dart';
import 'package:letflow/auth/auth.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_secure_storage_platform.dart';

class _Adapter implements HttpClientAdapter {
  final List<String> seen = [];
  int status = 200;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add('${options.method} ${options.path}');
    return ResponseBody.fromString(
      jsonEncode({'ok': true}),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _Adapter adapter;
  late ApiClient client;

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    adapter = _Adapter();
    client = ApiClient.forTesting(
      Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter,
      tokenStore: const TenantTokenStore(FlutterSecureStorage()),
      activeRealm: ActiveRealmHolder(),
      appAuthAdapter: FakeAppAuthAdapter(),
      routeToLogin: () {},
      delayFn: (_) async {},
    );
  });

  test('W1a: put and delete send their own verb', () async {
    await client.put('/x/1', data: {'a': 1});
    await client.delete('/x/1');
    expect(adapter.seen, ['PUT /x/1', 'DELETE /x/1']);
    expect(client, isA<WriteCapableHttpGateway>());
  });

  test(
    'W1b: a 503 on put and delete is one attempt, then ServerError',
    () async {
      adapter.status = 503;
      await expectLater(client.put('/x/1'), throwsA(isA<ServerError>()));
      await expectLater(client.delete('/x/1'), throwsA(isA<ServerError>()));
      expect(adapter.seen, ['PUT /x/1', 'DELETE /x/1']);
    },
  );
}
