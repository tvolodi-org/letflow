// REQ-811 criteria 3 and 4: unlocking with the device, the PIN as fallback,
// and every lifecycle path deleting both wrappings.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/auth/kv_store.dart';
import 'package:letflow/auth/session_record.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import '../support/fake_device_unlock.dart';
import '../support/fake_http_gateway.dart';
import '../support/keep_signed_in_harness.dart';

Future<(KeepHarness, FakeDeviceUnlock)> _enrolled() async {
  final h = KeepHarness();
  final fake = FakeDeviceUnlock();
  final c = h.controller(keep: h.newKeep(), deviceUnlock: fake);
  await c.beginBootstrap('acme');
  await c.enrollWithPin(kPin, kPin);
  expect(await c.enrollDeviceUnlock(), DeviceEnrolOutcome.enrolled);
  h.gateway.calls.clear();
  h.adapter.refreshCallCount = 0;
  fake.getCalls.clear();
  return (h, fake);
}

Future<BootstrapController> _locked(KeepHarness h, FakeDeviceUnlock f) async {
  final c = h.controller(keep: h.newKeep(), deviceUnlock: f);
  await c.attemptSessionResume();
  return c;
}

int _failed(KeepHarness h) =>
    SessionRecord.tryParse(h.records.raw!)!.failedPins;

void main() {
  test('U1 device unlock: one refresh, success, wrong count reset', () async {
    final (h, f) = await _enrolled();
    var c = await _locked(h, f);
    await c.submitPin('000000');
    await c.submitPin('111111');
    await c.submitPin('222222');
    expect(_failed(h), 3);
    c = await _locked(h, f);
    expect(c.deviceUnlockAvailable.value, isTrue);
    await c.tryDeviceUnlock();
    expect(c.state.phase, BootstrapPhase.success);
    expect(h.adapter.refreshCallCount, 1);
    expect(_failed(h), 0);
    expect(f.getCalls.single.rpId, kRpId);
  });

  test('U2 get throws: stays locked, record and count unchanged', () async {
    final (h, f) = await _enrolled();
    final c = await _locked(h, f);
    await c.submitPin('000000');
    final raw = h.records.raw;
    f.getThrows = true;
    await c.tryDeviceUnlock();
    expect(c.state.phase, BootstrapPhase.locked);
    expect(h.records.raw, raw);
    expect(_failed(h), 1);
  });

  test('U3 no output: same', () async {
    final (h, f) = await _enrolled();
    final c = await _locked(h, f);
    final raw = h.records.raw;
    f.getReturnsNull = true;
    await c.tryDeviceUnlock();
    expect(c.state.phase, BootstrapPhase.locked);
    expect(h.records.raw, raw);
    expect(h.adapter.refreshCallCount, 0);
  });

  test('U4 after a cancelled device unlock the PIN still works', () async {
    final (h, f) = await _enrolled();
    final c = await _locked(h, f);
    f.getThrows = true;
    await c.tryDeviceUnlock();
    await c.submitPin(kPin);
    expect(c.state.phase, BootstrapPhase.success);
  });

  test(
    'U5 a tampered device wrapping: refused, PIN works, record kept',
    () async {
      final (h, f) = await _enrolled();
      f.prf = Uint8List.fromList([for (final b in kPrfMarker) b ^ 0xff]);
      final c = await _locked(h, f);
      final raw = h.records.raw;
      await c.tryDeviceUnlock();
      expect(c.state.phase, BootstrapPhase.locked);
      expect(h.records.raw, raw);
      await c.submitPin(kPin);
      expect(c.state.phase, BootstrapPhase.success);
    },
  );

  test('U6 no device keys: nothing available, no get call', () async {
    final h = KeepHarness();
    final f = FakeDeviceUnlock();
    var c = h.controller(keep: h.newKeep(), deviceUnlock: f);
    await c.beginBootstrap('acme');
    await c.enrollWithPin(kPin, kPin);
    c = await _locked(h, f);
    expect(c.deviceUnlockAvailable.value, isFalse);
    await c.tryDeviceUnlock();
    expect(f.getCalls, isEmpty);
  });

  test('L1 30 days: device unlock is Expired and deletes the record', () async {
    final (h, f) = await _enrolled();
    final c = await _locked(h, f);
    h.clock = h.clock.add(const Duration(days: 30));
    await c.tryDeviceUnlock();
    expect(h.records.raw, isNull);
    expect(c.state.unlockNotice, UnlockNotice.expired);
    expect(h.adapter.refreshCallCount, 0);
  });

  test('L2 invalid_grant after device unlock deletes the record', () async {
    final (h, f) = await _enrolled();
    final c = await _locked(h, f);
    h.adapter.refreshError = const OidcHttpError(400, 'invalid_grant');
    await c.tryDeviceUnlock();
    expect(h.records.raw, isNull);
    expect(c.state.unlockNotice, UnlockNotice.revoked);
  });

  test('L3 logout deletes both wrappings', () async {
    final (h, f) = await _enrolled();
    final c = await _locked(h, f);
    await c.tryDeviceUnlock();
    await c.logout();
    expect(h.records.raw, isNull);
  });

  test('L4 switchTenant deletes the record', () async {
    final (h, f) = await _enrolled();
    h.gateway.unauthenticatedResponsesBySlug['other'] = ScriptedResponse(
      data: tenantConfigJson(
        realmUrl: 'https://idp.example/realms/other',
        clientId: 'cid-other',
      ),
    );
    final c = await _locked(h, f);
    await c.tryDeviceUnlock();
    await c.switchTenant('other');
    expect(h.records.raw, isNull);
  });

  test('L5 the 5th wrong PIN deletes the device wrapping too', () async {
    final (h, f) = await _enrolled();
    final c = await _locked(h, f);
    for (var i = 0; i < 5; i++) {
      await c.submitPin('000000');
    }
    expect(h.records.raw, isNull);
    f.getCalls.clear();
    await c.tryDeviceUnlock();
    expect(f.getCalls, isEmpty);
  });

  test('L6 a refreshed token keeps both wrappings', () async {
    final (h, f) = await _enrolled();
    final keep = h.newKeep();
    final before = SessionRecord.tryParse(h.records.raw!)!;
    final c = h.controller(keep: keep, deviceUnlock: f);
    await c.attemptSessionResume();
    await c.tryDeviceUnlock();
    await keep.replaceRefreshToken('brand-new-refresh');
    final after = SessionRecord.tryParse(h.records.raw!)!;
    expect(after.hasDeviceUnlock, isTrue);
    expect(after.deviceWrappedKey, before.deviceWrappedKey);
    expect(after.wrappedKey, before.wrappedKey);
    expect(after.encRefreshToken, isNot(before.encRefreshToken));
  });
}
