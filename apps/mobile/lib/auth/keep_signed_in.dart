/// The 30-day PWA sign-in behind a PIN (REQ-810). Platform-neutral lifecycle:
/// enrol, unlock, re-seal after a refresh, delete. Crypto and storage are
/// behind [SessionCrypto] and [SessionRecordStore].
///
/// Off by default: [kKeepSignedInFlag] is a compile-time flag nothing sets.
/// With it off no object of this file exists and the sign-in is the one of
/// `apps/mobile/README.md`, "Web sign-in" (memory only).
///
/// Secrets: the PIN, the PIN key and the data key live only in local
/// variables and (the data key) in [_dataKey] while the session is unlocked.
/// Nothing here logs or prints; failures are returned as enum-like values.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'kv_store.dart';
import 'session_crypto.dart';
import 'session_record.dart';

/// Compile-time flag `--dart-define=LETFLOW_PWA_KEEP_SIGNED_IN=true`. Default
/// off; no build script or workflow sets it.
const bool kKeepSignedInFlag = bool.fromEnvironment(
  'LETFLOW_PWA_KEEP_SIGNED_IN',
);

/// Outcome of [KeepSignedIn.unlock].
sealed class UnlockResult {
  const UnlockResult();
}

class Unlocked extends UnlockResult {
  const Unlocked(this.record);
  final SessionRecord record;
}

class WrongPin extends UnlockResult {
  const WrongPin(this.remaining);
  final int remaining;
}

class Expired extends UnlockResult {
  const Expired();
}

class TooManyAttempts extends UnlockResult {
  const TooManyAttempts();
}

class Corrupt extends UnlockResult {
  const Corrupt();
}

String _b64(List<int> bytes) => base64Url.encode(bytes);
Uint8List _unb64(String s) => Uint8List.fromList(base64Url.decode(s));

class KeepSignedIn {
  KeepSignedIn({
    required SessionCrypto crypto,
    required SessionRecordStore store,
    DateTime Function()? now,
  }) : _crypto = crypto,
       _store = store,
       _now = now ?? DateTime.now;

  final SessionCrypto _crypto;
  final SessionRecordStore _store;
  final DateTime Function() _now;

  Uint8List? _dataKey;
  String? _lastSealedToken;

  /// Exactly six ASCII digits; no trimming, no other Unicode digits.
  static bool isValidPin(String pin) =>
      pin.length == kPinLength &&
      pin.codeUnits.every((c) => c >= 0x30 && c <= 0x39);

  bool get isUnlocked => _dataKey != null;

  Future<bool> hasRecord() async => (await _store.read()) != null;

  /// The parsed record, or `null` when none (or an unusable one, which is
  /// deleted).
  Future<SessionRecord?> peek() async {
    final raw = await _store.read();
    if (raw == null) return null;
    final rec = SessionRecord.tryParse(raw);
    if (rec == null) await delete();
    return rec;
  }

  /// Stores the refresh token for [slug] under a new random data key wrapped
  /// by [pin]. [signedInAt] is the time of the full sign-in (never "now").
  Future<void> enroll({
    required String realmUrl,
    required String slug,
    required String refreshToken,
    required String pin,
    required DateTime signedInAt,
  }) async {
    if (!isValidPin(pin)) throw ArgumentError('invalid pin');
    final dataKey = await _crypto.randomBytes(kDataKeyBytes);
    final salt = await _crypto.randomBytes(kSaltBytes);
    final pinKey = await _crypto.pbkdf2(pin, salt, kPinIterations);
    final wrapped = await _crypto.seal(pinKey, dataKey);
    final enc = await _crypto.seal(
      dataKey,
      Uint8List.fromList(utf8.encode(refreshToken)),
    );
    final record = SessionRecord(
      realmUrl: realmUrl,
      slug: slug,
      encRefreshToken: _b64(enc),
      wrappedKey: _b64(wrapped),
      salt: _b64(salt),
      iterations: kPinIterations,
      signedInAt: signedInAt.toUtc(),
      failedPins: 0,
    );
    await _store.write(record.encode());
    _dataKey = dataKey;
    _lastSealedToken = refreshToken;
  }

