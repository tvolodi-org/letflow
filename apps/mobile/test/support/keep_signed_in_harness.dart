/// Shared setup for the REQ-810 (30-day sign-in) tests: a controller wired to
/// fakes, no browser, no flag.
library;

import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/auth/device_unlock.dart';
import 'package:letflow/auth/keep_signed_in.dart';
import 'package:letflow/auth/kv_store.dart';
import 'package:letflow/auth/web_app_auth_adapter.dart';
import 'package:letflow/auth/web_pointer_kv.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';

import 'fake_app_auth_adapter.dart';
import 'fake_http_gateway.dart';
import 'fake_session_crypto.dart';

const kRealm = 'https://idp.example/realms/acme';
const kPin = '123456';
const kRpId = 'app.example';

class MapStorage implements StringStorage {
  final m = <String, String>{};
  @override
  String? getItem(String k) => m[k];
  @override
  void setItem(String k, String v) => m[k] = v;
  @override
  void removeItem(String k) => m.remove(k);
}

class KeepHarness {
  KeepHarness({DateTime? start}) : clock = start ?? DateTime.utc(2026, 11, 1) {
    gateway = FakeHttpGateway()
      ..unauthenticatedResponses['/api/mobile/tenant-config'] =
          ScriptedResponse(
            data: tenantConfigJson(
              realmUrl: kRealm,
              clientId: 'letflow-mobile',
            ),
          )
      ..getResponses['/api/v1/me/memberships'] = ScriptedResponse(
        data: const {
          'memberships': [
            {
              'tenant_id': 't-1',
              'tenant_slug': 'acme',
              'tenant_display_name': 'Acme',
              'display_label': null,
            },
          ],
        },
      )
      ..getResponses['/api/v1/me/modules'] = ScriptedResponse(
        data: const {'installed_modules': <dynamic>[]},
      );
    adapter = FakeAppAuthAdapter(response: fakeTokenResponse());
  }

  DateTime clock;
  late FakeHttpGateway gateway;
  late FakeAppAuthAdapter adapter;
  final crypto = FakeSessionCrypto();
  final records = FakeSessionRecordStore();
  final pointer = MapStorage();
  final discovery = FakeDiscoveryHttp({
    'issuer': kRealm,
    'revocation_endpoint': '$kRealm/protocol/openid-connect/revoke',
  });
  final revocation = FakeRevocationHttp();
  final tokenMemory = MemoryKv();

  DateTime now() => clock;

  KeepSignedIn newKeep() =>
      KeepSignedIn(crypto: crypto, store: records, now: now);

  TenantTokenStore newTokenStore(KeepSignedIn? k) =>
      TenantTokenStore.withBackends(
        tokens: k == null ? MemoryKv() : SessionSyncKv(MemoryKv(), k),
        pointer: WebPointerKv(pointer),
      );

  BootstrapController controller({
    KeepSignedIn? keep,
    TenantTokenStore? tokenStore,
    bool withRevoker = true,
    FakeSessionRecordStore? stale,
    DeviceUnlockAuthenticator? deviceUnlock,
  }) {
    return BootstrapController(
      client: gateway,
      tokenStore: tokenStore ?? newTokenStore(keep),
      activeRealm: ActiveRealmHolder(),
      definitionCache: ActiveDefinitionCacheHolder(),
      cacheOpener: (_) async => InMemoryDefinitionCacheRepository(),
      pinnedFormCache: ActivePinnedFormCacheHolder(),
      pinnedFormCacheOpener: (_) async => InMemoryPinnedFormCacheRepository(),
      appAuthAdapter: adapter,
      webMode: true,
      webPending: () => null,
      keepSignedIn: keep,
      deviceUnlock: deviceUnlock,
      rpId: () => kRpId,
      revoker: withRevoker
          ? OidcRevoker(discovery: discovery, post: revocation)
          : null,
      staleRecordStore: stale,
      now: now,
    );
  }
}
