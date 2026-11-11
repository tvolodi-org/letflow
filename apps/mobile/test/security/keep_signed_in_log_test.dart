// REQ-810 criterion 9: no secret in any log line or visible text.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/bootstrap/navigation_bootstrap.dart';

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
}
