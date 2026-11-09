// PWA M2 (D-112) R1: BootstrapController.attemptSessionResume on web
// (redirect back from the IdP, silent restart, failure clears the pointer).
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/app_auth_platform_types.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/auth/kv_store.dart';
import 'package:letflow/auth/web_pointer_kv.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_http_gateway.dart';
import '../support/fake_secure_storage_platform.dart';

const _realm = 'https://idp.example/realms/acme';

class _Map implements StringStorage {
  final m = <String, String>{};
  @override
  String? getItem(String k) => m[k];
  @override
  void setItem(String k, String v) => m[k] = v;
  @override
  void removeItem(String k) => m.remove(k);
}

void main() {
  late FakeHttpGateway gateway;
  late FakeAppAuthAdapter adapter;
  late _Map pointerStorage;
  late TenantTokenStore store;

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    gateway = FakeHttpGateway()
      ..unauthenticatedResponses['/api/mobile/tenant-config'] =
          ScriptedResponse(
            data: tenantConfigJson(realmUrl: _realm, clientId: 'cid'),
          )
      ..getResponses['/api/v1/me/memberships'] = ScriptedResponse(
        statusCode: 403,
        data: const <String, dynamic>{},
      );
    adapter = FakeAppAuthAdapter(response: fakeTokenResponse());
    pointerStorage = _Map();
    store = TenantTokenStore.withBackends(
      tokens: MemoryKv(),
      pointer: WebPointerKv(pointerStorage),
    );
  });

  BootstrapController controller({
    bool webMode = true,
    WebPendingSignIn? pending,
    TenantTokenStore? tokenStore,
  }) => BootstrapController(
    client: gateway,
    tokenStore: tokenStore ?? store,
    activeRealm: ActiveRealmHolder(),
    definitionCache: ActiveDefinitionCacheHolder(),
    cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
    pinnedFormCache: ActivePinnedFormCacheHolder(),
    pinnedFormCacheOpener: (_) async => InMemoryPinnedFormCacheRepository(),
    appAuthAdapter: adapter,
    webMode: webMode,
    webPending: () => pending,
  );

  test('R1 pending redirect: bootstrap runs for the remembered slug', () async {
    final c = controller(
      pending: const WebPendingSignIn(slug: 'acme', state: 's'),
    );
    await c.attemptSessionResume();
    expect(adapter.callCount, 1);
    expect(gateway.calls.first.queryParameters?['slug'], 'acme');
  });

  test(
    'R1 pointer without tokens: sign-in restarts for the pointer slug',
    () async {
      await writeLastActiveTenant(
        store,
        const LastActiveTenantPointer(realmUrl: _realm, slug: 'acme'),
      );
      await controller().attemptSessionResume();
      expect(adapter.callCount, 1);
    },
  );

  test('R1 no pointer: unauthenticated, adapter untouched', () async {
    final c = controller();
    await c.attemptSessionResume();
    expect(c.state.phase, BootstrapPhase.unauthenticated);
    expect(adapter.callCount, 0);
  });

  test('R1 failed sign-in clears the pointer (no reload loop)', () async {
    adapter.error = StateError('boom');
    await writeLastActiveTenant(
      store,
      const LastActiveTenantPointer(realmUrl: _realm, slug: 'acme'),
    );
    final c = controller();
    await c.attemptSessionResume();
    expect(c.state.phase, BootstrapPhase.failure);
    expect(await readLastActiveTenant(store), isNull);
  });

  test('R1 webMode false keeps the native path (no adapter call)', () async {
    final native = const TenantTokenStore(FlutterSecureStorage());
    await writeLastActiveTenant(
      native,
      const LastActiveTenantPointer(realmUrl: _realm, slug: 'acme'),
    );
    final c = controller(webMode: false, tokenStore: native);
    await c.attemptSessionResume();
    expect(c.state.phase, BootstrapPhase.unauthenticated);
    expect(adapter.callCount, 0);
  });
}
