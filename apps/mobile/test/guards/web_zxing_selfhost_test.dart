// PWA M4 (D-112) S1: the web build's zxing-wasm is served by the app itself,
// never from a CDN. Static part; web_zxing_runtime_test.dart executes it.
// Runs from apps/mobile (as CI does).
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const String zxingVersion = '3.1.6';
const String mobileScannerVersion = '7.5.0';
const Map<String, String> sha256s = {
  'zxing-reader.iife.js':
      'ffd72d59d54082194f7c086b384dcd930bdeb0c5b39fbb13779694e69bb0d344',
  'zxing_reader.wasm':
      '5003fb4b88c4fbd1fd518a2fd8c8ad365c519e183a08c03a322dddfea3cea84e',
};
final RegExp _thirdParty = RegExp(r'https?:|jsdelivr|unpkg|gstatic');

// index.html keeps Flutter's template comments (with documentation links), so
// only loaded URLs are checked there.
final RegExp _thirdPartyLoad = RegExp(
  r'''(src|href)=["']https?:|jsdelivr|unpkg|gstatic''',
);

void main() {
  test('S1a: vendored files exist and match the sha256 in the README', () {
    for (final name in [
      'zxing-reader.iife.js',
      'zxing_reader.wasm',
      'zxing-config.js',
      'LICENSE',
      'README.md',
    ]) {
      expect(File('web/zxing/$name').existsSync(), isTrue, reason: name);
    }
    final wasm = File('web/zxing/zxing_reader.wasm').readAsBytesSync();
    expect(wasm.sublist(0, 4), [0x00, 0x61, 0x73, 0x6d]); // "\0asm"
    final readme = File('web/zxing/README.md').readAsStringSync();
    expect(readme, contains('`zxing-wasm` $zxingVersion'));
    for (final entry in sha256s.entries) {
      final bytes = File('web/zxing/${entry.key}').readAsBytesSync();
      expect(sha256.convert(bytes).toString(), entry.value, reason: entry.key);
      expect(readme, contains(entry.value), reason: entry.key);
    }
    expect(File('web/zxing/LICENSE').readAsStringSync(), contains('MIT'));
  });

  test('S1b: index.html preloads the bundle under the package script id', () {
    final h = File('web/index.html').readAsStringSync();
    final bundle = RegExp(
      r'<script id="mobile-scanner-zxing-wasm" src="([^"]+)"></script>',
    ).firstMatch(h);
    expect(bundle, isNotNull);
    expect(bundle!.group(1), 'zxing/zxing-reader.iife.js');
    final config = h.indexOf('<script src="zxing/zxing-config.js"></script>');
    expect(config, greaterThan(bundle.start));
    expect(config, lessThan(h.indexOf('flutter_bootstrap.js')));
    expect(h.contains(_thirdPartyLoad), isFalse, reason: 'index.html');
    final cfg = File('web/zxing/zxing-config.js').readAsStringSync();
    expect(cfg.contains(_thirdParty), isFalse, reason: 'zxing-config.js');
    expect(cfg, contains('setZXingModuleOverrides'));
    expect(cfg, contains("'zxing/zxing_reader.wasm', document.baseURI"));
  });

  test('S1c: a mobile_scanner bump forces a re-check of the vendored copy', () {
    final lock = File('pubspec.lock').readAsStringSync();
    final m = RegExp(
      r'  mobile_scanner:\n(?:    .*\n)*?    version: "([^"]+)"',
    ).firstMatch(lock.replaceAll('\r\n', '\n'));
    expect(m?.group(1), mobileScannerVersion);
  });
}
