// REQ-811 criterion 1: the offer shows only when the device can verify the
// user; declining stores nothing and makes no WebAuthn call.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/app.dart';
import 'package:letflow/auth/session_record.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';
import 'package:letflow/definitions/definitions.dart';
import 'package:letflow/definitions/tenant_home_screen.dart';

import '../support/fake_http_gateway.dart';
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
  widgetTests();
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

Future<(KeepHarness, FakeDeviceUnlock)> _pumpUntilPinSaved(
  WidgetTester tester, {
  required bool available,
}) async {
  final h = KeepHarness();
  final fake = FakeDeviceUnlock()..available = available;
  final c = h.controller(keep: h.newKeep(), deviceUnlock: fake);
  final repo = InMemoryDefinitionCacheRepository();
  final home = DefinitionHomeController(
    repository: repo,
    syncService: DefinitionSyncService(
      repository: repo,
      client: FakeHttpGateway(),
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        bootstrapControllerProvider.overrideWith((ref) => c),
        definitionHomeControllerProvider.overrideWith((ref) => home),
      ],
      child: const LetflowApp(),
    ),
  );
  await tester.pumpAndSettle();
  await c.beginBootstrap('acme');
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('keep-signed-in-accept')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('pin-setup-field')), kPin);
  await tester.enterText(find.byKey(const Key('pin-confirm-field')), kPin);
  await tester.tap(find.byKey(const Key('pin-setup-save')));
  await tester.pumpAndSettle();
  return (h, fake);
}

void widgetTests() {
  testWidgets('D5w offer shown after PIN setup; declining stores nothing', (
    tester,
  ) async {
    final (h, fake) = await _pumpUntilPinSaved(tester, available: true);
    expect(find.byKey(const Key('device-unlock-offer')), findsOneWidget);
    final pinOnly = h.records.raw;
    expect(pinOnly, isNotNull);
    await tester.tap(find.byKey(const Key('device-unlock-decline')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-unlock-offer')), findsNothing);
    expect(h.records.raw, pinOnly);
    expect(fake.createCalls, isEmpty);
    expect(fake.getCalls, isEmpty);
    // A PIN-only record has exactly the REQ-810 keys.
    expect(
      (jsonDecode(pinOnly!) as Map<String, dynamic>).keys.toSet(),
      kSessionRecordKeys,
    );
  });

  testWidgets('D6w no offer when the device cannot verify the user', (
    tester,
  ) async {
    final (h, fake) = await _pumpUntilPinSaved(tester, available: false);
    expect(find.byKey(const Key('device-unlock-offer')), findsNothing);
    expect(h.records.raw, isNotNull);
    expect(fake.createCalls, isEmpty);
  });
}

class _ThrowingAvailable extends FakeDeviceUnlock {
  @override
  Future<bool> isAvailable() async => throw StateError('no webauthn');
}
