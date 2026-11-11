// REQ-811: the fake HKDF equals RFC 5869 test case 1, so the VM tests and the
// browser test (B6) share one answer.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../support/fake_session_crypto.dart';

void main() {
  test('H1 RFC 5869 test case 1 (first 32 bytes of OKM)', () async {
    final ikm = Uint8List.fromList(List.filled(22, 0x0b));
    final salt = Uint8List.fromList(List.generate(13, (i) => i));
    final info = Uint8List.fromList(List.generate(10, (i) => 0xf0 + i));
    final okm = await FakeSessionCrypto().hkdfSha256(
      ikm,
      salt: salt,
      info: info,
    );
    final hex = okm.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(
      hex,
      '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf',
    );
  });
}
