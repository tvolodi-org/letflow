// AC2 and AC4: the whole `runTenantBootstrap` sequence (REQ-421 design
// §5.2), exercised end-to-end against a real `ApiClient` (fake Dio
// transport) and a real `TenantTokenStore` (fake secure-storage platform),
// so token isolation is proven at the actual header-attach level, not just
// at the fake-gateway call-recording level.
import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_dio_http_client_adapter.dart';
import '../support/fake_http_gateway.dart' show tenantConfigJson;
import '../support/fake_secure_storage_platform.dart';

const _realmA = 'https://idp.example/realms/acme';
const _realmB = 'https://idp.example/realms/beta';

void main() {
  late FakeDioHttpClientAdapter fakeAdapter;
  late ApiClient client;
  late TenantTokenStore tokenStore;
  late ActiveRealmHolder activeRealm;

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    fakeAdapter = FakeDioHttpClientAdapter();
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = fakeAdapter;
    tokenStore = const TenantTokenStore(FlutterSecureStorage());
    activeRealm = ActiveRealmHolder();
    client = ApiClient.forTesting(
      dio,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(),
      routeToLogin: () {},
    );

    fakeAdapter.handler = (options) {
      if (options.path == '/api/mobile/tenant-config') {
        final slug = options.queryParameters['slug'];
        if (slug == 'no-such-company') {
          // GH #4771: the server's unknown-company answer.
          return (
            200,
            {
              ...tenantConfigJson(
                realmUrl: 'https://idp.example/realms/bpm-default',
                clientId: 'letflow-mobile',
              ),
              'company_found': false,
            },
          );
        }
        if (slug == 'acme') {
          return (
            200,
            tenantConfigJson(realmUrl: _realmA, clientId: 'client-acme'),
          );
        }
        if (slug == 'beta') {
          return (
            200,
            tenantConfigJson(realmUrl: _realmB, clientId: 'client-beta'),
          );
        }
        if (slug == 'wrong-tenant') {
          return (
            200,
            tenantConfigJson(realmUrl: _realmA, clientId: 'client-acme'),
          );
        }
        if (slug == 'candidate-tenant') {
          return (
            200,
            tenantConfigJson(realmUrl: _realmA, clientId: 'client-acme'),
          );
        }
      }
      if (options.path == '/api/v1/me/memberships') {
        final auth = options.headers['Authorization'];
        if (auth == 'Bearer token-acme') {
          return (
            200,
            {
              'memberships': [
                {
                  'tenant_id': 't-acme',
                  'tenant_slug': 'acme',
                  'tenant_display_name': 'Acme',
                  'display_label': null,
                },
              ],
            },
          );
        }
        if (auth == 'Bearer token-beta') {
          return (
            200,
            {
              'memberships': [
                {
                  'tenant_id': 't-beta',
                  'tenant_slug': 'beta',
                  'tenant_display_name': 'Beta',
                  'display_label': null,
                },
              ],
            },
          );
        }
        if (auth == 'Bearer token-wrong-first-entry') {
          return (
            200,
            {
              'memberships': [
                {
                  'tenant_id': 't-other',
                  'tenant_slug': 'some-other-tenant',
                  'tenant_display_name': 'Some Other Tenant',
                  'display_label': null,
                },
                {
                  'tenant_id': 't-acme',
                  'tenant_slug': 'wrong-tenant',
                  'tenant_display_name': 'Acme',
                  'display_label': null,
                },
              ],
            },
          );
        }
        if (auth == 'Bearer token-candidate') {
          return (403, {'error': 'forbidden'});
        }
      }
      if (options.path == '/api/v1/me/modules') {
        return (200, {'installed_modules': []});
      }
      return null;
    };
  });

  test('two distinct slugs/realm_urls, one app instance, no rebuild: each ends'
      ' with tokens stored under its own tenant key, and each tenant\'s API'
      ' calls carry only that tenant\'s token', () async {
    final resultA = await runTenantBootstrap(
      'acme',
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(
        response: fakeTokenResponse(accessToken: 'token-acme'),
      ),
    );
    expect(resultA, isA<BootstrapSuccess>());

    final resultB = await runTenantBootstrap(
      'beta',
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(
        response: fakeTokenResponse(accessToken: 'token-beta'),
      ),
    );
    expect(resultB, isA<BootstrapSuccess>());

    final storedA = await tokenStore.read(_realmA);
    final storedB = await tokenStore.read(_realmB);
    expect(storedA!.accessToken, 'token-acme');
    expect(storedB!.accessToken, 'token-beta');

    // Never possible for a request made after tenant B's bootstrap to
    // carry tenant A's token (design §5.3's active-realm-pointer
    // invariant).
    final modulesCalls = fakeAdapter.requests
        .where((r) => r.path == '/api/v1/me/modules')
        .toList();
    expect(modulesCalls, hasLength(2));
    expect(modulesCalls[0].headers['Authorization'], 'Bearer token-acme');
    expect(modulesCalls[1].headers['Authorization'], 'Bearer token-beta');

    // And after both, the active pointer is tenant B's — a fresh
    // authenticated call now never carries tenant A's token.
    fakeAdapter.requests.clear();
    await client.get('/api/v1/me/modules');
    expect(
      fakeAdapter.requests.single.headers['Authorization'],
      'Bearer token-beta',
    );
  });

  test('an unknown company code shows tenant-not-found and never starts'
      ' sign-in (GH #4771)', () async {
    final result = await runTenantBootstrap(
      'no-such-company',
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(
        response: fakeTokenResponse(accessToken: 'must-not-be-used'),
      ),
    );

    expect(result, isA<BootstrapFailure>());
    expect(
      (result as BootstrapFailure).reason,
      BootstrapFailureReason.tenantNotFound,
    );
    expect(activeRealm.currentRealmUrl, isNull);
  });

  test(
    'first-membership-entry mismatch (even with a later matching entry)'
    ' shows tenant-not-found and leaves no token in the secure store',
    () async {
      final result = await runTenantBootstrap(
        'wrong-tenant',
        client: client,
        tokenStore: tokenStore,
        activeRealm: activeRealm,
        appAuthAdapter: FakeAppAuthAdapter(
          response: fakeTokenResponse(accessToken: 'token-wrong-first-entry'),
        ),
      );

      expect(result, isA<BootstrapFailure>());
      expect(
        (result as BootstrapFailure).reason,
        BootstrapFailureReason.tenantNotFound,
      );
      // Even though a LATER entry (index 1) does match 'wrong-tenant', the
      // first-entry-only rule (design §5.2 step 4) still rejects.
      expect(await tokenStore.read(_realmA), isNull);
    },
  );

  test('a 403 from /me/memberships (CANDIDATE) proceeds to /me/modules instead'
      ' of failing', () async {
    final result = await runTenantBootstrap(
      'candidate-tenant',
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(
        response: fakeTokenResponse(accessToken: 'token-candidate'),
      ),
    );

    expect(result, isA<BootstrapSuccess>());
    final modulesCalls = fakeAdapter.requests
        .where((r) => r.path == '/api/v1/me/modules')
        .toList();
    expect(modulesCalls, hasLength(1));
  });

  test('user cancellation returns null, not a failure, and no token is'
      ' stored', () async {
    final result = await runTenantBootstrap(
      'acme',
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(response: null),
    );

    expect(result, isNull);
    expect(await tokenStore.read(_realmA), isNull);
  });
}
