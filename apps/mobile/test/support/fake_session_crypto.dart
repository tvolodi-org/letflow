/// Hand-written fakes for the 30-day sign-in tests (REQ-810). The crypto fake
/// is NOT secure; it only has the same shape as the real one (random IV, tag
/// check, key-dependent output) and is fast, so the VM tests need no browser.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:letflow/auth/kv_store.dart';
import 'package:letflow/auth/session_crypto.dart';
import 'package:letflow/auth/session_record.dart';
import 'package:letflow/auth/web_app_auth_adapter.dart';

class FakeSessionCrypto implements SessionCrypto {
  int _counter = 0;
  final List<int> randomRequests = [];
  final List<({int iterations, int saltLength})> pbkdf2Calls = [];
  int sealCalls = 0;

  Uint8List _stream(Uint8List key, Uint8List iv, int n) {
    final out = BytesBuilder();
    var block = 0;
    while (out.length < n) {
      out.add(Hmac(sha256, key).convert([...iv, block++]).bytes);
    }
    return Uint8List.fromList(out.toBytes().sublist(0, n));
  }

  @override
  Future<Uint8List> randomBytes(int n) async {
    randomRequests.add(n);
    _counter++;
    return Uint8List.fromList(
      List<int>.generate(n, (i) => (_counter * 31 + i * 7 + n) & 0xff),
    );
  }

  @override
  Future<Uint8List> pbkdf2(String pin, Uint8List salt, int iterations) async {
    pbkdf2Calls.add((iterations: iterations, saltLength: salt.length));
    return Uint8List.fromList(
      sha256.convert([...utf8.encode(pin), ...salt, iterations & 0xff]).bytes,
    );
  }

  @override
  Future<Uint8List> seal(Uint8List key, Uint8List plaintext) async {
    sealCalls++;
    _counter++;
    final iv = Uint8List.fromList(
      List<int>.generate(12, (i) => (_counter * 13 + i) & 0xff),
    );
    final ks = _stream(key, iv, plaintext.length);
    final ct = Uint8List.fromList([
      for (var i = 0; i < plaintext.length; i++) plaintext[i] ^ ks[i],
    ]);
    final tag = Hmac(sha256, key).convert([...iv, ...ct]).bytes.sublist(0, 16);
    return Uint8List.fromList([...iv, ...ct, ...tag]);
  }

  @override
  Future<Uint8List?> open(Uint8List key, Uint8List sealed) async {
    if (sealed.length < 28) return null;
    final iv = sealed.sublist(0, 12);
    final ct = sealed.sublist(12, sealed.length - 16);
    final tag = sealed.sublist(sealed.length - 16);
    final want = Hmac(sha256, key).convert([...iv, ...ct]).bytes.sublist(0, 16);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= tag[i] ^ want[i];
    }
    if (diff != 0) return null;
    final ks = _stream(key, Uint8List.fromList(iv), ct.length);
    return Uint8List.fromList([
      for (var i = 0; i < ct.length; i++) ct[i] ^ ks[i],
    ]);
  }
}

/// Holds the raw JSON string, so a test can read exactly what is stored.
class FakeSessionRecordStore implements SessionRecordStore {
  String? raw;
  int deleteCalls = 0;

  @override
  Future<String?> read() async => raw;

  @override
  Future<void> write(String json) async => raw = json;

  @override
  Future<void> delete() async {
    deleteCalls++;
    raw = null;
  }
}

/// A store that must never be read (flag-off cleanup deletes unread).
class UnreadableSessionRecordStore extends FakeSessionRecordStore {
  @override
  Future<String?> read() async => throw StateError('record was read');
}

/// Discovery + revocation fakes for sign-out tests.
class FakeDiscoveryHttp implements OidcHttp {
  FakeDiscoveryHttp(this.doc);
  final Map<String, dynamic> doc;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> getJson(Uri url) async {
    calls++;
    return doc;
  }

  @override
  Future<Map<String, dynamic>> postForm(Uri url, Map<String, String> form) =>
      throw UnimplementedError();
}

class FakeRevocationHttp implements OidcRevocationHttp {
  final List<({Uri url, Map<String, String> form})> posts = [];
  int status = 200;
  Object? error;

  @override
  Future<int> postFormStatus(Uri url, Map<String, String> form) async {
    posts.add((url: url, form: form));
    if (error != null) throw error!;
    return status;
  }
}
