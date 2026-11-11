// REQ-810 criteria 10 and 11: README and runbooks say what the code does.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

void main() {
  test('D1 README names the flag, 30 days, six digits, 5 tries, 4 risks', () {
    final readme = _read('README.md');
    final i = readme.indexOf('### Web sign-in (M2)');
    final j = readme.indexOf('### Storage and offline (M3)');
    expect(i, greaterThan(-1));
    final section = readme.substring(i, j);
    expect(section, contains('LETFLOW_PWA_KEEP_SIGNED_IN'));
    expect(section, contains('memory only'));
    expect(section, contains('30 days'));
    expect(section, contains('exactly six digits'));
    expect(section, contains('5th wrong'));
    for (final n in ['(1)', '(2)', '(3)', '(4)']) {
      expect(section, contains(n));
    }
    expect(section, contains('iOS Safari may delete'));
    expect(readme.substring(j), contains('unless the 30-day flag is on'));
  });

  test('D2 sign-in runbook: offline session limit and lost device', () {
    final r = _read('../../docs/runbooks/mobile-web-pwa-signin.md');
    expect(r, contains('Offline Session Max Limited'));
    expect(r, contains('Offline Session Max'));
    expect(r, contains('offline_access'));
    expect(r, contains('## Lost or stolen device'));
    expect(r, contains('0072 D1'));
    expect(r, contains('first-administrator'));
    expect(r, contains('invalid_grant'));
  });

  test('D3 ready-check: device item and operator line', () {
    final r = _read('../../docs/runbooks/mobile-web-pwa-ready-check.md');
    expect(r, contains('stay-signed-in pass'));
    final ops = r.substring(r.indexOf('## Operator check steps'));
    expect(ops, contains('wrong PIN five times'));
  });
}
