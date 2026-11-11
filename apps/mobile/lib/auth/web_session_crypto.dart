/// WebCrypto implementation of [SessionCrypto] (REQ-810). Browser only:
/// imported by `app_auth_platform_web.dart`. PBKDF2-HMAC-SHA-256 for the PIN
/// key, AES-256-GCM (128-bit tag, fresh 12-byte IV per seal) for the key wrap
/// and for the stored secret. The proof that these calls produce the
/// documented values runs in a real browser:
/// `test/auth/web_session_crypto_browser_test.dart` (CI step "Browser crypto
/// test (Chrome)").
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'session_crypto.dart';

const int _ivBytes = 12;

JSObject _params(Map<String, JSAny> fields) {
  final o = JSObject();
  fields.forEach((k, v) => o.setProperty(k.toJS, v));
  return o;
}

class WebSessionCrypto implements SessionCrypto {
  WebSessionCrypto();

  web.SubtleCrypto get _subtle => web.window.crypto.subtle;

  @override
  Future<Uint8List> randomBytes(int n) async {
    final arr = Uint8List(n).toJS;
    web.window.crypto.getRandomValues(arr);
    return Uint8List.fromList(arr.toDart);
  }

  @override
  Future<Uint8List> pbkdf2(String pin, Uint8List salt, int iterations) async {
    // The PIN is six ASCII digits; UTF-8 equals the code units.
    final pinBytes = Uint8List.fromList(pin.codeUnits);
    final key = await _subtle
        .importKey(
          'raw',
          pinBytes.toJS,
          'PBKDF2'.toJS,
          false,
          ['deriveBits'.toJS].toJS,
        )
        .toDart;
    final bits = await _subtle
        .deriveBits(
          _params({
            'name': 'PBKDF2'.toJS,
            'hash': 'SHA-256'.toJS,
            'salt': salt.toJS,
            'iterations': iterations.toJS,
          }),
          key,
          256,
        )
        .toDart;
    return Uint8List.fromList(bits.toDart.asUint8List());
  }

  Future<web.CryptoKey> _aesKey(Uint8List key) => _subtle
      .importKey(
        'raw',
        key.toJS,
        'AES-GCM'.toJS,
        false,
        ['encrypt'.toJS, 'decrypt'.toJS].toJS,
      )
      .toDart;

  @override
  Future<Uint8List> seal(Uint8List key, Uint8List plaintext) async {
    final iv = await randomBytes(_ivBytes);
    final out = await _subtle
        .encrypt(
          _params({
            'name': 'AES-GCM'.toJS,
            'iv': iv.toJS,
            'tagLength': 128.toJS,
          }),
          await _aesKey(key),
          plaintext.toJS,
        )
        .toDart;
    final ct = (out! as JSArrayBuffer).toDart.asUint8List();
    final sealed = Uint8List(_ivBytes + ct.length)
      ..setRange(0, _ivBytes, iv)
      ..setRange(_ivBytes, _ivBytes + ct.length, ct);
    return sealed;
  }

  @override
  Future<Uint8List?> open(Uint8List key, Uint8List sealed) async {
    if (sealed.length < _ivBytes + 16) return null;
    try {
      final iv = Uint8List.fromList(sealed.sublist(0, _ivBytes));
      final ct = Uint8List.fromList(sealed.sublist(_ivBytes));
      final out = await _subtle
          .decrypt(
            _params({
              'name': 'AES-GCM'.toJS,
              'iv': iv.toJS,
              'tagLength': 128.toJS,
            }),
            await _aesKey(key),
            ct.toJS,
          )
          .toDart;
      return Uint8List.fromList((out! as JSArrayBuffer).toDart.asUint8List());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List> hkdfSha256(
    Uint8List ikm, {
    required Uint8List salt,
    required Uint8List info,
  }) async {
    final key = await _subtle
        .importKey(
          'raw',
          ikm.toJS,
          'HKDF'.toJS,
          false,
          ['deriveBits'.toJS].toJS,
        )
        .toDart;
    final bits = await _subtle
        .deriveBits(
          _params({
            'name': 'HKDF'.toJS,
            'hash': 'SHA-256'.toJS,
            'salt': salt.toJS,
            'info': info.toJS,
          }),
          key,
          256,
        )
        .toDart;
    return Uint8List.fromList(bits.toDart.asUint8List());
  }
}
