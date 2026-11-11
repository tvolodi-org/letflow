// REQ-810 criterion 5: 30 days from the full sign-in; refresh never moves it.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/api/api_client.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/auth/session_record.dart';
import 'package:letflow/auth/web_app_auth_adapter.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_http_gateway.dart' show tenantConfigJson;
import '../support/fake_session_crypto.dart';
import '../support/keep_signed_in_harness.dart';

Future<KeepHarness> _enrolled({DateTime? start}) async {
  final h = KeepHarness(start: start);
  final c = h.controller(keep: h.newKeep());
  await c.beginBootstrap('acme');
  expect(await c.enrollWithPin(kPin, kPin), EnrollOutcome.enrolled);
  return h;
}

/// A new page load: new controller, new in-memory state, same stores.
BootstrapController _reopen(KeepHarness h) {
  h.adapter.refreshCallCount = 0;
  return h.controller(keep: h.newKeep());
}

class _Loc implements WebLocation {
  String? assigned;
  @override
  Uri get current => Uri.parse('https://pwa.example/m/');
  @override
  String get redirectUri => 'https://pwa.example/m/';
  @override
  void assign(String url) => assigned = url;
  @override
  void replaceState(String url) {}
}

void main() {
  test(
    'L1b the request WebAppAuthAdapter builds carries offline_access',
    () async {
      final loc = _Loc();
      final adapter = WebAppAuthAdapter(
        http: FakeDiscoveryHttp({
          'issuer': kRealm,
          'authorization_endpoint': '$kRealm/protocol/openid-connect/auth',
          'token_endpoint': '$kRealm/protocol/openid-connect/token',
        }),
        location: loc,
        session: MapStorage(),
      );
      unawaited(
        authenticateWithTenant(
          TenantConfig.fromJson(tenantJson()),
          appAuthAdapter: adapter,
          scopes: kOidcScopesWeb,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final scope = Uri.parse(
        loc.assigned!,
      ).queryParameters['scope']!.split(' ');
      expect(scope, ['openid', 'profile', 'email', 'offline_access']);
    },
  );

  test(
    'L1 the web sign-in asks for offline_access plus the three scopes',
    () async {
      final h = KeepHarness();
      final c = h.controller(keep: h.newKeep());
      await c.beginBootstrap('acme');
      expect(
        h.adapter.lastRequest!.scopes,
        containsAll(['openid', 'profile', 'email', 'offline_access']),
      );
      expect(h.adapter.lastRequest!.scopes, hasLength(4));
    },
  );

  test('L2 native/flag-off default scopes are unchanged', () async {
    final h = KeepHarness();
    final c = h.controller(); // flag off
    await c.beginBootstrap('acme');
    expect(h.adapter.lastRequest!.scopes, kOidcScopes);
    expect(kOidcScopes, isNot(contains('offline_access')));
    final a = FakeAppAuthAdapter(response: fakeTokenResponse());
    await authenticateWithTenant(
      TenantConfig.fromJson(tenantJson()),
      appAuthAdapter: a,
    );
    expect(a.lastRequest!.scopes, kOidcScopes);
  });

  test('L3 29 days 23 hours still unlocks and refreshes once', () async {
    final h = await _enrolled();
    h.clock = h.clock.add(const Duration(days: 29, hours: 23));
    final c = _reopen(h);
    await c.attemptSessionResume();
    expect(c.state.phase, BootstrapPhase.locked);
    await c.submitPin(kPin);
    expect(c.state.phase, BootstrapPhase.success);
    expect(h.adapter.refreshCallCount, 1);
  });

  test(
    'L4 exactly 30 days deletes the record and makes no refresh call',
    () async {
      final h = await _enrolled();
      h.clock = h.clock.add(const Duration(days: 30));
      final c = _reopen(h);
      await c.attemptSessionResume();
      await c.submitPin(kPin);
      expect(c.state.phase, BootstrapPhase.unauthenticated);
      expect(c.state.unlockNotice, UnlockNotice.expired);
      expect(h.records.raw, isNull);
      expect(h.adapter.refreshCallCount, 0);
      expect(h.crypto.pbkdf2Calls.length, 1); // only the enrolment's derivation
    },
  );

  test('L5 a refresh replaces the stored token, signed_in_at stays', () async {
    final h = await _enrolled();
    final before = SessionRecord.tryParse(h.records.raw!)!;
    h.clock = h.clock.add(const Duration(days: 3));
    h.adapter.refreshResponse = fakeTokenRefreshResponse(
      refreshToken: 'rotated-refresh-token',
    );
    final c = _reopen(h);
    await c.attemptSessionResume();
    await c.submitPin(kPin);
    expect(c.state.phase, BootstrapPhase.success);
    final after = SessionRecord.tryParse(h.records.raw!)!;
    expect(after.signedInAt, before.signedInAt);
    expect(after.encRefreshToken, isNot(before.encRefreshToken));
    expect(h.records.raw!.contains('rotated-refresh-token'), isFalse);
    // The new token is what the next unlock refreshes with.
    final k2 = h.newKeep();
    await k2.unlock(kPin);
    expect(await k2.unlockedRefreshToken(), 'rotated-refresh-token');
  });

  test('L6 PIN set 3 hours after sign-in keeps the sign-in time', () async {
    final h = KeepHarness();
    final c = h.controller(keep: h.newKeep());
    await c.beginBootstrap('acme');
    final signedIn = h.clock;
    h.clock = h.clock.add(const Duration(hours: 3));
    expect(await c.enrollWithPin(kPin, kPin), EnrollOutcome.enrolled);
    final rec = SessionRecord.tryParse(h.records.raw!)!;
    expect(rec.signedInAt, signedIn);
    expect(
      rec.signedInAt.add(const Duration(days: 30)),
      signedIn.add(const Duration(days: 30)),
    );
  });
}

Map<String, dynamic> tenantJson() =>
    tenantConfigJson(realmUrl: kRealm, clientId: 'letflow-mobile');
