/// Crypto seam of the 30-day PWA sign-in (REQ-810). The real implementation is
/// WebCrypto (`web_session_crypto.dart`, browser only); `flutter test` on the
/// VM uses a hand-written fake, so the whole lifecycle runs without a browser.
library;

import 'dart:typed_data';

/// PBKDF2-HMAC-SHA-256 iterations for the PIN key.
const int kPinIterations = 600000;

/// Random salt length in bytes (one salt per record).
const int kSaltBytes = 16;

/// AES-256 data key length in bytes.
const int kDataKeyBytes = 32;

/// 30 days from the full sign-in.
const Duration kSessionMaxAge = Duration(days: 30);

/// The fifth wrong PIN deletes the record.
const int kMaxWrongPins = 5;

const int kPinLength = 6;

/// Upper bound accepted for a stored iteration count: a tampered record must
/// not be able to hang the device in a key-derivation loop.
const int kMaxStoredIterations = 10000000;

abstract interface class SessionCrypto {
  Future<Uint8List> randomBytes(int n);

  /// PBKDF2-HMAC-SHA-256 of the UTF-8 [pin], 32 bytes.
  Future<Uint8List> pbkdf2(String pin, Uint8List salt, int iterations);

  /// AES-256-GCM, fresh 12-byte IV, returns `iv ‖ ciphertext ‖ tag`.
  Future<Uint8List> seal(Uint8List key, Uint8List plaintext);

  /// Inverse of [seal]; `null` when the tag does not verify.
  Future<Uint8List?> open(Uint8List key, Uint8List sealed);

  /// HKDF-SHA-256 (RFC 5869) of [ikm], 32 bytes (REQ-811: the key derived
  /// from the passkey PRF output).
  Future<Uint8List> hkdfSha256(
    Uint8List ikm, {
    required Uint8List salt,
    required Uint8List info,
  });
}
