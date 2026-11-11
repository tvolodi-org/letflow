// REQ-810 criterion 9: no secret in any log line or visible text.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

import 'package:letflow/bootstrap/keep_signed_in_screens.dart'
    show deviceEnrolOutcomeText;
import 'package:letflow/i18n/i18n.dart';

import '../support/fake_device_unlock.dart';
import '../support/keep_signed_in_harness.dart';

void main() {
  test('G1 a full life cycle prints and shows no PIN, token or key', () async {
    final lines = <String>[];
    final old = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
    addTearDown(() => debugPrint = old);

    final h = KeepHarness();
    final texts = <String>[];
    var c = h.controller(keep: h.newKeep());
    await c.beginBootstrap('acme');
    await c.enrollWithPin(kPin, kPin);
    c = h.controller(keep: h.newKeep());
    await c.attemptSessionResume();
    await c.submitPin('999999');
    texts.add(unlockNoticeText(c.state) ?? '');
    h.adapter.refreshResponse = null;
    await c.submitPin(kPin);
    await c.logout();
    texts.add(unlockNoticeText(c.state) ?? '');

    final all = [...lines, ...texts].join('\n');
    for (final secret in [
      kPin,
      '999999',
      'fake-refresh-token',
      'fake-access-token',
      'fake-id-token',
      'refreshed-refresh-token',
    ]) {
      expect(all.contains(secret), isFalse, reason: secret);
    }
  });

  test('G2 device enrolment and unlock leak no PRF output or key', () async {
    final lines = <String>[];
    final old = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
    addTearDown(() => debugPrint = old);

    final h = KeepHarness();
    final fake = FakeDeviceUnlock();
    var c = h.controller(keep: h.newKeep(), deviceUnlock: fake);
    await c.beginBootstrap('acme');
    await c.enrollWithPin(kPin, kPin);
    final outcome = await c.enrollDeviceUnlock();
    final texts = <String>[
      deviceEnrolOutcomeText(outcome) ?? '',
      tr('session.device.offer.body'),
    ];
    c = h.controller(keep: h.newKeep(), deviceUnlock: fake);
    await c.attemptSessionResume();
    await c.tryDeviceUnlock();
    texts.add(unlockNoticeText(c.state) ?? '');

    final all = [...lines, ...texts, h.records.raw ?? ''].join('\n');
    final hex = kPrfMarker
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    for (final secret in [
      hex,
      base64.encode(kPrfMarker),
      base64Url.encode(kPrfMarker),
      kPrfMarker.join(','),
    ]) {
      expect(all.contains(secret), isFalse, reason: secret);
    }
  });
}
