// REQ-810 criterion 4 (VM half): the lifecycle passes the documented
// parameters to the crypto interface. The real WebCrypto half runs in a
// browser: web_session_crypto_browser_test.dart.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/auth/keep_signed_in.dart';
import 'package:letflow/auth/session_crypto.dart';
import 'package:letflow/auth/session_record.dart';

import '../support/keep_signed_in_harness.dart';

void main() {
  test(
    'K1 enroll uses 600000 iterations, a 16-byte salt, a 32-byte key',
    () async {
      final h = KeepHarness();
      final k = h.newKeep();
      await k.enroll(
        realmUrl: kRealm,
        slug: 'acme',
        refreshToken: 'r',
        pin: kPin,
        signedInAt: h.clock,
      );
      expect(h.crypto.pbkdf2Calls, hasLength(1));
      expect(h.crypto.pbkdf2Calls.single.iterations, 600000);
      expect(h.crypto.pbkdf2Calls.single.saltLength, 16);
      expect(h.crypto.randomRequests, containsAll([16, 32]));
      expect(h.crypto.sealCalls, 2); // key wrap + refresh token
      final m = jsonDecode(h.records.raw!) as Map<String, dynamic>;
      expect(m['iterations'], 600000);
      expect(base64Url.decode(m['salt'] as String), hasLength(16));
      expect(kPinIterations, 600000);
    },
  );

  test('K1b unlock derives with the iterations stored in the record', () async {
    final h = KeepHarness();
    final k = h.newKeep();
    await k.enroll(
      realmUrl: kRealm,
      slug: 'acme',
      refreshToken: 'r',
      pin: kPin,
      signedInAt: h.clock,
    );
    h.crypto.pbkdf2Calls.clear();
    // The fake's derivation uses the low byte of the count; a record that
    // says 7 must derive with 7 (and so the right PIN no longer opens it).
    final m = jsonDecode(h.records.raw!) as Map<String, dynamic>;
    m['iterations'] = 7;
    h.records.raw = jsonEncode(m);
    final r = await h.newKeep().unlock(kPin);
    expect(h.crypto.pbkdf2Calls.single.iterations, 7);
    expect(r, isA<WrongPin>());
  });

  test(
    'K1c a tampered iteration count above the cap is corrupt, not run',
    () async {
      final h = KeepHarness();
      final k = h.newKeep();
      await k.enroll(
        realmUrl: kRealm,
        slug: 'acme',
        refreshToken: 'r',
        pin: kPin,
        signedInAt: h.clock,
      );
      h.crypto.pbkdf2Calls.clear();
      final rec = SessionRecord.tryParse(h.records.raw!)!;
      h.records.raw = jsonEncode({
        ...rec.toJson(),
        'iterations': kMaxStoredIterations + 1,
      });
      expect(await h.newKeep().unlock(kPin), isA<Corrupt>());
      expect(h.crypto.pbkdf2Calls, isEmpty);
      expect(h.records.raw, isNull);
    },
  );
}
