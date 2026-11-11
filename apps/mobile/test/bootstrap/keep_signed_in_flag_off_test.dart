// REQ-810 criterion 1: with the flag off (no KeepSignedIn) nothing is stored,
// nothing is asked, and a record left by an earlier build is deleted unread.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/auth/auth.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_session_crypto.dart';
import '../support/keep_signed_in_harness.dart';

void main() {
  test('F1 no record, no offer, no crypto after a normal sign-in', () async {
    final h = KeepHarness();
    final c = h.controller();
    await c.beginBootstrap('acme');
    expect(c.state.phase, BootstrapPhase.success);
    expect(c.offerKeepSignedIn.value, isFalse);
    expect(h.records.raw, isNull);
    expect(h.crypto.sealCalls, 0);
    expect(h.adapter.lastRequest!.scopes, kOidcScopes);
    expect(await c.enrollWithPin(kPin, kPin), EnrollOutcome.failed);
    expect(h.records.raw, isNull);
    // REQ-811: no device-unlock object, no offer, no WebAuthn call.
    expect(c.deviceUnlock, isNull);
    expect(c.offerDeviceUnlock.value, isFalse);
    expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.pinStays);
  });

  test('F2 only a pointer: the sign-in restarts as on main', () async {
    final h = KeepHarness();
    final store = h.newTokenStore(null);
    await writeLastActiveTenant(
      store,
      const LastActiveTenantPointer(realmUrl: kRealm, slug: 'acme'),
    );
    final c = h.controller(tokenStore: store);
    await c.attemptSessionResume();
    expect(h.adapter.callCount, 1);
    expect(c.state.phase, isNot(BootstrapPhase.locked));
  });

  test('F3 a record left at start is deleted without being read', () async {
    final h = KeepHarness();
    final stale = UnreadableSessionRecordStore()..raw = '{"anything":1}';
    final c = h.controller(stale: stale);
    await c.attemptSessionResume();
    expect(stale.deleteCalls, 1);
    expect(stale.raw, isNull);
    expect(c.state.phase, BootstrapPhase.unauthenticated);
  });

  test('F3b sign-out with the flag off revokes nothing', () async {
    final h = KeepHarness();
    final c = h.controller();
    await c.beginBootstrap('acme');
    await c.logout();
    expect(h.revocation.posts, isEmpty);
    expect(h.discovery.calls, 0);
  });
}
