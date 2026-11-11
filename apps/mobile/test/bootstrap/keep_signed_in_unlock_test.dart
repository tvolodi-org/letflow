// REQ-810 criteria 6 and 7: the lock screen, wrong PINs, refresh failures.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/app.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/auth/keep_signed_in.dart';
import 'package:letflow/auth/kv_store.dart';
import 'package:letflow/auth/session_record.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_dio_http_client_adapter.dart';
import '../support/keep_signed_in_harness.dart';

Future<KeepHarness> _enrolled() async {
  final h = KeepHarness();
  final c = h.controller(keep: h.newKeep());
  await c.beginBootstrap('acme');
  await c.enrollWithPin(kPin, kPin);
  h.gateway.calls.clear();
  h.adapter.refreshCallCount = 0;
  return h;
}

Future<BootstrapController> _locked(KeepHarness h) async {
  final c = h.controller(keep: h.newKeep());
  await c.attemptSessionResume();
  return c;
}

int _failed(KeepHarness h) =>
    SessionRecord.tryParse(h.records.raw!)!.failedPins;

void main() {
  test('U1 a record at open: locked, no HTTP, nothing reachable', () async {
    final h = await _enrolled();
    final c = await _locked(h);
    expect(c.state.phase, BootstrapPhase.locked);
    expect(h.gateway.calls, isEmpty);
    expect(h.adapter.refreshCallCount, 0);
    expect(c.state.installedModules, isEmpty);
  });

  test('U2 the right PIN: one refresh, success, count 0', () async {
    final h = await _enrolled();
    var c = await _locked(h);
    await c.submitPin('000000');
    await c.submitPin('111111');
    expect(_failed(h), 2);
    c = await _locked(h);
    await c.submitPin(kPin);
    expect(c.state.phase, BootstrapPhase.success);
    expect(h.adapter.refreshCallCount, 1);
    expect(h.adapter.lastRefreshRequest!.refreshToken, 'fake-refresh-token');
    expect(h.adapter.lastRefreshRequest!.clientId, 'letflow-mobile');
    expect(_failed(h), 0);
  });

  test(
    'U3 each wrong PIN adds one, and it survives a new controller',
    () async {
      final h = await _enrolled();
      var c = await _locked(h);
      await c.submitPin('000000');
      expect(c.state.unlockNotice, UnlockNotice.wrongPin);
      expect(c.state.pinsRemaining, 4);
      expect(_failed(h), 1);
      c = await _locked(h); // a reload
      await c.submitPin('000000');
      expect(_failed(h), 2);
      expect(h.adapter.refreshCallCount, 0);
    },
  );

  test('U4 the 4th wrong PIN keeps the record, the 5th deletes it', () async {
    final h = await _enrolled();
    final c = await _locked(h);
    for (var i = 0; i < 4; i++) {
      await c.submitPin('000000');
    }
    expect(h.records.raw, isNotNull);
    expect(c.state.phase, BootstrapPhase.locked);
    await c.submitPin('000000');
    expect(h.records.raw, isNull);
    expect(c.state.phase, BootstrapPhase.unauthenticated);
    expect(c.state.unlockNotice, UnlockNotice.tooManyAttempts);
    // Even the right PIN cannot unlock a deleted record.
    expect(await h.newKeep().unlock(kPin), isA<Corrupt>());
  });

  test('U5 sign in again deletes the record', () async {
    final h = await _enrolled();
    final c = await _locked(h);
    await c.signInAgain();
    expect(h.records.raw, isNull);
    expect(c.state.phase, BootstrapPhase.unauthenticated);
  });

  test('U6 invalid_grant at unlock deletes the record', () async {
    final h = await _enrolled();
    final c = await _locked(h);
    h.adapter.refreshError = const OidcHttpError(400, 'invalid_grant');
    await c.submitPin(kPin);
    expect(h.records.raw, isNull);
    expect(c.state.phase, BootstrapPhase.unauthenticated);
    expect(c.state.unlockNotice, UnlockNotice.revoked);
  });

  test('U7 a network error keeps the record; retry needs no PIN', () async {
    final h = await _enrolled();
    final c = await _locked(h);
    h.adapter.refreshError = StateError('offline');
    await c.submitPin(kPin);
    expect(c.state.phase, BootstrapPhase.locked);
    expect(c.state.unlockNotice, UnlockNotice.noConnection);
    expect(h.records.raw, isNotNull);
    expect(_failed(h), 0);
    expect(c.state.installedModules, isEmpty);
    expect(
      h.gateway.calls.where((x) => x.path.startsWith('/api/v1')),
      isEmpty,
      reason: 'no tenant data while the refresh failed',
    );
    h.adapter.refreshError = null;
    await c.retryUnlockRefresh();
    expect(c.state.phase, BootstrapPhase.success);
    expect(h.adapter.refreshCallCount, 2);
  });

  group('refresh coordinator', () {
    Future<(KeepHarness, ApiClient, FakeAppAuthAdapter)> setup() async {
      final h = await _enrolled();
      final keep = h.newKeep();
      expect(await keep.unlock(kPin), isA<Unlocked>());
      final store = h.newTokenStore(keep);
      await store.store(
        kRealm,
        const TokenSet(
          accessToken: 'a',
          refreshToken: 'fake-refresh-token',
          idToken: null,
          accessTokenExpiration: null,
        ),
      );
      final dioAdapter = FakeDioHttpClientAdapter()
        ..handler = (o) => (401, <String, dynamic>{});
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = dioAdapter;
      final auth = FakeAppAuthAdapter();
      final client = ApiClient.forTesting(
        dio,
        tokenStore: store,
        activeRealm: ActiveRealmHolder()
          ..currentRealmUrl = kRealm
          ..clientId = 'letflow-mobile',
        appAuthAdapter: auth,
        routeToLogin: () {},
        delayFn: (_) async {},
        onRefreshRejected: keep.delete,
      );
      return (h, client, auth);
    }

    test(
      'U8 a refresh failing with a network error keeps the record',
      () async {
        final (h, client, auth) = await setup();
        auth.refreshError = StateError('socket');
        await expectLater(client.get('/x'), throwsA(anything));
        expect(h.records.raw, isNotNull);
      },
    );

    test(
      'U9 a refresh failing with invalid_grant deletes the record',
      () async {
        final (h, client, auth) = await setup();
        auth.refreshError = const OidcHttpError(400, 'invalid_grant');
        await expectLater(client.get('/x'), throwsA(anything));
        expect(h.records.raw, isNull);
      },
    );
  });

  testWidgets(
    'U1w the lock screen gates every route and shows a wrong-PIN line without the PIN',
    (tester) async {
      final h = await _enrolled();
      final c = h.controller(keep: h.newKeep());
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bootstrapControllerProvider.overrideWith((ref) => c)],
          child: const LetflowApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pin-unlock-screen')), findsOneWidget);
      final ctx = tester.element(find.byKey(const Key('pin-unlock-screen')));
      GoRouter.of(ctx).go('/home');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pin-unlock-screen')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('pin-unlock-field')),
        '000000',
      );
      await tester.tap(find.byKey(const Key('pin-unlock-submit')));
      await tester.pumpAndSettle();
      final notice = tester.widget<Text>(
        find.byKey(const Key('pin-unlock-notice')),
      );
      expect(notice.data, isNot(contains('000000')));
      expect(c.state.phase, BootstrapPhase.locked);
    },
  );
}
