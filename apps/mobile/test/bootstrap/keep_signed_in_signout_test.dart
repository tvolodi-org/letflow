// REQ-810 criterion 8: sign-out and tenant switch revoke at the IdP (best
// effort) and always delete the local record.
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/fake_http_gateway.dart';
import '../support/keep_signed_in_harness.dart';

const _otherRealm = 'https://idp.example/realms/other';

Future<(KeepHarness, BootstrapController)> _signedIn() async {
  final h = KeepHarness();
  final c = h.controller(keep: h.newKeep());
  await c.beginBootstrap('acme');
  await c.enrollWithPin(kPin, kPin);
  return (h, c);
}

/// Records what the world looked like when the NEW sign-in started.
class _SnapshotAdapter extends FakeAppAuthAdapter {
  _SnapshotAdapter(this.h) : super(response: fakeTokenResponse());
  final KeepHarness h;
  int? postsAtSignIn;
  String? recordAtSignIn = 'unset';

  @override
  Future<AuthorizationTokenResponse?> authorizeAndExchangeCode(
    AuthorizationTokenRequest request,
  ) {
    postsAtSignIn = h.revocation.posts.length;
    recordAtSignIn = h.records.raw;
    return super.authorizeAndExchangeCode(request);
  }
}

void main() {
  test('S1 logout deletes the record and revokes the refresh token', () async {
    final (h, c) = await _signedIn();
    await c.logout();
    expect(h.records.raw, isNull);
    expect(h.revocation.posts, hasLength(1));
    final p = h.revocation.posts.single;
    expect(p.url.toString(), '$kRealm/protocol/openid-connect/revoke');
    expect(p.form['client_id'], 'letflow-mobile');
    expect(p.form['token_type_hint'], 'refresh_token');
    expect(p.form['token'], 'fake-refresh-token');
    expect(c.state.phase, BootstrapPhase.unauthenticated);
    expect(c.revocationFailed.value, isFalse);
  });

  test('S2 a failing revocation still deletes and shows one line', () async {
    final (h, c) = await _signedIn();
    h.revocation.error = StateError('offline');
    await c.logout();
    expect(h.records.raw, isNull);
    expect(c.revocationFailed.value, isTrue);
    h.revocation.error = null;
    h.revocation.status = 400;
    final (h2, c2) = await _signedIn();
    h2.revocation.status = 400;
    await c2.logout();
    expect(h2.records.raw, isNull);
    expect(c2.revocationFailed.value, isTrue);
  });

  test('S3 switching to another realm revokes and deletes first', () async {
    final h = KeepHarness();
    final snap = _SnapshotAdapter(h);
    h.adapter = snap;
    h.gateway.unauthenticatedResponsesBySlug['other'] = ScriptedResponse(
      data: tenantConfigJson(realmUrl: _otherRealm, clientId: 'cid-other'),
    );
    final c = h.controller(keep: h.newKeep());
    await c.beginBootstrap('acme');
    await c.enrollWithPin(kPin, kPin);
    expect(h.records.raw, isNotNull);
    await c.switchTenant('other');
    expect(snap.postsAtSignIn, 1);
    expect(snap.recordAtSignIn, isNull);
    expect(h.revocation.posts.single.form['token'], 'fake-refresh-token');
  });

  test('S4 nothing of the previous tenant is left in any store', () async {
    final (h, c) = await _signedIn();
    final store = h.newTokenStore(null);
    await c.logout();
    expect(await store.read(kRealm), isNull);
    expect(await readLastActiveTenant(store), isNull);
    expect(h.records.raw, isNull);
    expect(h.pointer.m, isEmpty);
  });
}
