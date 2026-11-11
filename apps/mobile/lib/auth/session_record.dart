/// The one record the PWA keeps between visits when "stay signed in" is on
/// (REQ-810). Exactly eight keys, nothing else: no access token, no id token,
/// no PIN, no data key. The refresh token and the data key are stored only as
/// AES-GCM ciphertext (`iv ‖ ciphertext ‖ tag`, base64url).
///
/// Platform-neutral: the browser store behind [SessionRecordStore] lives in
/// `web_session_idb.dart`.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The eight keys of a stored record (REQ-810 criterion 3). A record made
/// without "unlock with this device" has exactly these keys, byte for byte as
/// REQ-810 wrote it.
const Set<String> kSessionRecordKeys = {
  'realm_url',
  'slug',
  'enc_refresh_token',
  'wrapped_key',
  'salt',
  'iterations',
  'signed_in_at',
  'failed_pins',
};

/// The three optional, all-or-none keys of REQ-811: the passkey credential id,
/// the random PRF input and the data key wrapped under the HKDF of the PRF
/// output. The PRF output and the key derived from it are never stored.
const Set<String> kDeviceRecordKeys = {
  'device_credential_id',
  'device_eval_input',
  'device_wrapped_key',
};

@immutable
class SessionRecord {
  const SessionRecord({
    required this.realmUrl,
    required this.slug,
    required this.encRefreshToken,
    required this.wrappedKey,
    required this.salt,
    required this.iterations,
    required this.signedInAt,
    required this.failedPins,
    this.deviceCredentialId,
    this.deviceEvalInput,
    this.deviceWrappedKey,
  });

  final String realmUrl;
  final String slug;
  final String encRefreshToken;
  final String wrappedKey;
  final String salt;
  final int iterations;

  /// UTC time of the full sign-in. The 30 days count from here and it is
  /// never moved by a refresh.
  final DateTime signedInAt;
  final int failedPins;

  /// REQ-811: all three set or all three null.
  final String? deviceCredentialId;
  final String? deviceEvalInput;
  final String? deviceWrappedKey;

  bool get hasDeviceUnlock =>
      deviceCredentialId != null &&
      deviceEvalInput != null &&
      deviceWrappedKey != null;

  SessionRecord withDevice({
    required String credentialId,
    required String evalInput,
    required String wrappedKey,
  }) => SessionRecord(
    realmUrl: realmUrl,
    slug: slug,
    encRefreshToken: encRefreshToken,
    wrappedKey: this.wrappedKey,
    salt: salt,
    iterations: iterations,
    signedInAt: signedInAt,
    failedPins: failedPins,
    deviceCredentialId: credentialId,
    deviceEvalInput: evalInput,
    deviceWrappedKey: wrappedKey,
  );

  SessionRecord copyWith({String? encRefreshToken, int? failedPins}) =>
      SessionRecord(
        realmUrl: realmUrl,
        slug: slug,
        encRefreshToken: encRefreshToken ?? this.encRefreshToken,
        wrappedKey: wrappedKey,
        salt: salt,
        iterations: iterations,
        signedInAt: signedInAt,
        failedPins: failedPins ?? this.failedPins,
        deviceCredentialId: deviceCredentialId,
        deviceEvalInput: deviceEvalInput,
        deviceWrappedKey: deviceWrappedKey,
      );

  Map<String, dynamic> toJson() => {
    'realm_url': realmUrl,
    'slug': slug,
    'enc_refresh_token': encRefreshToken,
    'wrapped_key': wrappedKey,
    'salt': salt,
    'iterations': iterations,
    'signed_in_at': signedInAt.toUtc().toIso8601String(),
    'failed_pins': failedPins,
    if (hasDeviceUnlock) ...{
      'device_credential_id': deviceCredentialId,
      'device_eval_input': deviceEvalInput,
      'device_wrapped_key': deviceWrappedKey,
    },
  };

  String encode() => jsonEncode(toJson());

  /// Parses a stored record; `null` when it is not valid JSON or its key set
  /// is not exactly [kSessionRecordKeys] (or those plus all of
  /// [kDeviceRecordKeys]) or a value has the wrong type.
  static SessionRecord? tryParse(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map<String, dynamic>) return null;
      final withDevice = m.containsKey('device_credential_id');
      final allowed = withDevice
          ? {...kSessionRecordKeys, ...kDeviceRecordKeys}
          : kSessionRecordKeys;
      if (m.length != allowed.length || !m.keys.every(allowed.contains)) {
        return null;
      }
      final devCred = m['device_credential_id'];
      final devEval = m['device_eval_input'];
      final devWrapped = m['device_wrapped_key'];
      if (withDevice &&
          (devCred is! String || devEval is! String || devWrapped is! String)) {
        return null;
      }
      final realm = m['realm_url'];
      final slug = m['slug'];
      final enc = m['enc_refresh_token'];
      final wrapped = m['wrapped_key'];
      final salt = m['salt'];
      final iterations = m['iterations'];
      final signedIn = m['signed_in_at'];
      final failed = m['failed_pins'];
      if (realm is! String ||
          slug is! String ||
          enc is! String ||
          wrapped is! String ||
          salt is! String ||
          iterations is! int ||
          signedIn is! String ||
          failed is! int) {
        return null;
      }
      return SessionRecord(
        realmUrl: realm,
        slug: slug,
        encRefreshToken: enc,
        wrappedKey: wrapped,
        salt: salt,
        iterations: iterations,
        signedInAt: DateTime.parse(signedIn).toUtc(),
        failedPins: failed,
        deviceCredentialId: withDevice ? devCred as String : null,
        deviceEvalInput: withDevice ? devEval as String : null,
        deviceWrappedKey: withDevice ? devWrapped as String : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Persistent store of the single record of this origin (a fixed key).
abstract interface class SessionRecordStore {
  Future<String?> read();
  Future<void> write(String json);
  Future<void> delete();
}
