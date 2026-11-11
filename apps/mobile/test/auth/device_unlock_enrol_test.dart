// REQ-811 criterion 2 (a)-(g): enrolment of the device wrapping.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/auth/session_record.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_device_unlock.dart';
import '../support/keep_signed_in_harness.dart';

Future<(KeepHarness, BootstrapController, FakeDeviceUnlock)> _offered() async {
  final h = KeepHarness();
  final fake = FakeDeviceUnlock();
  final c = h.controller(keep: h.newKeep(), deviceUnlock: fake);
  await c.beginBootstrap('acme');
  await c.enrollWithPin(kPin, kPin);
  return (h, c, fake);
}

Map<String, dynamic> _json(KeepHarness h) =>
    jsonDecode(h.records.raw!) as Map<String, dynamic>;

void main() {
  test(
    'E-a one create with required verification, platform, page host',
    () async {
      final (h, c, fake) = await _offered();
      final before = _json(h);
      prfOnCreateOff(fake);
      expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.enrolled);
      expect(fake.createCalls, hasLength(1));
      final call = fake.createCalls.single;
      expect(call.userVerification, 'required');
      expect(call.authenticatorAttachment, 'platform');
      expect(call.rpId, kRpId);
      expect(call.evalInput, hasLength(32));
      final after = _json(h);
      expect(after.keys.toSet(), {...kSessionRecordKeys, ...kDeviceRecordKeys});
      for (final k in kSessionRecordKeys) {
        expect(after[k], before[k], reason: k);
      }
      expect(c.offerDeviceUnlock.value, isFalse);
    },
  );

  test('E-b create cancelled: PIN stays, record unchanged', () async {
    final (h, c, fake) = await _offered();
    final raw = h.records.raw;
    fake.createThrows = true;
    expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.pinStays);
    expect(h.records.raw, raw);
    expect(fake.getCalls, isEmpty);
  });

  test('E-c get cancelled: cannot this way, record unchanged', () async {
    final (h, c, fake) = await _offered();
    final raw = h.records.raw;
    fake.getThrows = true;
    expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.cannotThisWay);
    expect(h.records.raw, raw);
  });

  test('E-d no PRF: cannot this way, no get call', () async {
    final (h, c, fake) = await _offered();
    final raw = h.records.raw;
    fake.prfEnabled = false;
    expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.cannotThisWay);
    expect(fake.getCalls, isEmpty);
    expect(h.records.raw, raw);
  });

  test(
    'E-e enabled, no output on create: exactly one get, same input',
    () async {
      final (_, c, fake) = await _offered();
      expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.enrolled);
      expect(fake.getCalls, hasLength(1));
      final g = fake.getCalls.single;
      expect(g.rpId, kRpId);
      expect(g.userVerification, 'required');
      expect(g.evalInput, fake.createCalls.single.evalInput);
      expect(g.credentialId, fake.credentialId);
    },
  );

  test('E-e2 output on create: no get call', () async {
    final (_, c, fake) = await _offered();
    fake.prfOnCreate = true;
    expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.enrolled);
    expect(fake.getCalls, isEmpty);
  });

  test('E-f get returns nothing: cannot this way, record unchanged', () async {
    final (h, c, fake) = await _offered();
    final raw = h.records.raw;
    fake.getReturnsNull = true;
    expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.cannotThisWay);
    expect(h.records.raw, raw);
  });

  test('E-g not offered or tried again for the same record', () async {
    final (_, c, fake) = await _offered();
    expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.enrolled);
    expect(c.offerDeviceUnlock.value, isFalse);
    await c.enrollDeviceUnlock();
    expect(fake.createCalls, hasLength(1));
  });

  // Criterion 2(g): after any ended attempt the offer is gone and a second
  // attempt makes no further create call.
  Future<void> expectNotAgain(
    BootstrapController c,
    FakeDeviceUnlock fake,
    KeepHarness h,
    String? rawBefore,
  ) async {
    expect(c.offerDeviceUnlock.value, isFalse);
    final creates = fake.createCalls.length;
    await c.enrollDeviceUnlock();
    expect(fake.createCalls, hasLength(creates));
    expect(h.records.raw, rawBefore);
  }

  test('E-g2 failed create: not offered or tried again', () async {
    final (h, c, fake) = await _offered();
    final raw = h.records.raw;
    fake.createThrows = true;
    expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.pinStays);
    await expectNotAgain(c, fake, h, raw);
  });

  test('E-g3 PRF not enabled: not offered or tried again', () async {
    final (h, c, fake) = await _offered();
    final raw = h.records.raw;
    fake.prfEnabled = false;
    expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.cannotThisWay);
    await expectNotAgain(c, fake, h, raw);
  });

  test('E-g3b enabled false but output present still ends', () async {
    final (h, c, fake) = await _offered();
    final raw = h.records.raw;
    fake
      ..prfEnabled = false
      ..prfOnCreate = true;
    expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.cannotThisWay);
    expect(h.records.raw, raw);
    await expectNotAgain(c, fake, h, raw);
  });

  for (final mode in ['throws', 'null']) {
    test('E-g4 get $mode: not offered or tried again', () async {
      final (h, c, fake) = await _offered();
      final raw = h.records.raw;
      fake.getThrows = mode == 'throws';
      fake.getReturnsNull = mode == 'null';
      expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.cannotThisWay);
      await expectNotAgain(c, fake, h, raw);
    });
  }

  test('E-h the PRF output and derived key are not stored', () async {
    final (h, c, _) = await _offered();
    await c.enrollDeviceUnlock();
    final raw = h.records.raw!;
    for (final enc in [
      base64Url.encode(kPrfMarker),
      base64.encode(kPrfMarker),
    ]) {
      expect(raw.contains(enc), isFalse);
    }
  });
}

void prfOnCreateOff(FakeDeviceUnlock f) => f.prfOnCreate = false;