  /// Checks [pin] against the stored record. On success the data key stays in
  /// memory so later refreshes can be re-sealed and [unlockedRefreshToken]
  /// works. An expired record is deleted before any key derivation.
  Future<UnlockResult> unlock(String pin) async {
    final raw = await _store.read();
    if (raw == null) return const Corrupt();
    final rec = SessionRecord.tryParse(raw);
    if (rec == null ||
        rec.iterations < 1 ||
        rec.iterations > kMaxStoredIterations) {
      await delete();
      return const Corrupt();
    }
    var age = _now().toUtc().difference(rec.signedInAt);
    if (age.isNegative) age = Duration.zero;
    if (age >= kSessionMaxAge) {
      await delete();
      return const Expired();
    }
    final Uint8List salt;
    final Uint8List wrapped;
    try {
      salt = _unb64(rec.salt);
      wrapped = _unb64(rec.wrappedKey);
    } catch (_) {
      await delete();
      return const Corrupt();
    }
    final pinKey = await _crypto.pbkdf2(pin, salt, rec.iterations);
    final dataKey = await _crypto.open(pinKey, wrapped);
    if (dataKey == null) {
      final failed = rec.failedPins + 1;
      if (failed >= kMaxWrongPins) {
        await delete();
        return const TooManyAttempts();
      }
      await _store.write(rec.copyWith(failedPins: failed).encode());
      return WrongPin(kMaxWrongPins - failed);
    }
    final token = await _openToken(dataKey, rec.encRefreshToken);
    if (token == null) {
      await delete();
      return const Corrupt();
    }
    _dataKey = dataKey;
    _lastSealedToken = token;
    if (rec.failedPins != 0) {
      await _store.write(rec.copyWith(failedPins: 0).encode());
    }
    return Unlocked(rec.copyWith(failedPins: 0));
  }

  Future<String?> _openToken(Uint8List dataKey, String enc) async {
    try {
      final plain = await _crypto.open(dataKey, _unb64(enc));
      return plain == null ? null : utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  /// The refresh token of the unlocked session (for a retry after a network
  /// error, without asking for the PIN again). `null` when locked.
  Future<String?> unlockedRefreshToken() async {
    final key = _dataKey;
    if (key == null) return null;
    final raw = await _store.read();
    final rec = raw == null ? null : SessionRecord.tryParse(raw);
    if (rec == null) return null;
    return _openToken(key, rec.encRefreshToken);
  }

  /// Re-seals [newToken] under the same data key with a fresh IV. The stored
  /// sign-in time is left unchanged. No-op when locked, when there is no
  /// record, when the token is the one already sealed, or when the record
  /// belongs to another realm than [realmUrl].
  Future<void> replaceRefreshToken(String newToken, {String? realmUrl}) async {
    final key = _dataKey;
    if (key == null || newToken == _lastSealedToken) return;
    final raw = await _store.read();
    if (raw == null) return;
    final rec = SessionRecord.tryParse(raw);
    if (rec == null) return;
    if (realmUrl != null && realmUrl != rec.realmUrl) return;
    final enc = await _crypto.seal(
      key,
      Uint8List.fromList(utf8.encode(newToken)),
    );
    await _store.write(rec.copyWith(encRefreshToken: _b64(enc)).encode());
    _lastSealedToken = newToken;
  }

  /// Deletes the record and drops the in-memory data key.
  Future<void> delete() async {
    final key = _dataKey;
    if (key != null) key.fillRange(0, key.length, 0);
    _dataKey = null;
    _lastSealedToken = null;
    await _store.delete();
  }
}

const String _tokensKeyPrefix = 'letflow.tenant_tokens.';

/// Tokens backend of `TenantTokenStore` when the sign-in is kept: memory as
/// before, plus every new refresh token is re-sealed into the record.
///
/// `delete` deliberately never touches the record: the refresh coordinator
/// deletes tokens on ANY refresh error (a network error included), and a
/// network error must keep the record (REQ-810 criterion 7).
class SessionSyncKv implements KvStore {
  SessionSyncKv(this._inner, this._keepSignedIn);

  final KvStore _inner;
  final KeepSignedIn _keepSignedIn;

  @override
  Future<String?> read(String key) => _inner.read(key);

  @override
  Future<void> write(String key, String value) async {
    await _inner.write(key, value);
    if (!key.startsWith(_tokensKeyPrefix)) return;
    try {
      final m = jsonDecode(value);
      final t = m is Map ? m['refresh_token'] : null;
      if (t is String && t.isNotEmpty) {
        await _keepSignedIn.replaceRefreshToken(
          t,
          realmUrl: key.substring(_tokensKeyPrefix.length),
        );
      }
    } catch (_) {
      // Sealing is best effort; the in-memory session is unaffected.
    }
  }

  @override
  Future<void> delete(String key) => _inner.delete(key);
}
