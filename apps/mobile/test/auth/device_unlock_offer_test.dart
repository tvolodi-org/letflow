// REQ-811 criterion 1: the offer shows only when the device can verify the
// user; declining stores nothing and makes no WebAuthn call.
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_device_unlock.dart';
import '../support/keep_signed_in_harness.dart';

Future<(KeepHarness, BootstrapController, FakeDeviceUnlock)> _setup({
  required bool available,
}) async {
  final h = KeepHarness();
  final fake = FakeDeviceUnlock()..available = available;
  final c = h.controller(keep: h.newKeep(), deviceUnlock: fake);
  await c.beginBootstrap('acme');
  return (h, c, fake);
}

void main() {
  test('D1 offered when a verifying authenticator exists', () async {
    final (h, c, fake) = await _setup(available: true);
    await c.enrollWithPin(kPin, kPin);
    expect(c.offerDeviceUnlock.value, isTrue);
    expect(fake.availableCalls, 1);
    expect(fake.createCalls, isEmpty);
    expect(h.records.raw, isNotNull);
  });

  test('D2 not offered when none exists', () async {
    final (_, c, fake) = await _setup(available: false);
    await c.enrollWithPin(kPin, kPin);
    expect(c.offerDeviceUnlock.value, isFalse);
    expect(fake.createCalls, isEmpty);
  });

  test('D3 declining leaves the record byte for byte, no create', () async {
    final (h, c, fake) = await _setup(available: true);
    await c.enrollWithPin(kPin, kPin);
    final before = h.records.raw;
    c.declineDeviceUnlock();
    expect(c.offerDeviceUnlock.value, isFalse);
    expect(h.records.raw, before);
    expect(fake.createCalls, isEmpty);
    expect(fake.getCalls, isEmpty);
  });

  test('D4 isAvailable throwing means no offer', () async {
    final h = KeepHarness();
    final c = h.controller(
      keep: h.newKeep(),
      deviceUnlock: _ThrowingAvailable(),
    );
    await c.beginBootstrap('acme');
    expect(await c.enrollWithPin(kPin, kPin), EnrollOutcome.enrolled);
    expect(c.offerDeviceUnlock.value, isFalse);
  });
}

class _ThrowingAvailable extends FakeDeviceUnlock {
  @override
  Future<bool> isAvailable() async => throw StateError('no webauthn');
}
