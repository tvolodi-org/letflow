@TestOn('browser')
library;

// REQ-810 criterion 4: the REAL WebCrypto calls, in a real browser. Run by the
// CI step "Browser crypto test (Chrome)":
//   flutter test --platform chrome test/auth/web_session_crypto_browser_test.dart
// It cannot run on the VM (and not on the team host, which has no Chrome);
// `flutter test` without --platform skips this file.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:letflow/auth/keep_signed_in.dart';
import 'package:letflow/auth/session_record.dart';
import 'package:letflow/auth/web_session_crypto.dart';

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);
String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

class _MemStore implements SessionRecordStore {
  String? raw;
  @override
  Future<String?> read() async => raw;
  @override
  Future<void> write(String json) async => raw = json;
  @override
  Future<void> delete() async => raw = null;
}

void main() {
  final crypto = WebSessionCrypto();

  test(
    'B1 PBKDF2-HMAC-SHA-256 known answer (600000 iterations)',
    () async {
      // python3 -I -c "import hashlib;print(hashlib.pbkdf2_hmac('sha256',
      //   b'123456',bytes(range(16)),600000).hex())"
      const expected =
          '93922e39f17be3ac82ee49e41b689b2f825ffcb9b18c64406350c92b4fa3c59c';
      final salt = Uint8List.fromList(List<int>.generate(16, (i) => i));
      final key = await crypto.pbkdf2('123456', salt, 600000);
      expect(_toHex(key), expected);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'B2 record stores 600000 and a 16-byte salt; tamper breaks unlock',
    () async {
      final store = _MemStore();
      Future<KeepSignedIn> keep() =>
          Future.value(KeepSignedIn(crypto: crypto, store: store));
      final a = await keep();
      await a.enroll(
        realmUrl: 'https://idp.example/realms/a',
        slug: 'a',
        refreshToken: 'tok-a',
        pin: '123456',
        signedInAt: DateTime.now().toUtc(),
      );
      final first = jsonDecode(store.raw!) as Map<String, dynamic>;
      expect(first['iterations'], 600000);
      expect(base64Url.decode(first['salt'] as String), hasLength(16));
      // Same PIN unwraps.
      final ok = await (await keep()).unlock('123456');
      expect(ok, isA<Unlocked>());
      // A second record has a different salt.
      final store2 = _MemStore();
      await KeepSignedIn(crypto: crypto, store: store2).enroll(
        realmUrl: 'https://idp.example/realms/a',
        slug: 'a',
        refreshToken: 'tok-a',
        pin: '123456',
        signedInAt: DateTime.now().toUtc(),
      );
      final second = jsonDecode(store2.raw!) as Map<String, dynamic>;
      expect(second['salt'], isNot(first['salt']));
      // Iterations edited down: the derived key differs, the PIN no longer opens.
      store.raw = jsonEncode({...first, 'iterations': 599999});
      expect(await (await keep()).unlock('123456'), isA<WrongPin>());
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );

  test('B3 AES-256-GCM McGrew-Viega test case 15 decrypts', () async {
    // Test Case 15 of "The Galois/Counter Mode of Operation (GCM)": no AAD.
    final key = _hex(
      'feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308',
    );
    final iv = _hex('cafebabefacedbaddecaf888');
    final plain =
        'd9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72'
        '1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255';
    final ct =
        '522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa'
        '8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad';
    const tag = 'b094dac5d93471bdec1a502270e3cc6c';
    final sealed = Uint8List.fromList([...iv, ..._hex(ct), ..._hex(tag)]);
    final opened = await crypto.open(key, sealed);
    expect(opened, isNotNull);
    expect(_toHex(opened!), plain);
    // A flipped tag bit is refused, not decrypted.
    final bad = Uint8List.fromList(sealed)..[sealed.length - 1] ^= 1;
    expect(await crypto.open(key, bad), isNull);
  });

  test(
    'B4 fresh IV and ciphertext on every seal; iv ‖ ct ‖ tag layout',
    () async {
      final key = await crypto.randomBytes(32);
      final msg = Uint8List.fromList(utf8.encode('same message'));
      final a = await crypto.seal(key, msg);
      final b = await crypto.seal(key, msg);
      expect(a, hasLength(12 + msg.length + 16));
      expect(a.sublist(0, 12), isNot(b.sublist(0, 12)));
      expect(a.sublist(12), isNot(b.sublist(12)));
      expect(await crypto.open(key, a), msg);
    },
  );

  test('B5 two enrolments get different 32-byte data keys', () async {
    final k1 = await crypto.randomBytes(32);
    final k2 = await crypto.randomBytes(32);
    expect(k1, hasLength(32));
    expect(k1, isNot(k2));
  });
}
