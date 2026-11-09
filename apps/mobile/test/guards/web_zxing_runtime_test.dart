// PWA M4 (D-112) S4: the self-hosted zxing-wasm is executed, not only grepped.
// tool/zxing_smoke/run.mjs serves web/ at a root and a non-root base path,
// decodes a known EAN-13 through the zxing WASM path in headless Firefox and
// checks that every request stays on the app origin. Exit 77 means node or
// firefox is missing outside CI (with CI set, a missing tool fails).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'S4: zxing bundle and wasm load from the app, decode works',
    () async {
      ProcessResult result;
      try {
        result = await Process.run('node', ['tool/zxing_smoke/run.mjs']);
      } on ProcessException catch (e) {
        if (Platform.environment['CI'] != null) {
          fail('node is not installed: $e');
        }
        markTestSkipped('node is not installed');
        return;
      }
      final out = '${result.stdout}${result.stderr}';
      if (result.exitCode == 77) {
        markTestSkipped(out);
        return;
      }
      expect(result.exitCode, 0, reason: out);
      expect(out, contains('zxing smoke: PASS'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
