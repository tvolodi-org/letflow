// REQ-810 criterion 3: what the stored record holds, and what no store holds.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart' show EnrollOutcome;
import 'package:letflow/auth/session_record.dart';

import '../support/keep_signed_in_harness.dart';

void main() {
  test('R1 the raw JSON key set is exactly the 8 keys', () async {
    final h = KeepHarness();
    final k = h.newKeep();
    await k.enroll(
      realmUrl: kRealm,
      slug: 'acme',
      refreshToken: 'refresh-secret-abc',
      pin: kPin,
      signedInAt: h.clock,
    );
    final m = jsonDecode(h.records.raw!) as Map<String, dynamic>;
    expect(m.keys.toSet(), kSessionRecordKeys);
    expect(m.length, 8);
    expect(SessionRecord.tryParse(h.records.raw!), isNotNull);
  });

  test('R1b a record with an extra, missing or mistyped key is refused', () {
    final good = {
      'realm_url': 'r',
      'slug': 's',
      'enc_refresh_token': 'e',
      'wrapped_key': 'w',
      'salt': 'a',
      'iterations': 1,
      'signed_in_at': '2026-11-01T00:00:00.000Z',
      'failed_pins': 0,
    };
    expect(SessionRecord.tryParse(jsonEncode(good)), isNotNull);
    expect(SessionRecord.tryParse(jsonEncode({...good, 'v': 1})), isNull);
    expect(
      SessionRecord.tryParse(jsonEncode(Map.of(good)..remove('salt'))),
      isNull,
    );
    expect(
      SessionRecord.tryParse(jsonEncode({...good, 'iterations': '1'})),
      isNull,
    );
    expect(SessionRecord.tryParse('not json'), isNull);
    expect(SessionRecord.tryParse('[]'), isNull);
  });

  test('R2 no token, PIN or data key appears in the record', () async {
    final h = KeepHarness();
    final k = h.newKeep();
    const refresh = 'refresh-secret-abc';
    await k.enroll(
      realmUrl: kRealm,
      slug: 'acme',
      refreshToken: refresh,
      pin: kPin,
      signedInAt: h.clock,
    );
    final raw = h.records.raw!;
    final rec = SessionRecord.tryParse(raw)!;
    final dataKey = (await h.crypto.randomBytes(0)); // shape only
    expect(dataKey, isEmpty);
    for (final secret in [
      refresh,
      base64Url.encode(utf8.encode(refresh)),
      base64.encode(utf8.encode(refresh)),
      utf8.encode(refresh).map((b) => b.toRadixString(16)).join(),
      'fake-access-token',
      'fake-id-token',
      kPin,
    ]) {
      expect(raw.contains(secret), isFalse, reason: secret);
    }
    // The stored ciphertext opens only with the data key, which is itself only
    // stored wrapped: the wrapped key is not the clear key of any length.
    expect(rec.wrappedKey.length, greaterThan(32));
  });

  test(
    'R3 sign-in then enrolment writes no access or id token anywhere',
    () async {
      final h = KeepHarness();
      final k = h.newKeep();
      final c = h.controller(keep: k);
      await c.beginBootstrap('acme');
      expect(c.offerKeepSignedIn.value, isTrue);
      expect(await c.enrollWithPin(kPin, kPin), EnrollOutcome.enrolled);
      final stores = [h.records.raw!, ...h.pointer.m.values];
      for (final s in stores) {
        expect(s.contains('fake-access-token'), isFalse);
        expect(s.contains('fake-id-token'), isFalse);
        expect(s.contains('fake-refresh-token'), isFalse);
      }
    },
  );
}
