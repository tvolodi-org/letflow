// REQ-810 criterion 2: the opt-in. Nothing is stored unless the user accepts
// and sets a valid, matching six-digit PIN.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/auth/keep_signed_in.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_app_auth_adapter.dart';
import '../support/keep_signed_in_harness.dart';

void main() {
  test('O1 a full sign-in with a refresh token makes the offer', () async {
    final h = KeepHarness();
    final c = h.controller(keep: h.newKeep());
    await c.beginBootstrap('acme');
    expect(c.offerKeepSignedIn.value, isTrue);
  });

  test('O1b no refresh token from the IdP: no offer', () async {
    final h = KeepHarness();
    h.adapter.response = fakeTokenResponse(refreshToken: null);
    final c = h.controller(keep: h.newKeep());
    await c.beginBootstrap('acme');
    expect(c.offerKeepSignedIn.value, isFalse);
  });

  test('O2 declining stores nothing', () async {
    final h = KeepHarness();
    final c = h.controller(keep: h.newKeep());
    await c.beginBootstrap('acme');
    c.declineKeepSignedIn();
    expect(c.offerKeepSignedIn.value, isFalse);
    expect(h.records.raw, isNull);
    expect(h.crypto.sealCalls, 0);
  });

  test(
    'O3 invalid or different PINs are refused and nothing is stored',
    () async {
      final h = KeepHarness();
      final c = h.controller(keep: h.newKeep());
      await c.beginBootstrap('acme');
      for (final bad in [
        '12345',
        '1234567',
        '12a456',
        '１２３４５６',
        '12345 ',
        '',
      ]) {
        expect(
          await c.enrollWithPin(bad, bad),
          EnrollOutcome.invalidPin,
          reason: bad,
        );
      }
      expect(await c.enrollWithPin('123456', '123457'), EnrollOutcome.mismatch);
      expect(h.records.raw, isNull);
      expect(h.crypto.sealCalls, 0);
      expect(KeepSignedIn.isValidPin('123456'), isTrue);
      expect(KeepSignedIn.isValidPin(' 23456'), isFalse);
    },
  );

  test('O4 matching valid PINs store exactly one record', () async {
    final h = KeepHarness();
    final c = h.controller(keep: h.newKeep());
    await c.beginBootstrap('acme');
    expect(await c.enrollWithPin(kPin, kPin), EnrollOutcome.enrolled);
    expect(h.records.raw, isNotNull);
    expect(c.offerKeepSignedIn.value, isFalse);
  });
}
