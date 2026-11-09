// T-1499 (PWA M3): the offline queue is cleared on logout and tenant switch,
// and the queued drafts are sent once when a verified session starts.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/app.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/pinned_form_cache.dart';
import 'package:letflow/definitions/tenant_home_screen.dart';
import 'package:letflow/features/stock/stock.dart';
import 'package:letflow/offline/offline_queue.dart';
import 'package:letflow/offline/offline_sync.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_dio_http_client_adapter.dart';
import '../support/fake_http_gateway.dart'
    show FakeHttpGateway, tenantConfigJson;
import '../support/fake_secure_storage_platform.dart';

const _realmA = 'https://idp.example/realms/acme';
const _realmB = 'https://idp.example/realms/beta';

class _SpyQueue implements OfflineDraftQueue {
  int cleared = 0;
  @override
  Future<void> closeAndClear() async => cleared++;
  @override
  Future<EnqueueResult> enqueue(
    Map<String, dynamic> body, {
    String label = '',
  }) async => EnqueueResult.stored;
  @override
  Future<List<QueuedDraft>> all() async => const [];
  @override
  Future<int> count() async => 0;
  @override
  Future<void> remove(String localId) async {}
  @override
  Future<void> markRejected(String localId, String code) async {}
}

class _StateController extends BootstrapController {
  _StateController(this.fake, {required super.client})
    : super(
        tokenStore: const TenantTokenStore(FlutterSecureStorage()),
        activeRealm: ActiveRealmHolder(),
        definitionCache: ActiveDefinitionCacheHolder(),
        pinnedFormCache: ActivePinnedFormCacheHolder(),
      );
  BootstrapUiState fake;
  @override
  BootstrapUiState get state => fake;
  void set(BootstrapUiState s) {
    fake = s;
    notifyListeners();
  }
}

class _Gateway implements HttpGateway {
  @override
  Future<Response<dynamic>> getUnauthenticated(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => Completer<Response<dynamic>>().future;
  @override
  Future<Response<dynamic>> get(
    String path, {
    Map<String, dynamic>? queryParameters,
  }) => Completer<Response<dynamic>>().future;
}

void main() {
  late TenantTokenStore tokenStore;
  late ActiveRealmHolder activeRealm;
  late ApiClient client;
  late _SpyQueue spy;

  setUp(() {
    FlutterSecureStoragePlatform.instance = FakeSecureStoragePlatform();
    final fake = FakeDioHttpClientAdapter()
      ..handler = (options) {
        if (options.path == '/api/mobile/tenant-config') {
          return (
            200,
            tenantConfigJson(realmUrl: _realmB, clientId: 'client-beta'),
          );
        }
        return null;
      };
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = fake;
    tokenStore = const TenantTokenStore(FlutterSecureStorage());
    activeRealm = ActiveRealmHolder()..currentRealmUrl = _realmA;
    client = ApiClient.forTesting(
      dio,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(),
      routeToLogin: () {},
    );
    spy = _SpyQueue();
  });

  test('Q7: logout clears the offline queue', () async {
    await logout(
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      offlineQueue: spy,
    );
    expect(spy.cleared, 1);
  });

  test('Q7b: logout with no active tenant leaves the queue alone', () async {
    activeRealm.currentRealmUrl = null;
    await logout(
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      offlineQueue: spy,
    );
    expect(spy.cleared, 0);
  });

  test('Q8: switching to another tenant clears the offline queue', () async {
    await switchTenant(
      'beta',
      client: client,
      tokenStore: tokenStore,
      activeRealm: activeRealm,
      appAuthAdapter: FakeAppAuthAdapter(response: fakeTokenResponse()),
      offlineQueue: spy,
    );
    expect(spy.cleared, 1);
  });

  group('A1: sync when the app opens', () {
    late int sent;
    late _StateController controller;

    Future<void> pump(WidgetTester tester, BootstrapPhase phase) async {
      final q = _SpyQueue();
      final repo = InMemoryDefinitionCacheRepository();
      final home = DefinitionHomeController(
        repository: repo,
        syncService: DefinitionSyncService(
          repository: repo,
          client: FakeHttpGateway(),
        ),
      );
      controller = _StateController(
        BootstrapUiState(phase: phase),
        client: _Gateway(),
      );
      sent = 0;
      final sync = OfflineSyncService(_OneEntry(), (body) async => sent++);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            bootstrapControllerProvider.overrideWith((ref) => controller),
            definitionHomeControllerProvider.overrideWith((ref) => home),
            offlineSyncProvider.overrideWithValue(sync),
            offlineQueueProvider.overrideWithValue(q),
          ],
          child: const LetflowApp(),
        ),
      );
      await tester.pump();
    }

    testWidgets('success drains once; a later change does not drain again', (
      tester,
    ) async {
      await pump(tester, BootstrapPhase.unauthenticated);
      expect(sent, 0);
      controller.set(const BootstrapUiState(phase: BootstrapPhase.success));
      await tester.pump();
      expect(sent, 1);
      controller.set(const BootstrapUiState(phase: BootstrapPhase.success));
      await tester.pump();
      expect(sent, 1);
    });

    testWidgets('resumedOffline does not drain', (tester) async {
      await pump(tester, BootstrapPhase.unauthenticated);
      controller.set(
        const BootstrapUiState(phase: BootstrapPhase.resumedOffline),
      );
      await tester.pump();
      expect(sent, 0);
    });
  });
}

class _OneEntry extends _SpyQueue {
  @override
  Future<List<QueuedDraft>> all() async => const [
    QueuedDraft(localId: '1', body: {'n': 1}, label: '', createdAtMs: 1),
  ];
}
